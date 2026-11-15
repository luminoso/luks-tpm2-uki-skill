---
name: luks-tpm2-uki
description: Use when setting up, auditing or fixing automatic LUKS2 disk decryption from a TPM2 without a PIN, with signed Unified Kernel Images (ukify, kernel-install), systemd-boot, systemd-cryptenroll, systemd-pcrlock and Secure Boot (own keys, sbctl, shim, MOK, DKMS module signing), on Debian, Proxmox, Ubuntu or other distributions, or when choosing which TPM PCRs to bind.
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

1. **Out-of-tree kernel modules (DKMS: NVIDIA, VirtualBox, ZFS)?** If yes, test whether this kernel accepts modules signed by a key that is only in firmware `db`. Debian kernels refuse them (`Key was rejected by service`). The Ubuntu-derived Proxmox kernel accepts them.
2. **Own Secure Boot keys, or keep Microsoft's?** Microsoft's are needed for Windows dual boot, firmware that cannot enter Setup Mode, or add-in cards whose option ROMs you cannot enroll by hash.
3. **Which PCRs** (`references/pcr-selection.md`).

| DKMS needed | Kernel trusts `db` for modules | Boot chain |
|---|---|---|
| no | n/a | No shim: firmware, systemd-boot signed by you, UKI |
| yes | yes | No shim; DKMS signs with your `db` key |
| yes | no | shim + MOK, and shim must deny the distribution's own certificate (MokListX). Own keys: `shim-unsigned` signed by you. Microsoft keys: `shim-signed`. |

## Rules that failed in testing when missing

| Rule | What happened without it |
|---|---|
| PCR 7 is always in the policy | Key released with Secure Boot off |
| PCR 11 is bound by signature (`--tpm2-public-key`), signed for `Phases=enter-initrd` only | Default phases let the booted system unseal |
| systemd initrd (dracut) with `systemd-pcrphase`; `initramfs-tools` pinned out | No pcrphase: policy never matches. A microcode package pulled `initramfs-tools` in, removed dracut, boot stopped in a passwordless BusyBox shell |
| Never lock PCR 12 with pcrlock; never bind PCR 8 | pcrlock's own ESP credential lands in PCR 12; PCR 8 is always zero here |
| `make-policy --pcr=<list> --recovery-pin=query` | Default hidden PIN: policy unrepairable without re-enrolling |
| With shim: deny the distribution certificate in MokListX, re-sign systemd-boot and MokManager with your key | Stock Debian kernel + attacker initrd replayed PCR 7 and 11, TPM released the key |
| Re-sign hook after every apt/dnf run, leaving exactly one signature (yours); `sbctl sign` adds a second one | systemd-boot or shim update put a refused binary on the ESP |
| Passphrase slot kept, signed `EFI/BOOT/BOOTX64.EFI` fallback present | Lost NVRAM entry or TPM refusal leaves no way in |
| PCR set checked stable across two plain reboots before sealing | Some firmware measures changing data |
| `rd.shell=0 rd.emergency=halt` in the UKI command line | A shell after a forced initrd failure still has matching PCRs; with these the initrd halts (tested) |
| Do not lock PCR 4 unless something re-locks it on every UKI and loader update | Every kernel update falls back to the passphrase |

## Common mistakes

- `apt install sbctl`: not packaged in Debian. Build the signed upstream release, or use `efitools` + `sbsign`.
- `systemd-pcrlock` is in `/usr/lib/systemd/`, not in `$PATH`.
- `kernel-install add-all` finds no kernels on Debian. Loop over `/boot/vmlinuz-*`.
- fwupd/LVFS `dbx` updates cannot apply under your own KEK.
- Creating a firmware boot entry (`efibootmgr --create`) changes PCR 1. If PCR 1 is locked, plan the re-lock.
- In an audit, a hand-modified `systemd-bootx64.efi.signed` is usually a manual re-sign, not tampering: the risk is the next package update reverting it.
