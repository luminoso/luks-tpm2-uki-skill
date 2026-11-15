# Runs in the finished e2e VM: guide §17 backup + recovery key, old kernel removal, TPM RC decode.
set -ux
DEV=/dev/nvme0n1p2
tpm2_rc_decode 0x128
install -d -m 0700 /root/recovery-backup
cryptsetup luksHeaderBackup $DEV --header-backup-file /root/recovery-backup/luks-header.img
cp -a /var/lib/sbctl /root/recovery-backup/sbctl
cp -a /etc/systemd/tpm2-pcr-private-key.pem /etc/systemd/tpm2-pcr-public-key.pem /etc/kernel/pcrlock-pcrs /root/recovery-backup/
tar -C /root/recovery-backup -cf - . | gpg --batch --pinentry-mode loopback --passphrase test --symmetric --cipher-algo AES256 -o /root/recovery-backup.tar.gpg
rm -rf /root/recovery-backup
gpg --batch --pinentry-mode loopback --passphrase test -d /root/recovery-backup.tar.gpg 2>/dev/null | tar -tf - | head
PASSWORD=testpass systemd-cryptenroll --recovery-key $DEV | tail -2
systemd-cryptenroll $DEV
old=$(dpkg -l 'linux-image-6.12*' | awk '/^ii/{print $2}')
DEBIAN_FRONTEND=noninteractive apt-get purge -yq $old 2>&1 | grep -iE "remov|systemd-boot" | head -5
ls /boot/efi/EFI/Linux
sbctl verify
