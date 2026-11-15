# Test only: upgrade to the trixie-backports kernel. No resealing should be needed.
set -euxo pipefail
echo "deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware" > /etc/apt/sources.list.d/backports.list
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -yq -t trixie-backports linux-image-amd64
ls -la /boot/efi/EFI/Linux/
if command -v sbctl >/dev/null; then sbctl verify; fi
