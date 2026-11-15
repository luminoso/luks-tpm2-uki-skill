# Guide §7: packages for both options. Installing dracut removes initramfs-tools (expected).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# Debian testing (systemd 262) moved systemd-pcrlock and the pcrphase units into systemd-tpm.
TPM=""; apt-cache show systemd-tpm >/dev/null 2>&1 && TPM=systemd-tpm
apt-get install -yq systemd-boot systemd-ukify systemd-cryptsetup $TPM dracut tpm2-tools sbsigntool efibootmgr mokutil dkms
