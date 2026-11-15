#!/usr/bin/env bash
# Boots a throwaway Debian cloud VM (SSH on localhost:2222) with the target disk attached as NVMe.
# Run inside the tpmlab distrobox.
set -euo pipefail
cd "$(dirname "$0")"
BASE=${BASE:-target-base} BUILDER=${BUILDER:-builder}   # image names, e.g. BASE=target-forky for Debian testing
[ -f "images/$BUILDER.qcow2" ] || { qemu-img create -q -f qcow2 -b debian-13-genericcloud-amd64.qcow2 -F qcow2 "images/$BUILDER.qcow2" 12G; }
[ -f "images/$BASE.qcow2" ] || qemu-img create -q -f qcow2 "images/$BASE.qcow2" 20G
qemu-system-x86_64 -name builder -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
  -drive file="images/$BUILDER.qcow2",if=virtio,format=qcow2 \
  -drive file=images/seed.iso,media=cdrom,format=raw \
  -drive if=none,id=t0,file="images/$BASE.qcow2",format=qcow2 -device nvme,serial=tpmlab0,drive=t0 \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
  -display none -serial file:"run/$BUILDER-serial.log" -daemonize -pidfile "run/$BUILDER.pid"
