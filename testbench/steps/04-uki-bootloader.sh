# Guide §10: build UKIs, drop GRUB/shim, lock systemd-boot, sign the bootloader, apt re-sign hook.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
ESP=$(bootctl --print-esp-path)
TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)

# Build a signed UKI for every installed kernel first, so something bootable exists before cleanup.
for k in /boot/vmlinuz-*; do
  kernel-install add "${k#/boot/vmlinuz-}" "$k"
done
bootctl list --no-pager | grep -E 'type|id:'

# GRUB and shim are signed for the Microsoft chain. With only your own keys enrolled they cannot boot,
# and shim-signed makes the systemd-boot postinst put shim back in front of systemd-boot.
apt-get purge -yq --allow-remove-essential grub-efi-amd64 grub-efi-amd64-signed grub-efi-amd64-bin grub-efi-amd64-unsigned \
  grub-common grub2-common os-prober shim-signed shim-signed-common shim-helpers-amd64-signed \
  shim-unsigned mokutil systemd-boot-efi-amd64-signed cryptsetup-initramfs \
  initramfs-tools initramfs-tools-core initramfs-tools-bin
apt-get autoremove --purge -yq
cat > /etc/apt/preferences.d/no-shim-grub <<'C'
Package: shim-signed grub-efi-amd64-signed systemd-boot-efi-amd64-signed
Pin: release *
Pin-Priority: -1

Explanation: microcode packages recommend initramfs-tools, which would replace dracut in the UKI
Package: initramfs-tools initramfs-tools-core
Pin: release *
Pin-Priority: -1
C
rm -rf "$ESP/EFI/debian" "$ESP/EFI/BOOT"
bootctl install
# Now drop the Type #1 entries the systemd-boot package created.
rm -rf "${ESP:?}/$TOKEN" "$ESP"/loader/entries/"$TOKEN"-*.conf


cat > "$ESP/loader/loader.conf" <<'C'
timeout 3
editor no
C

sbctl sign -s "$ESP/EFI/systemd/systemd-bootx64.efi"
sbctl sign -s "$ESP/EFI/BOOT/BOOTX64.EFI"

# systemd-boot package upgrades run "bootctl update", which copies an unsigned binary to the ESP.
cat > /etc/apt/apt.conf.d/99-sbctl-sign <<'C'
DPkg::Post-Invoke { "if [ -x /usr/local/bin/sbctl ]; then /usr/local/bin/sbctl sign-all; fi"; };
C

find "$ESP" -type f | sort
sbctl verify
bootctl list --no-pager
