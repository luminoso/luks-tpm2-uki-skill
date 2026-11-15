#!/usr/bin/env bash
# mok-enroll.sh NAME NKEYS PASSWORD : reboot NAME and confirm a pending mokutil --import in MokManager.
# Run inside the tpmlab distrobox. MokManager's serial output lags, so this sends a fixed key sequence.
set -euo pipefail
cd "$(dirname "$0")"
name=$1 n=$2 pw=$3 L=run/$1/serial.log
./vm.sh stop "$name"; off=$(stat -c %s "$L"); ./vm.sh start "$name"
for _ in $(seq 60); do tail -c +"$off" "$L" | grep -aq "Press any key" && break; sleep 1; done
K() { python3 keys.py "run/$name/serial.sock" "$@"; }
K space                                   # enter MOK management
K down enter                              # "Enroll MOK"
downs=(); for _ in $(seq "$n"); do downs+=(down); done
K "${downs[@]}" enter                     # skip "View key N" entries, pick "Continue"
K down enter                              # "Yes"
K "text:$pw" enter                        # MOK password
K enter                                   # "Reboot"
echo "sent"
