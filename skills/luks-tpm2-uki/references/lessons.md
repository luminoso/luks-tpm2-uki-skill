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

## Boot chain

- Stock Debian kernel + attacker initrd got the key when shim (which trusts Debian's certificate) was in the chain. The attack path's PCR 7 was the legitimate list minus its final entry, so the initrd replayed it and the UKI's PCR 11 measurements. VM, both shim options, `tests/n5-*`. Closed by denying Debian's certificate in MokListX: shim refused the kernel ("Security Policy Violation") and the refusal itself extended PCR 7.
- Attacker MOK enrolled at the console does not change locked PCRs (the disk still opens), but a kernel approved by it adds a PCR 7 entry that cannot be undone. TPM refused. VM.
- No-shim chain refused the Debian kernel at the firmware ("Access denied"). VM.
- Command line injection through an extra boot entry (`init=/bin/sh`) was ignored by systemd-stub under Secure Boot. VM, `tests/n1-cmdline-inject.sh`.
- Planted TPM-sealed credential (`systemd.extra-unit.*`) in `ESP/loader/credentials/` was received as untrusted and not applied. VM.
- Forced initrd failure (LUKS header UUID changed, no key needed) reached dracut's emergency mode, which refused a shell because the root account is locked inside the initrd. VM. The initramfs-tools initrd, in an earlier failure, gave a passwordless BusyBox shell. With `rd.shell=0 rd.emergency=halt` in the UKI command line, the same forced failure printed "Could not boot. Halting." and stopped; normal boots still opened automatically. VM, no-shim chain.

## Packages and updates

- sbctl is not packaged in Debian (trixie, backports, sid). It builds from the signed upstream tarball with trixie's Go (`GOTOOLCHAIN=local`). Keys in `/var/lib/sbctl/keys`.
- `sbctl sign` adds a signature next to an existing one. With the distribution's certificate denied, a file carrying both is refused. The `resign-esp` script strips and re-signs instead.
- systemd-boot package updates run `bootctl update`, which copies `systemd-bootx64.efi.signed` (the distribution's signature) to the ESP if present. Without a re-sign hook, firmware with only your keys refuses it.
- `shim-signed`'s pre-install script refuses to install or upgrade when Secure Boot is on and no Microsoft certificate is in `db` ("FATAL ERROR - your system will not currently boot with this signed shim installed"), leaving dpkg half-configured. With own keys use `shim-unsigned`, signed by you, in a directory the systemd-boot package does not manage (it deletes `EFI/debian/shim*` when `shim-signed` is absent).
- Debian's GRUB signed package is protected: purging it needs `--allow-remove-essential` or a typed confirmation.
- `intel-microcode` recommends initramfs-tools; installing it removed dracut and the next boot stopped in a BusyBox shell. A pin to -1 fixes it; dracut then rebuilds the UKI with the microcode.
- Proxmox kernels recommend `grub-pc`, so purged GRUB comes back with the next kernel unless pinned.
- Installing systemd-boot on a factory (Microsoft keys) machine adds a boot entry first in the order that the firmware refuses, and replaces the removable-media fallback. In the VM nothing bootable remained. With Microsoft keys, enroll the MOK before installing the boot packages, and do not reboot between installing them and finishing the switch.
- `systemd-boot-update.service` (runs `bootctl update` at boot) is disabled on Debian 13. Even when enabled it only copies a newer version, which the apt hook has already re-signed.
- `kernel-install add-all` looks under `/usr/lib/modules/*/vmlinuz`, which Debian does not use.
- Updates to dracut or microcode rebuild the UKI (through dracut's trigger). An update to systemd-stub alone does not.
- Keys at conventional paths do nothing by themselves. Debian's `/usr/lib/kernel/uki.conf` is all comments; without `/etc/kernel/uki.conf` the UKI was built unsigned.

## Kernel module trust

- Debian's kernel refused a module signed with Debian's DKMS key without shim (`Key was rejected by service`). `db` certificates land in the `.platform` keyring, which Debian does not use for modules; MOK keys reach `.machine` only through shim.
- The Proxmox kernel loaded a DKMS module signed by a certificate that was only in `db`. Host. So on Proxmox the no-shim chain works with DKMS, signed by the `db` key.

## Test bench pitfalls

- A hard power-off right after ESP writes left the FAT inconsistent and the loader unreadable. Power off cleanly.
- MokManager's serial output lags one keypress behind; script a fixed key sequence.
