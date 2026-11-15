# Guide §6, option 1: build sbctl 0.18 from the signed upstream release, create Secure Boot keys.
set -euxo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -yq golang-go gpg libpcsclite-dev pkgconf
cd /root
V=0.18
curl -fsSLO https://github.com/Foxboron/sbctl/releases/download/$V/sbctl-$V.tar.gz
curl -fsSLO https://github.com/Foxboron/sbctl/releases/download/$V/sbctl-$V.tar.gz.sig
gpg --keyserver hkps://keys.openpgp.org --recv-keys C100346676634E80C940FB9E9C02FF419FECBE16
gpg --verify sbctl-$V.tar.gz.sig sbctl-$V.tar.gz
tar xzf sbctl-$V.tar.gz
cd sbctl-$V
GOTOOLCHAIN=local go build -trimpath -o sbctl ./cmd/sbctl
install -m 0755 sbctl /usr/local/bin/sbctl
sbctl status
sbctl create-keys
sbctl status
find /var/lib/sbctl -maxdepth 3 | sort
