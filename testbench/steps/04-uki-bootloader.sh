# Guide §10, option 1 without shim: build UKIs, drop GRUB and shim, firmware starts systemd-boot
# directly, apt hook copies systemd-boot from its package and signs it with your db key.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
ESP=$(bootctl --print-esp-path)
TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)

# Build a signed UKI for every installed kernel first, so something bootable exists before cleanup.
for k in /boot/vmlinuz-*; do
  kernel-install add "${k#/boot/vmlinuz-}" "$k"
done
bootctl list --no-pager | grep -E 'type|id:'

apt-get purge -yq --allow-remove-essential grub-efi-amd64 grub-efi-amd64-signed grub-efi-amd64-bin grub-efi-amd64-unsigned \
  grub-common grub2-common os-prober cryptsetup-initramfs \
  initramfs-tools initramfs-tools-core initramfs-tools-bin
apt-get purge -yq shim-signed shim-signed-common shim-helpers-amd64-signed shim-unsigned systemd-boot-efi-amd64-signed
apt-get autoremove --purge -yq
cat > /etc/apt/preferences.d/no-grub <<'C'
Package: grub-efi-amd64-signed grub-efi-amd64
Pin: release *
Pin-Priority: -1

Package: initramfs-tools initramfs-tools-core
Pin: release *
Pin-Priority: -1

Package: shim-signed shim-helpers-amd64-signed systemd-boot-efi-amd64-signed
Pin: release *
Pin-Priority: -1
C
rm -f "$ESP"/EFI/debian/grub* "$ESP"/EFI/BOOT/grub*
rm -rf "$ESP/EFI/debian"
bootctl install                       # EFI/systemd + fallback EFI/BOOT/BOOTX64.EFI, "Linux Boot Manager" entry first
rm -rf "${ESP:?}/$TOKEN" "$ESP"/loader/entries/"$TOKEN"-*.conf

cat > "$ESP/loader/loader.conf" <<'C'
timeout 3
editor no
C

SB=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
cat > /etc/kernel/esp-signing.conf <<C
KEY=/var/lib/sbctl/keys/db/db.key
CERT=/var/lib/sbctl/keys/db/db.pem
COPY="$SB:$ESP/EFI/systemd/systemd-bootx64.efi $SB:$ESP/EFI/BOOT/BOOTX64.EFI"
FILES="$ESP/EFI/systemd/systemd-bootx64.efi $ESP/EFI/BOOT/BOOTX64.EFI"
C
cat > /usr/local/sbin/resign-esp <<'C'
#!/bin/sh
# Copy boot files from their package (COPY) when the package changed or the ESP copy is not yours,
# then leave every boot file in FILES with exactly one signature: yours. Runs after every apt operation.
set -eu
. /etc/kernel/esp-signing.conf
mkdir -p /var/lib/resign-esp
ours() { [ "$(sbverify --list "$1" 2>/dev/null | grep -c '^signature [0-9]')" = 1 ] && sbverify --cert "$CERT" "$1" >/dev/null 2>&1; }
for pair in $COPY; do
  src=${pair%%:*} dst=${pair#*:} stamp=/var/lib/resign-esp/$(basename "${pair#*:}").sha256
  sum=$(sha256sum < "$src")
  if [ ! -f "$dst" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$sum" ] || ! ours "$dst"; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst" && echo "$sum" > "$stamp" && echo "resign-esp: copied $src to $dst"
  fi
done
for f in $FILES; do
  [ -f "$f" ] || continue
  n=$(sbverify --list "$f" 2>/dev/null | grep -c '^signature [0-9]') || true
  if [ "$n" = 1 ] && sbverify --cert "$CERT" "$f" >/dev/null 2>&1; then continue; fi
  while sbattach --remove "$f" >/dev/null 2>&1; do :; done
  sbsign --key "$KEY" --cert "$CERT" --output "$f" "$f" >/dev/null 2>&1
  echo "resign-esp: signed $f"
done
C
chmod 0755 /usr/local/sbin/resign-esp
cat > /etc/apt/apt.conf.d/99-resign-esp <<'C'
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/resign-esp ]; then /usr/local/sbin/resign-esp; fi"; };
C
/usr/local/sbin/resign-esp

efibootmgr | grep -E 'BootOrder|Linux Boot Manager'
find "$ESP" -type f | sort
for f in $(. /etc/kernel/esp-signing.conf; echo $FILES) "$ESP"/EFI/Linux/*.efi; do sbverify --list "$f" | grep -c '^signature [0-9]' | grep -qx 1; sbverify --cert /var/lib/sbctl/keys/db/db.pem "$f"; done
bootctl list --no-pager
