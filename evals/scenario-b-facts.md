# Scenario B: host facts

Collected read-only from a real Proxmox VE 9.2 host on Debian 13 (names anonymized). Kernel 7.0.14-28-pve running, 7.0.14-29-pve installed the same day.

- Disk: /dev/nvme0n1p1 vfat ESP on /boot/efi (fmask/dmask 0077); /dev/nvme0n1p2 LUKS2 -> LVM -> ext4 root.
- /proc/cmdline and /etc/kernel/cmdline: root=UUID=... rd.luks.name=<uuid>=nvme0n1p2_crypt rd.luks.options=tpm2-device=auto intel_iommu=on iommu=pt i915.enable_guc=3 i915.max_vfs=7 module_blacklist=xe (cmdline also has systemd.machine_id=...)
- /etc/crypttab: nvme0n1p2_crypt UUID=... none luks,discard,x-initrd.attach,tpm-device=auto
- bootctl status: Secure Boot enabled (user); TPM2 support yes; Measured UKI yes; boot loader systemd-boot 257.13-1~deb13u1; Current Entry e7cf...-7.0.14-28-pve.efi; Default Entry b2338...-6.17.4-2-pve.efi
- efivar LoaderEntries at this boot: "e7cf...-7.0.14-28-pve.efi auto-reboot-to-firmware-setup"; LoaderEntryDefault: b2338...-6.17.4-2-pve.efi
- efibootmgr: BootOrder 0000; Boot0000 "Linux Boot Manager" -> \EFI\systemd\systemd-bootx64.efi (only entry)
- ESP files: EFI/keys/{db.esl,mok-dkms.der,mok-dkms.pub,PK.auth,PK.esl}, EFI/Linux/e7cf...-7.0.14-28-pve.efi, EFI/Linux/e7cf...-7.0.14-29-pve+2.efi, EFI/systemd/systemd-bootx64.efi, loader/credentials/pcrlock.<id>.cred, loader/loader.conf, loader/random-seed, loader/entries.srel. All .efi signed by "CN=Owner db key" only.
- loader.conf: timeout 5; default e7cf...-*
- Firmware key lists: PK "Owner PK", KEK "Owner KEK", db: "Owner db key" and "DKMS module signing key"; dbx absent; no hashes in db.
- Packages installed: dkms, dracut 106, efibootmgr, grub-common, grub-efi-amd64-signed, grub-pc, grub-pc-bin, grub2-common (Proxmox builds), intel-microcode, lvm2, proxmox-kernel-7.0.14-26/28/29-pve-signed, proxmox-kernel-helper, sbsigntool, efitools, systemd 257.13, systemd-boot 257.13-1+pmx1, systemd-boot-efi, systemd-boot-efi-amd64-signed, systemd-cryptsetup, systemd-ukify, tpm2-tools. NOT installed: shim, mokutil, sbctl, initramfs-tools.
- Proxmox kernel packages: Depends "initramfs-tools | linux-initramfs-tool"; Recommends "grub-pc | grub-efi-amd64 | ...".
- debconf grub-pc: install_devices empty; install_devices_failed_upgrade: true.
- /etc/kernel/install.conf: layout=uki, initrd_generator=dracut, uki_generator=ukify. /etc/kernel/postinst.d: dkms, dracut, proxmox-auto-removal, zz-proxmox-boot, zz-systemd-boot, zz-update-grub. No /etc/kernel/proxmox-boot-uuids.
- /etc/kernel/uki.conf: [UKI] Cmdline=@/etc/kernel/cmdline, SecureBootSigningTool=sbsign, SecureBootPrivateKey=/etc/secureboot/keys/db.key, SecureBootCertificate=/etc/secureboot/keys/db.crt; [PCRSignature:initrd] Phases=enter-initrd, PCRPrivateKey/PCRPublicKey in /etc/secureboot/keys/.
- /etc/secureboot/keys (0700 root): PK.key, PK.crt, PK.esl, PK.auth, KEK.key, KEK.crt, KEK.esl, db.key, db.crt, db.cer, db.esl, tpm2-pcr-private-key.pem, tpm2-pcr-public-key.pem.
- /etc/dracut.conf.d: hostonly_cmdline="no"; add_dracutmodules+=" tpm2-tss systemd-cryptsetup "; install_items+=" /usr/lib/systemd/systemd-pcrlock /etc/machine-id ".
- systemd-pcrphase-initrd.service ran in this boot; disk opened 1 s after cryptsetup started; no unseal errors in journal.
- LUKS2: keyslots 1 and 2; token "systemd-tpm2" on keyslot 2: tpm2-pubkey-pcrs 11, tpm2-pin false, tpm2-pcrlock true. Keyslot 1 has no token.
- /var/lib/systemd/pcrlock.json: PCRs 0,1,2,3,7,13,14.
- dkms status: led-ugreen/0.3 installed for 7.0.14-26/28/29; module loaded, signer "DKMS module signing key"; kernel lockdown: integrity.
- /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed: dated May 18 (rest of package April 13), signed by "Owner db key"; dpkg --verify reports it modified (checksum).
- /etc/apt/apt.conf.d: no hook that signs anything. /etc/apt/preferences.d: empty.
- No EFI/BOOT/BOOTX64.EFI on the ESP.
