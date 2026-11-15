# Guide §14: boot counting. New UKIs get "+3" in their name; systemd-boot counts down on each start,
# systemd-bless-boot removes the counter once the system is up, and an entry at "+0" is skipped.
set -euxo pipefail
echo 3 > /etc/kernel/tries
ESP=$(bootctl --print-esp-path)
T=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)
# Rebuild existing UKIs with a counter; drop the uncounted copy only once the new one exists.
for k in /boot/vmlinuz-*; do
  v=${k#/boot/vmlinuz-}
  kernel-install add "$v" "$k"
  [ -f "$ESP/EFI/Linux/$T-$v+3.efi" ] && rm -f "$ESP/EFI/Linux/$T-$v.efi"
done
ls "$ESP"/EFI/Linux/
ls "$ESP"/EFI/Linux/ | grep -q '+3\.efi$'
systemctl is-enabled tpm-unlock-check.service
