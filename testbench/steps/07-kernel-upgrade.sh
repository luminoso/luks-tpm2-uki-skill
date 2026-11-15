set -euxo pipefail
# Test only: a newer kernel from KERNEL_SUITE (trixie-backports; on testing, unstable). No resealing should be needed.
K=${KERNEL_SUITE:-trixie-backports}
echo "deb http://deb.debian.org/debian $K main contrib non-free-firmware" > /etc/apt/sources.list.d/newer-kernel.list
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -yq -t "$K" linux-image-amd64 linux-headers-amd64   # headers: DKMS rebuilds for the new kernel
ls -la /boot/efi/EFI/Linux/
if command -v sbctl >/dev/null; then sbctl verify; fi
