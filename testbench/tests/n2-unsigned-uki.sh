# Attacker drops a modified (unsigned) UKI on the ESP and makes it the next boot.
set -eux
ESP=/boot/efi
U=$(ls $ESP/EFI/Linux/*.efi | sort -V | tail -1)
cp "$U" /tmp/evil.efi
sbattach --remove /tmp/evil.efi
cp /tmp/evil.efi $ESP/EFI/Linux/evil.efi
sbctl verify 2>&1 | grep evil || true
bootctl set-oneshot evil.efi
sync
