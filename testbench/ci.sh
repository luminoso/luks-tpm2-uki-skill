#!/usr/bin/env bash
# CI entry point: build the base disk, then run one chain end to end. Runs as root in a Fedora
# container with /dev/kvm (see .github/workflows/e2e.yml), or by hand in the tpmlab distrobox.
#   OPTION=1 SHIM=0 SUITE=trixie bash ci.sh
set -euxo pipefail
cd "$(dirname "$0")"
SUITE=${SUITE:-trixie}
if [ "$SUITE" = trixie ]; then KERNEL_SUITE=trixie-backports; else KERNEL_SUITE=unstable; fi
export OPTION=${OPTION:-1} SHIM=${SHIM:-0} KERNEL_SUITE

if [ "$(id -u)" = 0 ] && command -v dnf >/dev/null; then
  dnf install -y -q qemu-system-x86 qemu-img swtpm swtpm-tools edk2-ovmf openssh-clients xorriso \
    python3 python3-virt-firmware cpio rpm
fi
mkdir -p images run

# A second firmware build for the firmware-update test (vm.sh swapfw): edk2 from an older Fedora.
if [ ! -f images/OVMF_CODE_alt.qcow2 ]; then
  d=$(mktemp -d); (cd "$d" && dnf download -q --releasever=42 edk2-ovmf && rpm2cpio edk2-ovmf-*.rpm | cpio -idm --quiet ./usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2)
  cp "$d/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2" images/OVMF_CODE_alt.qcow2
  cmp -s images/OVMF_CODE_alt.qcow2 /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2 && { echo "alt firmware is identical"; exit 1; }
fi

# Base disk: a throwaway Debian cloud VM debootstraps the target.
if [ ! -f images/target-base.qcow2 ]; then
  [ -f lab_key ] || ssh-keygen -q -t ed25519 -N '' -f lab_key
  sed "s|REPLACE_WITH_CONTENTS_OF_lab_key.pub|$(cat lab_key.pub)|" seed/user-data.template > seed/user-data
  curl -fsSLo images/debian-13-genericcloud-amd64.qcow2 \
    https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
  xorriso -as mkisofs -o images/seed.iso -V cidata -J -r seed/
  ./builder-up.sh
  for _ in $(seq 120); do ./lab-ssh.sh 2222 true 2>/dev/null && break; sleep 5; done
  ./lab-ssh.sh 2222 "SUITE=$SUITE bash -s" < build-target.sh > run/build-target.log 2>&1 || { tail -40 run/build-target.log; exit 1; }
  grep -q BUILD-OK run/build-target.log
  ./lab-ssh.sh 2222 poweroff || true
  for _ in $(seq 60); do kill -0 "$(cat run/builder.pid)" 2>/dev/null || break; sleep 2; done
  rm -f images/builder.qcow2
fi

./run-all.sh ci
