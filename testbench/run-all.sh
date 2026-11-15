#!/usr/bin/env bash
# End-to-end: fresh Debian -> guide steps -> Secure Boot -> MOK -> TPM unlock -> kernel upgrade.
#   OPTION=1 ./run-all.sh NAME   own Secure Boot keys (firmware starts in Setup Mode)    [default]
#   OPTION=2 ./run-all.sh NAME   factory Microsoft keys, UKI key enrolled as MOK
# Run inside the tpmlab distrobox. Exits non-zero on the first unexpected result.
set -euo pipefail
cd "$(dirname "$0")"
VM=${1:-e2e} OPTION=${OPTION:-1}
CONSOLE="console=tty0 console=ttyS0,115200"
log() { echo "run/$VM-$1.log"; }
step() { echo "== $1"; ./lab-ssh.sh 2201 "${2:-} bash -s" < "steps/$1.sh" > "$(log "$1")" 2>&1 || { echo "FAILED: $1 ($(log "$1"))"; tail -20 "$(log "$1")"; exit 1; }; }
# For steps that prompt on a terminal: feed lines through script(1).
tty_step() { local s=$1; shift; echo "== $s"; ./lab-ssh.sh 2201 "cat > /root/$s.sh" < "steps/$s.sh"
  ./lab-ssh.sh 2201 "(sleep 3; for l in $*; do echo \$l; sleep 1; done) | PASSWORD=testpass PCRS=\${PCRS:-} script -qec 'bash /root/$s.sh' /dev/null" > "$(log "$s")" 2>&1 \
    || { echo "FAILED: $s"; tail -20 "$(log "$s")"; exit 1; }; }
expect() { got=$(./boot.sh "$VM" | tail -1); echo "boot: $got (want RESULT=$1)"; [ "$got" = "RESULT=$1" ] || exit 1; }
reboot() { ./vm.sh stop "$VM" >/dev/null; expect "$1"; }
mok() { ./mok-enroll.sh "$VM" "$1" mokpass1 > "$(log mok)" 2>&1 || { echo "FAILED: mok-enroll ($(log mok))"; tail "$(log mok)"; exit 1; }; expect PROMPT; ./lab-ssh.sh 2201 'echo "MOK:"; mokutil --list-enrolled | grep "Subject: CN"; echo "MOKX:"; mokutil --mokx --list-enrolled 2>/dev/null | grep "Subject: CN" || true'; }
hash() { ./lab-ssh.sh 2201 'mokutil --generate-hash=mokpass1 > /root/mok.hash'; }
distrust() { hash; step 10-distrust-debian MOK_HASH_FILE=/root/mok.hash; mok 1; }
check() { echo "-- $1"; ./lab-ssh.sh 2201 "$2" | tail -${3:-3}; }

./vm.sh new "$VM" ms                      # both options start like a new PC: Microsoft keys, Secure Boot on
expect PROMPT
if [ "$OPTION" = 2 ]; then
  # Keys and MOK enrollment come before the boot packages: installing systemd-boot puts an entry
  # first that factory (Microsoft) firmware refuses.
  ./lab-ssh.sh 2201 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -yq mokutil >/dev/null && mokutil --generate-hash=mokpass1 > /root/mok.hash'
  step 02-uki-key-mok MOK_HASH_FILE=/root/mok.hash
  mok 2                                   # enroll while shim + GRUB still boot
  step 01-packages
  step 03-config "SB_KEY=/etc/kernel/secure-boot-private-key.pem SB_CERT=/etc/kernel/secure-boot-certificate.pem EXTRA_CMDLINE='$CONSOLE'"
  step 04-uki-bootloader-shim
  reboot PROMPT
  distrust
else
  step 02-sbctl
  step 01-packages
  step 03-config "EXTRA_CMDLINE='$CONSOLE'"
  step 04-uki-bootloader-shim
  ./vm.sh stop "$VM" >/dev/null; ./vm.sh clearkeys "$VM"   # firmware setup: clear Secure Boot keys
  expect PROMPT
  step 05-enroll-sb
  reboot PROMPT
  hash; step 08-dkms-mok MOK_HASH_FILE=/root/mok.hash
  mok 1
  distrust
fi
check "Secure Boot" 'mokutil --sb-state; bootctl status 2>/dev/null | grep -E "Stub:"'
check "DKMS-signed module" 'bash -s < /dev/stdin' 1 < tests/dkms-insmod.sh
tty_step 06-tpm 246810
grep -h 'PCRs in protection mask' "$(log 06-tpm)" | head -1
reboot AUTO
reboot AUTO
./lab-ssh.sh 2201 'bash -s' < tests/n1-cmdline-inject.sh >/dev/null 2>&1
reboot AUTO
check "cmdline after injection attempt" 'bootctl status 2>/dev/null | grep "Current Entry"; grep -c "init=/bin/sh" /proc/cmdline || echo "init=/bin/sh not in /proc/cmdline"'
echo "== attack: Debian-signed kernel + stock initrd"
./lab-ssh.sh 2201 'bash -s' < tests/n5-prepare.sh > "$(log n5)" 2>&1
off=$(stat -c %s "run/$VM/serial.log"); ./vm.sh stop "$VM" >/dev/null; ./boot.sh "$VM" | tail -1
tail -c +"$off" "run/$VM/serial.log" | tr -d '\r' | grep -aoE "Error loading[^\x1b]*" | head -1
check "booted entry" 'bootctl status 2>/dev/null | grep "Current Entry"' 1
reboot AUTO
if [ "$OPTION" = 1 ]; then PKGS="shim-unsigned systemd-boot-efi systemd-boot"; else PKGS="shim-signed shim-helpers-amd64-signed systemd-boot-efi-amd64-signed systemd-boot"; fi
echo "-- apt reinstall of $PKGS"
./lab-ssh.sh 2201 "rm -rf /var/lib/resign-esp; DEBIAN_FRONTEND=noninteractive apt-get install -yq --reinstall $PKGS" > "$(log reinstall)" 2>&1 || { echo "FAILED: reinstall ($(log reinstall))"; tail "$(log reinstall)"; exit 1; }
grep -E 'resign-esp|^E:' "$(log reinstall)" || true
reboot AUTO
step 07-kernel-upgrade
reboot AUTO
check "after kernel upgrade" 'uname -r; mokutil --sb-state'
reboot AUTO
echo "E2E PASS (option $OPTION)"
