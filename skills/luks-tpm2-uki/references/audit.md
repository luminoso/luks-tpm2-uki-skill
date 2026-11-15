# Auditing an existing setup

## Collect facts first

```bash
bash scripts/audit.sh            # as the user: everything readable without root
sudo bash scripts/audit.sh       # ask the user to run this and paste the output
```

The script only reads. It prints sections for the boot chain, Secure Boot keys, TPM policy, initrd, update hooks and recovery. Do not conclude anything from a section the script could not read: say it needs root.

## What a healthy system shows

Check what works before listing problems, and say so in the report:

- The last boot opened the disk without a prompt: `systemd-cryptsetup@<name>` finished within a second or two of starting, no "Failed to unseal" lines.
- `systemd-pcrphase-initrd.service` ran in this boot.
- The LUKS header has a `systemd-tpm2` token and at least one keyslot without a token (the passphrase).
- `pcrlock.json` lists PCR 7. The token says `tpm2-pubkey-pcrs: 11`.

## Checks

| # | Check | How | Bad sign | Severity | Fix |
|---|---|---|---|---|---|
| 1 | Boot files survive package updates | `dpkg --verify systemd-boot-efi-amd64-signed`; apt hooks in `/etc/apt/apt.conf.d`; signer of ESP files (`sbverify --list`) | A hand-replaced `systemd-bootx64.efi.signed` and no re-sign hook. The next package update restores the vendor-signed file and `bootctl update` copies it to the ESP, where firmware with only your keys refuses it | High | `resign-esp` apt hook (`scripts/resign-esp`), then reinstall the package so dpkg owns the original again |
| 2 | Fallback loader | `ls ESP/EFI/BOOT/BOOTX64.EFI`, `efibootmgr` | Missing, and only one NVRAM boot entry. A BIOS reset or update that clears entries leaves nothing to boot | High | Copy the signed loader there and add it to the hook's file list. Do not add an entry yourself, and if PCR 1 is locked, `pcrlock-update open 1` first: some firmware adds a "UEFI OS" entry for the new file by itself (seen on a real host), which changes PCR 1 |
| 3 | PCR 7 in the policy | `pcrlock.json` PCR list, or the token's `tpm2-pcrs` | Missing | High | Re-make the policy with 7 (`pcr-selection.md`) |
| 4 | Signed PCR 11 limited to the initrd | `ukify inspect` the UKI: `.pcrsig` with one entry per bank; `uki.conf` `Phases=enter-initrd` | Several phases signed | High | Set `Phases=enter-initrd`, rebuild UKIs |
| 5 | Distribution certificate trusted by shim | Is shim in the chain (`efibootmgr`, `ESP/EFI/*/shimx64.efi`)? `mokutil --mokx --list-enrolled` | shim present and the distribution's certificate not in MokListX | High | Re-sign systemd-boot and MokManager with your key, then deny the certificate (`debian-guide.md` §12) |
| 6 | Private keys on the host | List the key directory (`/etc/secureboot`, `/var/lib/sbctl/keys`, ...) | PK and KEK private keys present | Medium | Encrypted archive off the machine, then shred. Keep only the db key and the PCR key |
| 7 | Extra certificates in firmware `db` | Parse `db` (`scripts/audit.sh` does) | A DKMS or other narrow-purpose certificate in `db`: firmware will also start any EFI program signed with it | Medium | If the kernel trusts `db` for modules, sign DKMS with the `db` key and remove the extra certificate (`scripts/db-remove-cert.py`, then the pcrlock procedure in `pcr-selection.md`) |
| 8 | initramfs-tools kept out | `apt-cache policy initramfs-tools`, `/etc/apt/preferences.d` | Not pinned while dracut builds the UKI's initrd. A package that depends on or recommends it (microcode) swaps dracut out | Medium | Pin `initramfs-tools` and `initramfs-tools-core` to -1 |
| 9 | Leftover GRUB | `dpkg -l 'grub*'`, kernel package `Recommends:`, `/boot/grub/x86_64-efi/core.efi`, debconf `grub2/update_nvram` | Debian: installed and recommended by new kernels. Proxmox: GRUB is required by `zz-proxmox-boot`, so the bad sign is GRUB able to write the ESP or NVRAM | Low | Debian: `apt-get -s purge` first, then purge and pin. Proxmox: keep `grub-efi-amd64`, `apt-mark manual`, `grub2/update_nvram false`, `grub2/force_efi_extra_removable false` |
| 10 | crypttab options | `/etc/crypttab` | Typos like `tpm-device=` (systemd ignores unknown options) | Low | Fix the option |
| 11 | Saved default boot entry | `LoaderEntryDefault` EFI variable vs `LoaderEntries` | Points at a UKI that no longer exists | Low | `bootctl set-default ""` |
| 12 | Emergency shell in the initrd | `rd.shell=0 rd.emergency=halt` in the UKI `.cmdline`; if absent, which initrd generator (initramfs-tools gives a passwordless shell) | Missing | Medium (High with initramfs-tools) | Add both to `/etc/kernel/cmdline`, rebuild UKIs. Tested: the initrd halts on failure |
| 13 | Option ROMs | `db` hash entries vs `EV_EFI_BOOT_SERVICES_DRIVER` events in the TPM log | Own keys, option ROMs in the log, no hashes enrolled | Medium (no display or no boot) | `sbctl enroll-keys --tpm-eventlog`, or keep Microsoft's UEFI CA |
| 14 | Pending kernel | `uname -r` vs `/lib/modules`, UKIs on the ESP | New kernel installed but its UKI is missing, unsigned or lacks `.pcrsig` | High before reboot | Rebuild with `kernel-install add <ver> /boot/vmlinuz-<ver>` |
| 15 | Unexpected files on the ESP | `find ESP -type f`, every `loader/entries/*.conf` | Boot entries or programs the user did not create (an extra kernel, an entry with `init=` options): someone wrote to the ESP | High until explained | Ask the user before removing. Secure Boot and the TPM policy should have refused them: check that boot's journal |
| 16 | Re-sign hook signs whatever is on the ESP | `/etc/kernel/esp-signing.conf`: is every loader in `FILES` also restored from a package `COPY` source? | A loader path with no `COPY` source: a binary written there by `grub-install` or another tool would get your signature | Medium | Add `COPY` entries from the package files (`scripts/esp-signing.conf.example`) and the current `scripts/resign-esp` |
| 17 | Next boot | `check-next-boot` (root), in the audit output | Any FAIL line: the next reboot asks for the passphrase or does not boot | High before reboot | Fix what the line names; `pcrlock-update close` for changed PCR 1/7 or stale policy |
| 18 | Recovery key | `cryptsetup luksDump`: `systemd-recovery` token | None: only the passphrase opens the disk when the TPM refuses | Medium | `systemd-cryptenroll --recovery-key`, shown once; paper or password manager, never a file on the host |
| 19 | Unlock alert | `tpm-unlock-check.service` enabled | Not installed: a TPM refusal on an unattended reboot is only noticed at the console | Low (Medium on servers) | Install `scripts/tpm-unlock-check` + `.service`; root's mail must reach someone |
| 20 | Boot counting | `/etc/kernel/tries`, `+N` in UKI names, `systemd-bless-boot.service` | Not set: a new kernel that fails to boot needs someone at the boot menu | Low | `echo 3 > /etc/kernel/tries`, rebuild UKIs |
| 21 | Policy left open | `/var/lib/pcrlock-update.open` | Present: fewer PCRs locked than the user chose, since the date shown | Medium | `pcrlock-update close` once the planned change has booted |

## Writing the report

- Most severe first. One line on what is wrong, one on why it matters on this host, one with the fix.
- Separate "verified on this host" from "inferred". If a fact needs root, say which command the user should run.
- Do not recommend locking PCR 4, binding PCR 8, or locking PCR 12.
- Do not treat a signing key on the host as an emergency by itself: automatic UKI signing needs the `db` key and the PCR key there. PK and KEK are the ones to move.
- Severity is about consequences on this host: unbootable after the next update ranks above a stale variable.

## Fixing

Deliver one script the user runs as root. For each step: check the precondition, back up, change, verify, stop on error. Put risky steps (firmware variables) behind an explicit question. Order steps so the machine stays bootable after each one, and so keys needed for a rollback (KEK) are removed last, after a successful reboot.
