#!/usr/bin/env bash
# Runs as root inside the builder VM. Installs a stock Debian 13 onto /dev/nvme0n1 with the
# layout the guide assumes: ESP p1, LUKS2 p2 (btrfs, subvolume @rootfs), plus an ext4 /boot (p3)
# so the stock GRUB boot works before the guide moves everything to systemd-boot + UKI.
set -euxo pipefail
D=/dev/nvme0n1
PASS=testpass
MAP=nvme0n1p2_crypt
MIRROR=http://deb.debian.org/debian

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq debootstrap cryptsetup btrfs-progs dosfstools gdisk

sgdisk --zap-all $D
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:-1G -t2:8309 -c2:root -n3:0:0 -t3:8300 -c3:boot $D
partprobe $D || true; udevadm settle

mkfs.vfat -F32 ${D}p1
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --batch-mode ${D}p2 -
echo -n "$PASS" | cryptsetup open ${D}p2 $MAP -
mkfs.btrfs -q -f /dev/mapper/$MAP
mkfs.ext4 -q -F ${D}p3

mount /dev/mapper/$MAP /mnt
btrfs subvolume create /mnt/@rootfs
umount /mnt
mount -o subvol=@rootfs /dev/mapper/$MAP /mnt
mkdir -p /mnt/boot && mount ${D}p3 /mnt/boot
mkdir -p /mnt/boot/efi && mount ${D}p1 /mnt/boot/efi

debootstrap --include=ca-certificates,locales,openssh-server,sudo,less,curl trixie /mnt $MIRROR

LUKS_UUID=$(cryptsetup luksUUID ${D}p2)
BOOT_UUID=$(blkid -s UUID -o value ${D}p3)
ESP_UUID=$(blkid -s UUID -o value ${D}p1)

cat > /mnt/etc/apt/sources.list <<EOF
deb $MIRROR trixie main contrib non-free-firmware
deb $MIRROR trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF
# Same shape d-i writes for a manually partitioned LUKS + btrfs install.
cat > /mnt/etc/fstab <<EOF
/dev/mapper/$MAP /         btrfs defaults,subvol=@rootfs 0 0
UUID=$BOOT_UUID  /boot     ext4  defaults              0 2
UUID=$ESP_UUID   /boot/efi vfat  umask=0077            0 1
EOF
echo "$MAP UUID=$LUKS_UUID none luks,discard" > /mnt/etc/crypttab
echo tpmlab > /mnt/etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 tpmlab\n' > /mnt/etc/hosts
mkdir -p /mnt/etc/systemd/network
printf '[Match]\nName=en*\n[Network]\nDHCP=yes\n' > /mnt/etc/systemd/network/20-wired.network
echo 'nameserver 10.0.2.3' > /mnt/etc/resolv.conf
mkdir -p /mnt/root/.ssh && cp /root/.ssh/authorized_keys /mnt/root/.ssh/ && chmod 700 /mnt/root/.ssh

for f in dev dev/pts proc sys; do mount --bind /$f /mnt/$f; done
chroot /mnt /bin/bash -euxc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq linux-image-amd64 grub-efi-amd64 cryptsetup cryptsetup-initramfs btrfs-progs
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty0 console=ttyS0,115200\"/" /etc/default/grub
  echo GRUB_TERMINAL=\"console serial\" >> /etc/default/grub
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --removable
  update-initramfs -u -k all
  update-grub
  systemctl enable systemd-networkd ssh
  echo root:root | chpasswd
'
umount -R /mnt
cryptsetup close $MAP
echo BUILD-OK
