#!/usr/bin/env bash
# Run on the host inside tpmlab: shows why PCR 7 is required.
# A) policy without PCR 7 + Secure Boot keys cleared  -> key still released (hole)
# B) policy with only PCR 7 + Secure Boot keys cleared -> passphrase prompt
set -uo pipefail
cd "$(dirname "$0")/.."
VM=t1 PORT=${PORT:-2201}
relock() {  # $1 = PCR list
  ./lab-ssh.sh "$PORT" "(sleep 2; echo 246810) | script -qec '/usr/lib/systemd/systemd-pcrlock make-policy --pcr=$1 --recovery-pin=query' /dev/null 2>&1 | grep -E 'protection mask|NV index'"
}
for case in "13,14" "7"; do
  echo "=== policy PCRs: $case"
  ./vm.sh stop $VM >/dev/null; ./vm.sh restore $VM tpm2
  ./boot.sh $VM | tail -1
  relock "$case"
  ./vm.sh stop $VM >/dev/null
  echo -n "normal boot: "; ./boot.sh $VM | tail -1
  ./vm.sh stop $VM >/dev/null
  cp run/$VM@uki/vars.qcow2 run/$VM/vars.qcow2      # Secure Boot keys cleared, SB off
  echo -n "SB cleared:  "; ./boot.sh $VM | tail -1
  ./lab-ssh.sh "$PORT" 'bootctl status 2>/dev/null | grep "Secure Boot"'
done
./vm.sh stop $VM >/dev/null
