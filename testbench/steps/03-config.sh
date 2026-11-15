# Guide §8-9: crypttab, kernel cmdline, dracut, kernel-install, ukify, PCR signing key.
set -euxo pipefail
DEV=/dev/nvme0n1p2
NAME=nvme0n1p2_crypt
UUID=$(cryptsetup luksUUID $DEV)
EXTRA=${EXTRA_CMDLINE:-}   # test bench adds console=ttyS0,115200 here

echo "$NAME UUID=$UUID none luks,discard,tpm2-device=auto,x-initrd.attach" > /etc/crypttab

echo "rd.luks.name=$UUID=$NAME rd.luks.options=$UUID=tpm2-device=auto,discard root=/dev/mapper/$NAME rootflags=subvol=@rootfs rw quiet rd.shell=0 rd.emergency=halt $EXTRA" > /etc/kernel/cmdline

# dracut 106 (Debian 13) calls the module systemd-pcrphase; newer dracut (testing) systemd-pcrextend.
PCRMOD=systemd-pcrphase; ls -d /usr/lib/dracut/modules.d/*systemd-pcrphase >/dev/null 2>&1 || PCRMOD=systemd-pcrextend
cat > /etc/dracut.conf.d/50-tpm2-uki.conf <<C
hostonly="yes"
hostonly_cmdline="no"
compress="zstd"
add_dracutmodules+=" systemd-cryptsetup $PCRMOD tpm2-tss btrfs "
omit_dracutmodules+=" network cifs nfs iscsi nbd "
C

cat > /etc/kernel/install.conf <<'C'
layout=uki
initrd_generator=dracut
uki_generator=ukify
C

# Key that signs the expected PCR 11 values. Only valid for the enter-initrd phase.
(umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /etc/systemd/tpm2-pcr-private-key.pem)
openssl pkey -in /etc/systemd/tpm2-pcr-private-key.pem -pubout -out /etc/systemd/tpm2-pcr-public-key.pem

SB_KEY=${SB_KEY:-/var/lib/sbctl/keys/db/db.key}     # option 2: /etc/kernel/secure-boot-private-key.pem
SB_CERT=${SB_CERT:-/var/lib/sbctl/keys/db/db.pem}   # option 2: /etc/kernel/secure-boot-certificate.pem
cat > /etc/kernel/uki.conf <<C
[UKI]
SecureBootPrivateKey=$SB_KEY
SecureBootCertificate=$SB_CERT
PCRPKey=/etc/systemd/tpm2-pcr-public-key.pem

[PCRSignature:initrd]
PCRPrivateKey=/etc/systemd/tpm2-pcr-private-key.pem
PCRPublicKey=/etc/systemd/tpm2-pcr-public-key.pem
Phases=enter-initrd
C
cat /etc/crypttab /etc/kernel/cmdline
