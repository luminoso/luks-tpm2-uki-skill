#!/usr/bin/env bash
# boot.sh NAME : start the VM and report how the disk was opened.
# Prints RESULT=AUTO (reached SSH without a passphrase prompt) or RESULT=PROMPT (prompt seen,
# passphrase typed, $PASS or testpass) or RESULT=FAIL. Run inside the tpmlab distrobox.
set -uo pipefail
cd "$(dirname "$0")"
name=$1 dir=run/$1 log=run/$1/serial.log PORT=${PORT:-2201}
start=$(stat -c %s "$log" 2>/dev/null || echo 0)
{ [ -f "$dir/qemu.pid" ] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null; } || ./vm.sh start "$name" || exit 1   # already running: just watch
new() { tail -c +$((start + 1)) "$log" | tr -d '\r'; }
prompted=no
for _ in $(seq 100); do
  if [ $prompted = no ] && new | grep -qaE 'Please (enter passphrase|unlock disk)'; then
    prompted=yes; sleep 1; ./vm.sh type "$name" "${PASS:-testpass}"
  fi
  if ./lab-ssh.sh "$PORT" true 2>/dev/null; then
    [ $prompted = yes ] && echo RESULT=PROMPT || echo RESULT=AUTO; exit 0
  fi
  if new | grep -qaE 'Security Violation|Access Denied|emergency mode|Kernel panic|Give root password|Could not boot|System halted'; then
    break
  fi
  sleep 3
done
echo RESULT=FAIL; new | tail -40; exit 1
