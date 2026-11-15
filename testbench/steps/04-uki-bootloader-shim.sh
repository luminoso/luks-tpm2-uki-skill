# Guide §10, both options: build UKIs, remove GRUB, put shim in front of systemd-boot, re-sign the boot
# files with your key, apt re-sign hook.
#   Option 1: shim-unsigned, copied to ESP/EFI/shim/ and signed by you (no Microsoft signature needed,
#             and shim-signed's pre-install check would refuse to install under your keys anyway).
#   Option 2: shim-signed (Microsoft-signed), laid out by Debian's systemd-boot package in ESP/EFI/debian/.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
ESP=$(bootctl --print-esp-path)
TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)
if [ -d /var/lib/sbctl/keys ]; then OPTION=1; else OPTION=2; fi

# Build a signed UKI for every installed kernel first, so something bootable exists before cleanup.
for k in /boot/vmlinuz-*; do
  kernel-install add "${k#/boot/vmlinuz-}" "$k"
done
bootctl list --no-pager | grep -E 'type|id:'

apt-get purge -yq --allow-remove-essential grub-efi-amd64 grub-efi-amd64-signed grub-efi-amd64-bin \
  grub-efi-amd64-unsigned grub-common grub2-common os-prober cryptsetup-initramfs \
  initramfs-tools initramfs-tools-core initramfs-tools-bin
if [ $OPTION = 1 ]; then
  apt-get purge -yq shim-signed shim-signed-common shim-helpers-amd64-signed systemd-boot-efi-amd64-signed
  apt-get install -yq shim-unsigned mokutil
else
  apt-get install -yq shim-signed systemd-boot-efi-amd64-signed mokutil
fi
apt-get autoremove --purge -yq
{
  if [ $OPTION = 1 ]; then
    printf 'Package: grub-efi-amd64-signed grub-efi-amd64 shim-signed shim-helpers-amd64-signed systemd-boot-efi-amd64-signed\n'
  else
    printf 'Package: grub-efi-amd64-signed grub-efi-amd64\n'
  fi
  printf 'Pin: release *\nPin-Priority: -1\n\n'
  printf 'Explanation: microcode packages recommend initramfs-tools, which would replace dracut in the UKI\n'
  printf 'Package: initramfs-tools initramfs-tools-core\nPin: release *\nPin-Priority: -1\n'
} > /etc/apt/preferences.d/no-grub
rm -rf "$ESP"/EFI/debian/grub* "$ESP"/EFI/BOOT/grub*

if [ $OPTION = 1 ]; then
  rm -rf "$ESP/EFI/debian"
  bootctl install --no-variables          # restore EFI/BOOT/BOOTX64.EFI (systemd-boot) as removable fallback
  install -d "$ESP/EFI/shim"
  KEY=/var/lib/sbctl/keys/db/db.key CERT=/var/lib/sbctl/keys/db/db.pem
  COPY="/usr/lib/shim/shimx64.efi:$ESP/EFI/shim/shimx64.efi /usr/lib/shim/mmx64.efi:$ESP/EFI/shim/mmx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi:$ESP/EFI/systemd/systemd-bootx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi:$ESP/EFI/BOOT/BOOTX64.EFI"
  FILES="$ESP/EFI/shim/shimx64.efi $ESP/EFI/shim/mmx64.efi $ESP/EFI/systemd/systemd-bootx64.efi $ESP/EFI/BOOT/BOOTX64.EFI"
else
  dpkg-reconfigure systemd-boot          # with signed GRUB gone, this puts shim-signed in front
  KEY=/etc/kernel/secure-boot-private-key.pem CERT=/etc/kernel/secure-boot-certificate.pem
  COPY="/usr/lib/systemd/boot/efi/systemd-bootx64.efi:$ESP/EFI/systemd/systemd-bootx64.efi"
  FILES="$ESP/EFI/systemd/systemd-bootx64.efi $ESP/EFI/debian/mmx64.efi $ESP/EFI/debian/fbx64.efi $ESP/EFI/BOOT/mmx64.efi $ESP/EFI/BOOT/fbx64.efi"
fi

# Now drop the Type #1 entries the systemd-boot package created.
rm -rf "${ESP:?}/$TOKEN" "$ESP"/loader/entries/"$TOKEN"-*.conf

cat > "$ESP/loader/loader.conf" <<'C'
timeout 3
editor no
C

# Signing hook: copy shim from its package (option 1), then leave every boot file with exactly one
# signature, yours. Debian's signature is stripped: once Debian's certificate is denied in shim
# (section 12), a file that still carries it is refused even with yours next to it.
cat > /etc/kernel/esp-signing.conf <<C
KEY=$KEY
CERT=$CERT
COPY="$COPY"
FILES="$FILES"
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

if [ $OPTION = 1 ]; then
  # Boot entry: firmware starts your shim, shim starts systemd-boot (same form as Debian's own entry).
  part=$(findmnt -nvo SOURCE "$ESP"); disk=/dev/$(lsblk -no PKNAME "$part"); num=$(cat /sys/class/block/${part##*/}/partition)
  efibootmgr -q --create --disk "$disk" --part "$num" --loader '\EFI\shim\shimx64.efi' \
    --label 'Debian (own shim)' --unicode '\EFI\systemd\systemd-bootx64.efi \0'
fi

find "$ESP" -type f | sort
efibootmgr
bootctl list --no-pager | grep -E 'type|id:'
for f in $FILES; do [ -f "$f" ] && { echo "$f"; sbverify --list "$f" | grep subject; }; done
