# Lessons, with evidence

Each entry: what happened, why, what fixed it. "VM" means the QEMU/OVMF/swtpm test bench in `testbench/`, Debian 13.7, systemd 257.13, dracut 106, shim 16.1. "Host" means a real Proxmox VE 9.2 machine.

## TPM policy

- Policy without PCR 7 released the key with Secure Boot off. PCR 11 is software-extendable, so the signed value is reproducible with Secure Boot off. VM, `tests/n4-no-pcr7.sh`. PCR 7 alone prompted.
- First reboot after sealing asked for the passphrase. `make-policy` with the default PCR list locked PCR 12 at zero, then wrote its policy credential to the ESP, which systemd-stub measured into PCR 12. Fix: explicit `--pcr=` list without 12.
- Policy could not be repaired. Default `--recovery-pin=hide` generated a PIN nobody saw; once PCRs drifted, `make-policy` failed with TPM_RC 0x1c4. Fix: `--recovery-pin=query`.
- PCR 8 is always zero with systemd-boot and a UKI. Binding it adds nothing.
- `Phases=` default signs every phase. With only `enter-initrd` signed, the running system holding the UKI's signature still got "No matching TPM2 token data found". VM.
- Planned firmware variable change without a prompt works by keeping the old pcrlock component as a second variant before the change. VM, `db` rewrite.
- `Esys_Unseal ... 0x128` in the journal before the disk opens is TPM_RC_PCR_CHANGED, a race systemd retries. Harmless.
- `make-policy --recovery-pin=query` always authorizes the NV write with the PIN. Fed no PIN on a boot that matched the policy, it failed with TPM_RC 0x99d (policy check failed); without the option the same update went through and the PIN stayed the same. VM.
- A firmware build from another edk2 release changed PCRs 0, 1 and 2. PCR 1 changed through `efi-handoff-tables`. Dropping only 0 and 2 before the switch still prompted; dropping 0 to 3 did not. VM.
- `systemd-pcrlock remove-policy` followed by `make-policy` creates a new NV index; the LUKS token still names the old one (`tpm2_pcrlock_nv` in `cryptsetup token export`). The next boot printed "No pcrlock policy found among system credentials. Couldn't find pcrlock policy for volume." and asked for the passphrase. Host, then reproduced in the VM; `systemd-cryptenroll --wipe-slot=tpm2 ...` against the new policy fixed it. To re-lock, run `make-policy` again: it updates the same NV index. `check-next-boot` now compares the token's NV index with the policy's.
- Some firmware creates its own boot entry for `EFI/BOOT/BOOTX64.EFI` once that file appears ("UEFI OS", optional data `BO`). On a UGREEN DXP2800 that changed the boot entries and BootOrder, so PCR 1, on the next boot: the disk asked for the passphrase. Host. Before adding the fallback loader on a host that locks PCR 1, `pcrlock-update open 1`, boot once, then `close`; or leave PCR 1 out.
- A `db` entry appended with `efi-updatevar` and recorded with `lock-secureboot-policy` + `make-policy` before the reboot opened automatically; not recording it prompted. VM.

## Boot chain

- Stock Debian kernel + attacker initrd got the key when shim (which trusts Debian's certificate) was in the chain. The attack path's PCR 7 was the legitimate list minus its final entry, so the initrd replayed it and the UKI's PCR 11 measurements. VM, both shim options, `tests/n5-*`. Closed by denying Debian's certificate in MokListX: shim refused the kernel ("Security Policy Violation") and the refusal itself extended PCR 7.
- Attacker MOK enrolled at the console does not change locked PCRs (the disk still opens), but a kernel approved by it adds a PCR 7 entry that cannot be undone. TPM refused. VM.
- No-shim chain refused the Debian kernel at the firmware ("Access denied"). VM.
- Command line injection through an extra boot entry (`init=/bin/sh`) was ignored by systemd-stub under Secure Boot. VM, `tests/n1-cmdline-inject.sh`.
- Planted TPM-sealed credential (`systemd.extra-unit.*`) in `ESP/loader/credentials/` was received as untrusted and not applied. VM.
- Forced initrd failure (LUKS header UUID changed, no key needed) reached dracut's emergency mode, which refused a shell because the root account is locked inside the initrd. VM. The initramfs-tools initrd, in an earlier failure, gave a passwordless BusyBox shell. With `rd.shell=0 rd.emergency=halt` in the UKI command line, the same forced failure printed "Could not boot. Halting." and stopped; normal boots still opened automatically. VM, no-shim chain.

## Operations

- Boot counting (`/etc/kernel/tries`) works with signed UKIs: kernel-install names them `+3.efi`, `systemd-bless-boot` removed the counter after a good boot, and a correctly signed UKI with a missing root device was started 3 times (the initrd halted each time, after dracut's `rd.retry` timeout, 180 s by default), then marked `+0-3` and skipped; the previous kernel opened the disk from the TPM. VM.
- Journal markers for the unlock alert (systemd 257): a TPM unlock logs nothing from `systemd-cryptsetup`; a passphrase or recovery key logs `Set cipher ... for device <the volume>`; a TPM refusal logs `TPM2 operation failed, falling back to traditional unlocking`. VM, compared across 13 boots.
- `check-next-boot` caught an unsigned UKI made the default, a UKI with a different command line, a changed BootOrder and a `db` change, each before the reboot. Two bugs found on the way: `cmd | grep -q` under `pipefail` reports failure when `cmd` gets SIGPIPE, and an empty `pcrlock predict` (pcrlock busy) must count as a mismatch, not a pass. VM.
- A recovery key is typed at the same prompt as the passphrase and opened the disk after an unplanned firmware change. VM.

## Packages and updates

- sbctl is not packaged in Debian (trixie, backports, sid). It builds from the signed upstream tarball with trixie's Go (`GOTOOLCHAIN=local`). Keys in `/var/lib/sbctl/keys`.
- `sbctl sign` adds a signature next to an existing one. With the distribution's certificate denied, a file carrying both is refused. The `resign-esp` script strips and re-signs instead.
- systemd-boot package updates run `bootctl update`, which copies `systemd-bootx64.efi.signed` (the distribution's signature) to the ESP if present. Without a re-sign hook, firmware with only your keys refuses it.
- `shim-signed`'s pre-install script refuses to install or upgrade when Secure Boot is on and no Microsoft certificate is in `db` ("FATAL ERROR - your system will not currently boot with this signed shim installed"), leaving dpkg half-configured. With own keys use `shim-unsigned`, signed by you, in a directory the systemd-boot package does not manage (it deletes `EFI/debian/shim*` when `shim-signed` is absent).
- Debian's GRUB signed package is protected: purging it needs `--allow-remove-essential` or a typed confirmation.
- `intel-microcode` recommends initramfs-tools; installing it removed dracut and the next boot stopped in a BusyBox shell. A pin to -1 fixes it; dracut then rebuilds the UKI with the microcode.
- On Proxmox, purging GRUB breaks kernel package scripts: `zz-proxmox-boot` exits 1 with "System booted in EFI-mode but 'grub-efi-amd64' meta-package not installed!", which aborted an `apt autoremove` of an old kernel and left dpkg half-done. Host. Keep `grub-efi-amd64` installed and inert (`grub2/update_nvram false`, no `/boot/grub/x86_64-efi/core.efi`); do not pin GRUB.
- A re-sign hook that signs whatever sits at its paths would also sign a GRUB or shim binary that a package wrote there. The hook now restores each path from its package when the file is not yours, and only then signs. Unit-tested on a fake ESP: a foreign binary at the fallback path was replaced by the package binary, not signed.
- Installing systemd-boot on a factory (Microsoft keys) machine adds a boot entry first in the order that the firmware refuses, and replaces the removable-media fallback. In the VM nothing bootable remained. With Microsoft keys, enroll the MOK before installing the boot packages, and do not reboot between installing them and finishing the switch.
- `systemd-boot-update.service` (runs `bootctl update` at boot) is disabled on Debian 13. Even when enabled it only copies a newer version, which the apt hook has already re-signed.
- `kernel-install add-all` looks under `/usr/lib/modules/*/vmlinuz`, which Debian does not use.
- Updates to dracut or microcode rebuild the UKI (through dracut's trigger). An update to systemd-stub alone does not.
- Keys at conventional paths do nothing by themselves. Debian's `/usr/lib/kernel/uki.conf` is all comments; without `/etc/kernel/uki.conf` the UKI was built unsigned.

## Kernel module trust

- Debian's kernel accepts modules signed by a key that is only in firmware `db`, without shim. VM, kernel 6.12 with Secure Boot on and lockdown `integrity`: the `db`-signed module loaded; the same module unsigned, and signed with a random key, was refused (`Key was rejected by service`). A real DKMS module signed with the `db` key (`/etc/dkms/framework.conf.d/db-key.conf`) loaded, and was rebuilt and loaded after the upgrade to 7.2.
- Mistake made and corrected: an earlier no-shim run signed the test module with the DKMS key, which was enrolled nowhere, saw `Key was rejected by service`, and concluded that Debian ignores `db` for modules. A module test needs two controls: the same module unsigned must be refused, and the signing key must be the one actually enrolled.
- The Proxmox kernel loaded a DKMS module signed by a certificate that was only in `db`. Host.

## Test bench pitfalls

- A hard power-off right after ESP writes left the FAT inconsistent and the loader unreadable. Power off cleanly.
- MokManager's serial output lags one keypress behind; script a fixed key sequence.
