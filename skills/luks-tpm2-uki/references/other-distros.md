# Other distributions and derivatives

Only Debian 13 (VM) and Proxmox VE 9 (real host) were tested. Use this page to map the Debian guide onto another system. Everything not marked as tested is a question to check on the target machine, not an answer.

## What carries over unchanged

These are systemd components and behave the same wherever systemd 255 or newer ships them:

- `systemd-cryptenroll` with `--tpm2-pcrlock`, `--tpm2-public-key`, `--tpm2-public-key-pcrs=11`
- `systemd-pcrlock` (`lock-*`, `predict`, `make-policy --pcr= --recovery-pin=query`); it may live outside `$PATH`, e.g. `/usr/lib/systemd/`
- `ukify` with `[PCRSignature:...] Phases=enter-initrd`, systemd-stub, systemd-boot, `bootctl`
- `kernel-install` with `layout=uki` (if the distribution routes kernel installs through it)
- `systemd-pcrphase` in a systemd-based initrd
- All the PCR rules in `pcr-selection.md`, and all the boot-chain rules in `SKILL.md`

## What changes, and how to find out

| Question | How to check | Why it matters |
|---|---|---|
| Which initrd generator, and is it systemd-based? | Package list; for mkinitcpio, the `systemd` and `sd-encrypt` hooks; for dracut, `98dracut-systemd` | `systemd-pcrphase` and TPM tokens need systemd in the initrd |
| Does the generator include `systemd-pcrphase`? | Look inside the built initrd (`lsinitrd`, `lsinitcpio`); after a boot, `systemctl status systemd-pcrphase-initrd` | Without it the signed PCR 11 policy never matches |
| Can something replace the generator behind your back? | Which packages depend on or recommend the distribution's default generator | Debian: microcode recommends initramfs-tools and swapped dracut out |
| Do kernel installs go through `kernel-install`? | Kernel package post-install scripts; `/etc/kernel/postinst.d`; pacman or dnf hooks | Otherwise UKIs are not rebuilt and signed on kernel updates |
| Does the kernel trust `db` certificates for module signatures? | `KEY=<db key> CERT=<db cert> bash testbench/tests/dkms-insmod.sh` signs a test module with the `db` key and loads it, after checking that the unsigned module is refused | Decides between the no-shim chain and shim + MOK when DKMS is needed. Debian 13 and Proxmox VE 9: trusted |
| Is sbctl packaged? | Package search | On Debian it is not |
| How do package hooks run after updates? | apt: `DPkg::Post-Invoke`; pacman: `/etc/pacman.d/hooks`; dnf: actions plugin | The re-sign hook must run after every update that touches boot files |
| Does the systemd-boot or shim package copy files to the ESP on update, and which ones? | Its post-install script | Those are the files the re-sign hook must cover |
| Which certificate is built into the distribution's shim? | `mokutil --export`, or the shim package's certificate file | That is the certificate to deny in MokListX |

## Observed on Debian testing (forky, November 2026)

- systemd 262 moved `systemd-pcrlock`, `systemd-pcrextend` and the `systemd-pcrphase*` units into a new package, `systemd-tpm`. Without it nothing measures the boot phase.
- dracut 112 names the module `systemd-pcrextend`; `add_dracutmodules+=" systemd-pcrphase "` fails the build.

## Observed on Proxmox VE 9

- Debian 13 base, Proxmox kernel (Ubuntu-derived), Proxmox's own `systemd-boot` build.
- The kernel loaded a DKMS module signed by a certificate that was only in firmware `db`, with lockdown on and no shim. On Proxmox, DKMS works with the no-shim chain if DKMS signs with the `db` key.
- Kernel packages recommend `grub-pc` and depend on `initramfs-tools | linux-initramfs-tool`. dracut satisfies the dependency; pin `initramfs-tools` out.
- Do not remove GRUB: `zz-proxmox-boot` fails every kernel install and removal when booted in EFI mode without `grub-efi-amd64`. Keep it installed, marked manual, with `grub2/update_nvram false` and `grub2/force_efi_extra_removable false`. Without `/boot/grub/x86_64-efi/core.efi` its package scripts never run `grub-install`.
- `shim-signed` may be left in state `ic` (install requested, only config files) after its pre-install script refused under your own keys. Pin it to -1; do not purge it if `EFI/proxmox` or `EFI/debian` exists on the ESP, because its postrm then runs `grub-install`.
- `proxmox-boot-tool`'s hook (`zz-proxmox-boot`) does nothing unless `/etc/kernel/proxmox-boot-uuids` exists. Check before adding ESPs to it, since it manages its own copies.
- Proxmox VE 9's kernel runs with IMA active (PCR 10 non-zero). `systemd-pcrlock make-policy` can fail mid-session with `Esys_PolicyPCR ... ErrorCode (0x00000128)` (`TPM_RC_PCR_CHANGED`) when an IMA measurement bumps the TPM PCR update counter; an immediate retry (as in `scripts/pcrlock-update`) succeeds.
- On an LVM-on-LUKS layout (Proxmox root on `pve/root` or `debian-vg/debian-root`), `systemd-pcrlock lock-gpt` with no path inspects `/` and fails with `Disk does not have GPT partition table, refusing.`; pass the ESP's parent disk (`lock-gpt /dev/nvme0n1`).
- When migrating existing DKMS modules from `/var/lib/dkms/mok.key` to `db.key`, `dkms` signs only during `build` (`dkms build --force` then `dkms install --force`), needs kernel headers (`/lib/modules/<kver>/build`) for every retained kernel, and overwrites `mok_signing_key` with a new self-signed key if `mok_certificate` is missing.

## When the target is not Debian

Follow `debian-guide.md` in order and, at each step, answer the matching question above first. Keep the same verification points: UKI has `.pcrsig` with one entry per bank, `systemd-pcrphase-initrd` ran, the policy contains PCR 7, the boot files carry exactly one signature that your firmware or shim trusts, and two plain reboots give the same PCR values.
