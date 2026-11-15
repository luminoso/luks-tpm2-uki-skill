# Evaluation rubric

Three scenarios, run with and without the skill, on a strong and a weak model. Each answer is scored by hand against the items below: 1 point per item the answer gets right, 0 if missing or wrong. False claims are counted separately.

The prompts are in `scenarios.md`. The ground truth comes from the VM test bench (`testbench/`) and from a real host audit.

## Scenario A: setup plan (Debian 13, NVIDIA via DKMS, own keys, changes BIOS settings)

| # | Item | Why it is ground truth |
|---|---|---|
| A1 | Keeps PCR 7 in the policy | Without PCR 7 the VM released the key with Secure Boot off |
| A2 | Does not bind PCR 8, or says it is useless here | Always zero with systemd-boot + UKI |
| A3 | Does not lock PCR 12 with pcrlock | pcrlock's own ESP credential is measured into PCR 12; first reboot failed |
| A4 | Uses a signed PCR 11 policy (`--tpm2-public-key`) so kernel updates need no reseal | Tested across a 6.12 to 7.2 upgrade |
| A5 | Limits the PCR signature to `Phases=enter-initrd` | Default signs all phases; the booted system could unseal |
| A6 | Uses a systemd-based initrd (dracut) with `systemd-pcrphase` | initramfs-tools has no systemd; signed policy never matches without pcrphase |
| A7 | Signs DKMS modules with a key the kernel trusts and checks the module loads: the `db` key without shim (simplest on Debian), or a MOK with shim. Wrong: unsigned modules, or a DKMS key enrolled nowhere | Debian's kernel loaded a module signed with the `db` key and refused unsigned and foreign-signed ones; a MOK-signed one loaded with shim |
| A8 | Leaves shim out, or, if shim is used, denies Debian's certificate (MokListX) | With shim trusting Debian, a Debian kernel + attacker initrd replayed PCR 7/11 and got the key; without shim the firmware refused that kernel |
| A9 | Knows sbctl is not packaged in Debian, or uses packaged tools correctly | Not in trixie, backports or sid |
| A10 | Re-signs boot files after package updates (hook) | systemd-boot/shim updates copy unsigned or Debian-signed files to the ESP |
| A11 | Keeps initramfs-tools from replacing dracut (pin) | microcode Recommends pulled it in; boot stopped in BusyBox |
| A12 | Sets a known pcrlock recovery PIN (or equivalent recovery path) | Default `hide` PIN made the policy unrepairable without re-enrolling |
| A13 | Leaves PCR 1/3 out (or makes it the user's choice) given BIOS changes, and checks PCR stability across a reboot | User requirement; some firmware measures changing data |
| A14 | Keeps a passphrase or recovery key slot | Every TPM refusal falls back to it |
| A15 | Makes sure a forced initrd failure cannot give a shell while the PCRs still match (checks it, or adds `rd.shell=0 rd.emergency=halt`) | Debian's dracut initrd refused (root locked); the initramfs-tools initrd gave a passwordless BusyBox shell |

## Scenario C: server without DKMS, operations (12 items)

| # | Item | Why it is ground truth |
|---|---|---|
| C1 | Leaves shim out: firmware starts systemd-boot signed by the user's `db` key | No DKMS needed; without shim Debian's certificate is never trusted, the Debian-kernel attack was refused by the firmware |
| C2 | Keeps PCR 7 in the policy | Key released with Secure Boot off without it |
| C3 | Signed PCR 11 limited to `Phases=enter-initrd` | Default phases let the booted system unseal |
| C4 | dracut with `systemd-pcrphase`, `initramfs-tools` pinned out | Microcode pulled initramfs-tools in and removed dracut |
| C5 | Re-sign hook that restores systemd-boot from its package (or equivalent: never signs whatever is on the ESP) | Package updates put unsigned or foreign loaders on the ESP |
| C6 | BIOS update: drops PCRs 0 to 3 (not only 0 and 2) from the policy before flashing, re-locks after the first boot, PCR 7 kept | A different firmware build changed PCRs 0, 1 and 2 |
| C7 | Policy updates without the PIN while the machine matches; recovery PIN only when it does not | `--recovery-pin=query` always uses the PIN |
| C8 | Recovery key, kept off the machine | Second fallback; tested at the prompt |
| C9 | Alert when the disk was opened by passphrase (journal-based check, mail or monitoring) | Unattended reboots |
| C10 | Boot counting (`/etc/kernel/tries`) with `systemd-bless-boot` | Broken UKI tried 3 times, then skipped |
| C11 | Checks before rebooting that the next boot will match (UKI signature, `.pcrsig`, PCR 1/7 changes) | Caught boot order and `db` changes before the reboot |
| C12 | `rd.shell=0 rd.emergency=halt` (and notes a halted machine needs a reset for boot counting to continue) | Forced initrd failure halts |

## Scenario B: audit of a real host (facts given as text)

| # | Item | Severity |
|---|---|---|
| B1 | Next systemd-boot package update puts a Debian-signed loader on the ESP (hand-replaced `.signed`, no re-sign hook) and the firmware refuses it | High |
| B2 | No `EFI/BOOT/BOOTX64.EFI` fallback; boot depends on one NVRAM entry | High/Medium |
| B3 | PK and KEK private keys stored on the host | Medium |
| B4 | DKMS certificate in firmware `db`: firmware runs EFI binaries signed with it | Medium |
| B5 | Nothing stops initramfs-tools from replacing dracut | Medium |
| B6 | GRUB still installed, recommended by new kernels, grub-pc in a failed state | Low |
| B7 | crypttab typo `tpm-device=` | Low |
| B8 | Stale `LoaderEntryDefault` pointing at a removed UKI | Low |
| B9 | Says to check that a forced initrd failure cannot give a shell while the PCRs still match | Check |

False claims to count (each one is a point against): saying TPM decryption is not working, saying `systemd-pcrphase` is missing from the initrd, saying there is no passphrase slot, saying PCR 7 is missing from the policy, recommending binding PCR 8 or locking PCR 12.
