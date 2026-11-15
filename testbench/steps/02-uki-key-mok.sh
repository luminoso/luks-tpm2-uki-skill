# Guide §6, option 2 (before installing the boot packages): no sbctl, no Setup Mode. Create a UKI signing key and enroll it (plus the DKMS
# module key) as MOKs. The import is confirmed in MokManager on the next boot.
set -euxo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -yq mokutil dkms
(umask 077; openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -subj "/CN=$(hostname) UKI signing key/" \
  -keyout /etc/kernel/secure-boot-private-key.pem -out /etc/kernel/secure-boot-certificate.pem)
openssl x509 -in /etc/kernel/secure-boot-certificate.pem -outform DER -out /etc/kernel/secure-boot-certificate.der
dkms generate_mok
mokutil --import /etc/kernel/secure-boot-certificate.der /var/lib/dkms/mok.pub ${MOK_HASH_FILE:+--hash-file "$MOK_HASH_FILE"}   # test bench: no prompt
mokutil --list-new | grep 'Subject:'
