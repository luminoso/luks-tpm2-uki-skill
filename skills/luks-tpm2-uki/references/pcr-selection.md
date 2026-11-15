# Choosing PCRs

The TPM policy has two parts:

- **PCR 11, always, by signature.** systemd-stub measures the UKI (kernel, initrd, command line) into PCR 11. `ukify` signs the value each UKI will produce, and the TPM accepts any value carrying your signature. Kernel updates never need resealing. Sign only `Phases=enter-initrd`.
- **A set of firmware and Secure Boot PCRs, chosen per user, locked by `systemd-pcrlock`.** pcrlock keeps the allowed values in a TPM NV index, so you can update them later without touching the LUKS header.

The second set is a trade-off. Each extra PCR catches one more kind of tampering, and also adds one more routine event that sends the user to the passphrase prompt. Ask the user what they change on this machine, then pick.

## What each PCR holds on this setup

| PCR | Holds | Changes when | Lock it? |
|---|---|---|---|
| 0 | Firmware code | Firmware update | Optional |
| 1 | Firmware settings, boot order, boot entries (`Boot####`) | Any BIOS setting, `efibootmgr -o` or `--create`, a new boot entry (booting a USB stick from the firmware menu can add one) | Optional, the most fragile |
| 2 | Option ROMs of add-in cards and some docks | Adding, removing or updating a card or dock with an option ROM | Optional |
| 3 | Option ROM configuration | Same as 2 | Optional |
| 4 | Hashes of every EFI program started (shim, systemd-boot, UKI) | Every kernel and boot loader update | No, unless something re-locks it on every update |
| 5 | GPT, `loader.conf` | Partition changes, loader config edits | pcrlock drops it by itself |
| 7 | Secure Boot on/off, PK/KEK/db/dbx, shim's SBAT level, which certificate approved each step, MokListX refusals | Key changes, dbx updates, shim updates that raise SBAT | **Required** |
| 8 | Nothing (systemd-boot leaves it at zero) | Never | No: binding it protects nothing |
| 11 | UKI sections and boot phase | Every kernel update | By signature only, never literally |
| 12 | Credentials and addons from the ESP, including pcrlock's own policy credential | Every `make-policy` run | **Never** |
| 13 | System extensions (usually zero) | Only if you use sysexts | Optional, cheap |
| 14 | shim's MOK lists | MOK enrollment | No: pcrlock drops it when shim is present |

Why PCR 7 is required: PCR 11 is extended by software. With Secure Boot off, anyone can boot the user's own UKI and reproduce the signed PCR 11 value. PCR 7 is what proves the boot chain ran only signed code. In the VM, a policy without PCR 7 released the key with Secure Boot off; with PCR 7 alone it prompted.

## Profiles to offer

| Profile | PCRs (pcrlock) | Survives | Fails on |
|---|---|---|---|
| Minimal | 7 | Firmware updates, BIOS settings, boot order, docks, cards | Secure Boot changes |
| Balanced (default) | 0, 2, 7, 13 | BIOS settings, boot order, USB boot entries | Firmware updates, option ROM changes |
| Strict | 0, 1, 2, 3, 7, 13 | Nothing but routine OS updates | Any firmware or settings change |

All three keep signed PCR 11 on top.

Translate the user's habits into the choice:

| The user... | Leave out |
|---|---|
| changes BIOS settings, boot order, or boots USB sticks from the firmware menu | 1, 3 |
| installs firmware updates often (fwupd, vendor tools) | 0, 2 |
| plugs docks, eGPUs or swaps PCIe cards | 2, 3 |

## Find out which PCRs a change moves, on this machine

Firmware differs, so measure instead of guessing. For each change the user cares about (plug the dock, change one BIOS setting, add a USB boot entry):

```bash
systemd-analyze pcrs 0 1 2 3 4 5 7 13 > /root/pcrs.before
# make the change, reboot
systemd-analyze pcrs 0 1 2 3 4 5 7 13 | diff /root/pcrs.before -
```

Any PCR that shows up in the diff is one this change would trip. Leave it out if the user wants that change to be free.

## Check which PCRs this host can lock

Record the components, then dry-run the policy:

```bash
P=/usr/lib/systemd/systemd-pcrlock
$P lock-firmware-code; $P lock-firmware-config
$P lock-secureboot-policy; $P lock-secureboot-authority; $P lock-gpt
$P predict 2>&1 | grep -E '^PCR|protection mask'
```

`predict` writes nothing. `PCRs in protection mask:` is the most this host supports. To see why a PCR was dropped, look in `$P log` for events with `-` in the COMPONENT column. If PCR 7 is dropped, stop: the firmware measures something pcrlock does not recognize.

Then check stability. Two plain reboots, no changes, same values:

```bash
systemd-analyze pcrs 0 1 2 3 7 13 > /root/pcrs.before
systemctl reboot
# after the reboot:
systemd-analyze pcrs 0 1 2 3 7 13 | diff /root/pcrs.before - && echo stable
```

Drop any PCR that changes on a plain reboot. The final list is: what `predict` keeps, minus unstable PCRs, minus what the user's habits rule out. It must still contain 7.

## Make and keep the policy

```bash
PCRS=0,2,7,13                                     # the chosen list
echo "PCRS=$PCRS" > /etc/kernel/pcrlock-pcrs       # one place, reused for every re-lock
$P make-policy --pcr=$PCRS --recovery-pin=query 2>&1 | tee /tmp/mp.out
grep 'PCRs in protection mask:.*\b7 (secure-boot-policy)' /tmp/mp.out || echo "STOP: PCR 7 not locked"
```

Always pass `--pcr=` explicitly: the default list includes PCR 12, which breaks the first reboot. Always use `--recovery-pin=query` and have the user write the PIN down: with the default (`hide`), a machine that has drifted from the policy cannot be re-locked without removing the policy and enrolling the disk again.

## Re-lock after a change

After the change (passphrase prompt on the next boot), re-record what changed and update the policy with the PIN:

```bash
. /etc/kernel/pcrlock-pcrs
$P lock-firmware-code          # firmware update
$P lock-firmware-config        # settings, boot order
$P lock-secureboot-policy      # db/dbx/KEK/PK change
$P lock-secureboot-authority   # shim or signing certificate change
$P make-policy --pcr=$PCRS --recovery-pin=query
```

No `systemd-cryptenroll` needed: the LUKS token points to the same NV index. `Failed to add OR policy to TPM: tpm:parameter(1):value is out of range` (TPM_RC 0x1c4) means the current PCRs match none of the predicted values: add `--recovery-pin=query`.

`--recovery-pin=query` makes `make-policy` use the PIN every time. While the machine still matches the policy in force, leave it out: the update is authorized by the current PCRs and the PIN does not change. With the option and an empty or wrong PIN, the VM failed with `Failed to write to NV index` (TPM_RC 0x99d) even on a matching boot. `scripts/pcrlock-update close` tries without the PIN first and asks only if that fails.

## Planned changes without a passphrase prompt

Firmware updates and BIOS settings cannot be recorded before they happen: the new values only exist in the event log of the first boot after the change. Narrow the policy for that one boot instead (`scripts/pcrlock-update`):

```bash
pcrlock-update open 0,1,2,3      # PCR 7 always stays locked
# flash the firmware or change the setting, reboot: opens automatically
pcrlock-update close             # re-record all components, lock the full list again
```

Tested in the VM by switching to a firmware build from a different edk2 release: PCRs 0, 1 and 2 changed (the firmware's handoff tables are measured into PCR 1), so `open 0,2` still prompted and `open 0,1,2,3` did not. No PIN was asked at either step.

When you change a Secure Boot variable yourself (for example writing a new `db`), you can record it ahead instead, and keep the old state as a second allowed value before the change, so both match:

```bash
D=/var/lib/pcrlock.d/240-secureboot-policy.pcrlock.d
cp $D/generated.pcrlock $D/previous.pcrlock    # old state stays allowed
# ... make the change (e.g. efi-updatevar on db) ...
$P lock-secureboot-policy                      # records the new state
$P make-policy --pcr=$PCRS                     # no PIN needed: the machine still matches the old policy
# reboot (opens automatically), then tighten:
rm $D/previous.pcrlock && $P make-policy --pcr=$PCRS
```

Tested in the VM for a `db` rewrite: both reboots opened automatically, and pcrlock retrieved its own PIN from the TPM.
