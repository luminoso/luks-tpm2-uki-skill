# Guide §7: packages for both options. Installing dracut removes initramfs-tools (expected).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq systemd-boot systemd-ukify systemd-cryptsetup dracut tpm2-tools sbsigntool efibootmgr mokutil dkms
