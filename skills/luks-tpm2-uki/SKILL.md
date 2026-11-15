---
name: luks-tpm2-uki
description: Use when setting up, auditing or fixing automatic LUKS2 disk decryption from a TPM2 without a PIN, with signed Unified Kernel Images (ukify, kernel-install), systemd-boot, systemd-cryptenroll, systemd-pcrlock and Secure Boot (own keys, sbctl, shim, MOK, DKMS module signing), on Debian, Proxmox, Ubuntu or other distributions, when choosing which TPM PCRs to bind, or before a firmware update, BIOS change or reboot on such a machine.
---

# LUKS2 + TPM2 + signed UKI

## Overview

Goal: the TPM releases the disk key only to the user's own signed UKI, inside the initrd, with Secure Boot on. Every rule below either keeps that true across updates, or lets the user choose which changes (BIOS settings, docks, firmware updates) should cost them a passphrase prompt.

Everything here was tested in a QEMU/OVMF/swtpm VM and on a real Proxmox host. The repository's `testbench/` reproduces it.

## How to work on the user's machine

- Audit before changing anything. Run `bash scripts/audit.sh` as the user, then give the user the same command to run with `sudo` and ask for the output. Read it fully before proposing changes.
- Never run `sudo` yourself unless the user says so. Hand root commands to the user.
- Deliver changes as a script the user runs, with a check before each step, backups, and a stop on the first error.
- Firmware variables (PK, KEK, db, dbx, MOK lists) and the LUKS header are the two places where a mistake can lock the user out. Before touching either: back up, plan the pcrlock update for PCR 7 (see `references/pcr-selection.md`), and make sure the user has the passphrase. Test the sequence in a VM first when you can.
- Before the user reboots after any change to boot files, keys, firmware variables or the policy, have them run `check-next-boot` as root.
- Mark every statement as verified on this host, or not verified.

## Pick the reference

| Task | Read |
|---|---|
| New setup on Debian 13 | `references/debian-guide.md`, after the decisions below |
| Other distribution or derivative | `references/other-distros.md`, then the guide |
| Audit or fix an existing setup | `references/audit.md` |
| Choosing PCRs (always, for setup and audit) | `references/pcr-selection.md` |
| Why a rule exists, with test evidence | `references/lessons.md` |

## Decide with the user, in this order

1. **Out-of-tree kernel modules (DKMS: NVIDIA, VirtualBox, ZFS)?** If yes, check that this kernel accepts modules signed by a key that is only in firmware `db` (`testbench/tests/dkms-insmod.sh`, which also checks that an unsigned module is refused). Debian 13's kernel (6.12 and 7.2) and Proxmox VE 9's accept them (tested). Upstream Linux keeps `db` keys for kexec only.
2. **Own Secure Boot keys, or keep Microsoft's?** Microsoft's are needed for Windows dual boot, firmware that cannot enter Setup Mode, or add-in cards whose option ROMs you cannot enroll by hash.
3. **Which PCRs** (`references/pcr-selection.md`).

| DKMS needed | Kernel trusts `db` for modules | Boot chain |
|---|---|---|
| no | n/a | No shim: firmware, systemd-boot signed by you, UKI |
| yes | yes (Debian, Proxmox) | No shim; DKMS signs with your `db` key (`/etc/dkms/framework.conf.d/`: `mok_signing_key`, `mok_certificate`) |
| yes | no | shim + MOK, and shim must deny the distribution's own certificate (MokListX). Own keys: `shim-unsigned` signed by you. Microsoft keys: `shim-signed`. |

Microsoft keys kept (option 2) always means shim + MOK + MokListX.

## Operations after setup

Offer these on every setup and audit. Each was tested in the VM; install them from `scripts/` to `/usr/local/sbin/`.

| Tool | What it is for |
|---|---|
| `check-next-boot` | Read-only: will the next boot open the disk from the TPM? Signature, `.pcrsig`, PCR key, command line and `systemd-pcrphase` of the default UKI; ESP files; LUKS token; stale policy; PCR 1 and PCR 7 changes since this boot |
| `pcrlock-update open 0,1,2,3` / `close` | Planned firmware update or BIOS change without a passphrase prompt. A different firmware build changed PCRs 0, 1 and 2 in the VM, so `open 0,2` was not enough |
| `tpm-unlock-check` + `.service` | Mail to root and a critical journal line when the disk was opened by passphrase or recovery key |
| `/etc/kernel/tries` | Boot counting: a UKI that fails 3 times is skipped and the previous kernel starts |
| `systemd-cryptenroll --recovery-key` | Second fallback, shown once, never stored on the host |

## Rules that failed in testing when missing

| Rule | What happened without it |
|---|---|
| PCR 7 is always in the policy | Key released with Secure Boot off |
| PCR 11 is bound by signature (`--tpm2-public-key`), signed for `Phases=enter-initrd` only | Default phases let the booted system unseal |
| systemd initrd (dracut) with `systemd-pcrphase`; `initramfs-tools` pinned out | No pcrphase: policy never matches. A microcode package pulled `initramfs-tools` in, removed dracut, boot stopped in a passwordless BusyBox shell |
| Never lock PCR 12 with pcrlock; never bind PCR 8 | pcrlock's own ESP credential lands in PCR 12; PCR 8 is always zero here |
| `make-policy --pcr=<list> --recovery-pin=query` when creating the policy, and when the machine no longer matches it | Default hidden PIN: policy unrepairable without re-enrolling. Leave the option out for updates while the machine still matches: with it, `make-policy` always uses the PIN |
| With shim: deny the distribution certificate in MokListX, re-sign systemd-boot and MokManager with your key | Stock Debian kernel + attacker initrd replayed PCR 7 and 11, TPM released the key |
| Re-sign hook after every apt/dnf run, leaving exactly one signature (yours); `sbctl sign` adds a second one | systemd-boot or shim update put a refused binary on the ESP |
| Passphrase slot kept, signed `EFI/BOOT/BOOTX64.EFI` fallback present | Lost NVRAM entry or TPM refusal leaves no way in |
| PCR set checked stable across two plain reboots before sealing | Some firmware measures changing data |
| `rd.shell=0 rd.emergency=halt` in the UKI command line | A shell after a forced initrd failure still has matching PCRs; with these the initrd halts (tested) |
| Do not lock PCR 4 unless something re-locks it on every UKI and loader update | Every kernel update falls back to the passphrase |

## Common mistakes

- `apt install sbctl`: not packaged in Debian. Build the signed upstream release, or use `efitools` + `sbsign`.
- `systemd-pcrlock` is in `/usr/lib/systemd/`, not in `$PATH`.
- On Proxmox, do not remove GRUB: its kernel hook fails without `grub-efi-amd64`. Keep it installed and unable to write NVRAM or the fallback path.
- `systemd-pcrlock remove-policy` orphans the LUKS token: the next `make-policy` creates a new NV index and every boot asks for the passphrase until `systemd-cryptenroll --wipe-slot=tpm2 ...` is run again. To re-lock, just run `make-policy` again.
- Some firmware creates its own boot entry when `EFI/BOOT/BOOTX64.EFI` appears, which changes PCR 1 on the next boot.
- `kernel-install add-all` finds no kernels on Debian. Loop over `/boot/vmlinuz-*`.
- fwupd/LVFS `dbx` updates cannot apply under your own KEK.
- Creating a firmware boot entry (`efibootmgr --create`) changes PCR 1. If PCR 1 is locked, plan the re-lock.
- In an audit, a hand-modified `systemd-bootx64.efi.signed` is usually a manual re-sign, not tampering: the risk is the next package update reverting it.
