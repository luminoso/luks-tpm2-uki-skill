# Guide §12, option 1: DKMS signs modules with your db key. Debian's kernel trusts db keys for modules.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -yq dkms
openssl x509 -in /var/lib/sbctl/keys/db/db.pem -outform DER -out /var/lib/sbctl/keys/db/db.der
mkdir -p /etc/dkms/framework.conf.d
printf 'mok_signing_key=/var/lib/sbctl/keys/db/db.key\nmok_certificate=/var/lib/sbctl/keys/db/db.der\n' > /etc/dkms/framework.conf.d/db-key.conf
cat /etc/dkms/framework.conf.d/db-key.conf
