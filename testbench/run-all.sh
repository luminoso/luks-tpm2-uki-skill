#!/usr/bin/env bash
# End-to-end: fresh Debian -> guide steps -> Secure Boot -> TPM unlock -> attacks -> updates -> operations.
#   OPTION=1 ./run-all.sh NAME          own Secure Boot keys, no shim: firmware starts systemd-boot   [default]
#   OPTION=1 SHIM=1 ./run-all.sh NAME   own Secure Boot keys + shim + MOK (DKMS modules on the Debian kernel)
#   OPTION=2 ./run-all.sh NAME          factory Microsoft keys + shim, UKI key enrolled as MOK
#   PORT=2202 ...                       SSH port of this VM, so several runs can go in parallel
# Run inside the tpmlab distrobox. Exits non-zero on the first unexpected result.
set -euo pipefail
cd "$(dirname "$0")"
VM=${1:-e2e} OPTION=${OPTION:-1} SHIM=${SHIM:-0}
[ "$OPTION" = 2 ] && SHIM=1
export PORT=${PORT:-2201}
SCRIPTS=$(cd "$(ls -d ../skills/luks-tpm2-uki/scripts ../luks-tpm2-uki/skills/luks-tpm2-uki/scripts 2>/dev/null | head -1)" && pwd)
OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2
CONSOLE="console=tty0 console=ttyS0,115200"
log() { echo "run/$VM-$1.log"; }
step() { echo "== $1"; ./lab-ssh.sh "$PORT" "${2:-} bash -s" < "steps/$1.sh" > "$(log "$1")" 2>&1 || { echo "FAILED: $1 ($(log "$1"))"; tail -20 "$(log "$1")"; exit 1; }; }
# For steps that prompt on a terminal: feed lines through script(1).
tty_step() { local s=$1; shift; echo "== $s"; ./lab-ssh.sh "$PORT" "cat > /root/$s.sh" < "steps/$s.sh"
  ./lab-ssh.sh "$PORT" "(sleep 3; for l in $*; do echo \$l; sleep 1; done) | PASSWORD=testpass PCRS=\${PCRS:-} script -qec 'bash /root/$s.sh' /dev/null" > "$(log "$s")" 2>&1 \
    || { echo "FAILED: $s"; tail -20 "$(log "$s")"; exit 1; }; }
result() { ./boot.sh "$VM" | grep -o 'RESULT=[A-Z]*' | head -1 || true; }
expect() { got=$(result); echo "boot: $got (want RESULT=$1)"; [ "$got" = "RESULT=$1" ] || exit 1; }
reboot() { ./vm.sh stop "$VM" >/dev/null; expect "$1"; }
mok() { ./mok-enroll.sh "$VM" "$1" mokpass1 > "$(log mok)" 2>&1 || { echo "FAILED: mok-enroll ($(log mok))"; tail "$(log mok)"; exit 1; }; expect PROMPT; ./lab-ssh.sh "$PORT" 'echo "MOK:"; mokutil --list-enrolled | grep "Subject: CN"; echo "MOKX:"; mokutil --mokx --list-enrolled 2>/dev/null | grep "Subject: CN" || true'; }
hash() { ./lab-ssh.sh "$PORT" 'mokutil --generate-hash=mokpass1 > /root/mok.hash'; }
distrust() { hash; step 10-distrust-debian MOK_HASH_FILE=/root/mok.hash; mok 1; }
check() { echo "-- $1"; ./lab-ssh.sh "$PORT" "$2" | tail -"${3:-3}"; }
# Like assert, but retries for up to a minute (units that run late in boot).
eventually() { assert "$1" "for i in \$(seq 30); do ( $2 ) >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"; }
assert() { if ./lab-ssh.sh "$PORT" "$2" > "$(log assert)" 2>&1; then echo "ok: $1"; else echo "FAILED: $1"; tail -20 "$(log assert)"; exit 1; fi; }

./vm.sh new "$VM" ms                      # every chain starts like a new PC: Microsoft keys, Secure Boot on
expect PROMPT
if [ "$OPTION" = 2 ]; then
  # Keys and MOK enrollment come before the boot packages: installing systemd-boot puts an entry
  # first that factory (Microsoft) firmware refuses.
  ./lab-ssh.sh "$PORT" 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -yq mokutil >/dev/null && mokutil --generate-hash=mokpass1 > /root/mok.hash'
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
  if [ "$SHIM" = 1 ]; then step 04-uki-bootloader-shim; else step 04-uki-bootloader; fi
  ./vm.sh stop "$VM" >/dev/null; ./vm.sh clearkeys "$VM"   # firmware setup: clear Secure Boot keys
  expect PROMPT
  step 05-enroll-sb
  reboot PROMPT
  if [ "$SHIM" = 1 ]; then
    hash; step 08-dkms-mok MOK_HASH_FILE=/root/mok.hash
    mok 1
    distrust
  fi
fi
check "Secure Boot" 'mokutil --sb-state; bootctl status 2>/dev/null | grep -E "Stub:"'
# Kernel module trust: a module signed with the key DKMS will use must load, an unsigned one must not
# (dkms-insmod.sh checks that first), and a real DKMS module must load.
if [ "$SHIM" = 0 ]; then
  step 09-dkms-db                         # DKMS signs with the db key
  keys="KEY=/var/lib/sbctl/keys/db/db.key CERT=/var/lib/sbctl/keys/db/db.pem"; signer="Database Key"
else
  keys=""; signer="DKMS module signing key"   # DKMS key, enrolled as a MOK
fi
got=$(./lab-ssh.sh "$PORT" "$keys bash -s" < tests/dkms-insmod.sh 2>&1 | grep -E '^(INSMOD-|ENFORCEMENT-)' | tail -1)
echo "-- module signed with ${keys:+the db key}${keys:-the DKMS MOK key}, unsigned control refused: $got (want INSMOD-OK)"; [ "$got" = INSMOD-OK ] || exit 1
got=$(./lab-ssh.sh "$PORT" 'bash -s' < tests/dkms-real.sh 2>&1 | grep -E '^DKMS-' | tail -1)
echo "-- DKMS module: $got (want DKMS-OK $signer)"; [ "$got" = "DKMS-OK $signer" ] || exit 1
tty_step 06-tpm 246810
grep -h 'PCRs in protection mask' "$(log 06-tpm)" | head -1
reboot AUTO
reboot AUTO
./lab-ssh.sh "$PORT" 'bash -s' < tests/n1-cmdline-inject.sh >/dev/null 2>&1
reboot AUTO
check "cmdline after injection attempt" 'bootctl status 2>/dev/null | grep "Current Entry"; grep -c "init=/bin/sh" /proc/cmdline || echo "init=/bin/sh not in /proc/cmdline"'
echo "== attack: Debian-signed kernel + stock initrd"
./lab-ssh.sh "$PORT" 'bash -s' < tests/n5-prepare.sh > "$(log n5)" 2>&1
off=$(stat -c %s "run/$VM/serial.log"); ./vm.sh stop "$VM" >/dev/null
r=$(result)
# Without shim the firmware refuses the kernel ("Access Denied"), which boot.sh reports as FAIL while
# systemd-boot goes on to the default entry: keep watching that boot.
[ "$r" = RESULT=FAIL ] && r="$(result) after a refusal"
echo "boot after the attack entry: $r"; case $r in RESULT=FAIL*) exit 1 ;; esac
errs=$(tail -c +"$off" "run/$VM/serial.log" | tr -d '\r' | grep -aoE "Error loading[^\x1b]*" || true)
echo "${errs%%$'\n'*}"; [ -n "$errs" ] || { echo "FAILED: the Debian kernel was not refused"; exit 1; }
check "booted entry" 'bootctl status 2>/dev/null | grep "Current Entry"' 1
reboot AUTO
if [ "$OPTION" = 2 ]; then PKGS="shim-signed shim-helpers-amd64-signed systemd-boot-efi-amd64-signed systemd-boot"
elif [ "$SHIM" = 1 ]; then PKGS="shim-unsigned systemd-boot-efi systemd-boot"
else PKGS="systemd-boot-efi systemd-boot"; fi
echo "-- apt reinstall of $PKGS"
./lab-ssh.sh "$PORT" "rm -rf /var/lib/resign-esp; DEBIAN_FRONTEND=noninteractive apt-get install -yq --reinstall $PKGS" > "$(log reinstall)" 2>&1 || { echo "FAILED: reinstall ($(log reinstall))"; tail "$(log reinstall)"; exit 1; }
grep -E 'resign-esp|^E:' "$(log reinstall)" || true
reboot AUTO

echo "== operations: pre-reboot check, unlock alert, boot counting"
for f in check-next-boot pcrlock-update tpm-unlock-check; do
  ./lab-ssh.sh "$PORT" "cat > /usr/local/sbin/$f && chmod 0755 /usr/local/sbin/$f" < "$SCRIPTS/$f"
done
./lab-ssh.sh "$PORT" 'cat > /etc/systemd/system/tpm-unlock-check.service && systemctl daemon-reload && systemctl enable -q tpm-unlock-check.service' < "$SCRIPTS/tpm-unlock-check.service"
step 11-boot-counting
assert "check-next-boot passes" check-next-boot
reboot AUTO
blessed='test -f /boot/efi/EFI/Linux/$(cat /etc/machine-id)-$(uname -r).efi'
eventually "booted UKI blessed (counter removed)" "$blessed"
eventually "unlock alert quiet after a TPM boot" 'journalctl -b -o cat -u tpm-unlock-check | grep -q "the TPM opened every"'
step 12-broken-uki
assert "check-next-boot flags the broken UKI" '! check-next-boot'
./vm.sh stop "$VM" >/dev/null
for i in 1 2 3; do
  r=$(result); echo "broken UKI, start $i: $r (want RESULT=FAIL)"; [ "$r" = RESULT=FAIL ] || exit 1
  ./vm.sh reset "$VM"
done
expect AUTO
assert "broken UKI marked bad after 3 tries" 'ls /boot/efi/EFI/Linux/ | grep -q "9.9.9+0-3.efi$"'
./lab-ssh.sh "$PORT" 'rm -f /boot/efi/EFI/Linux/*-9.9.9+*.efi'
step 07-kernel-upgrade "KERNEL_SUITE=${KERNEL_SUITE:-trixie-backports}"
reboot AUTO
check "after kernel upgrade" 'uname -r; mokutil --sb-state'
assert "DKMS rebuilt the module for the new kernel, signed by $signer, and it loads" "modinfo -F signer \$(modinfo -n tbhello) | grep -qx '$signer' && modprobe tbhello"
eventually "new kernel's UKI blessed" "$blessed"

echo "== planned firmware update"
assert "pcrlock-update open 0,1,2,3" 'pcrlock-update open 0,1,2,3 </dev/null'
./vm.sh stop "$VM" >/dev/null; ./vm.sh swapfw "$VM"
expect AUTO
assert "pcrlock-update close" 'pcrlock-update close </dev/null && check-next-boot'
reboot AUTO
echo "== unplanned firmware change, unlocked with the recovery key"
step 13-recovery-key PASSWORD=testpass
key=$(./lab-ssh.sh "$PORT" 'cat /root/recovery-key.txt')
./vm.sh stop "$VM" >/dev/null; ./vm.sh swapfw "$VM" "$OVMF_CODE"
PASS=$key expect PROMPT
eventually "unlock alert fired" 'systemctl is-failed -q tpm-unlock-check'
assert "re-lock with the recovery PIN" "(sleep 4; echo 246810) | script -qec 'pcrlock-update close' /dev/null | grep -q 'again'"
reboot AUTO
eventually "unlock alert quiet again" 'journalctl -b -o cat -u tpm-unlock-check | grep -q "the TPM opened every"'
echo "E2E PASS (option $OPTION, shim $SHIM)"
