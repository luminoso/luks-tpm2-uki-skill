#!/usr/bin/env bash
# Target VM control. Run inside the tpmlab distrobox.
#   vm.sh new NAME [ms]      fresh disk overlay (of images/$BASE.qcow2, default target-base) + blank UEFI vars (Setup Mode), or factory Microsoft keys with "ms"; empty TPM
#   vm.sh start NAME         boot (SSH on localhost:$PORT, default 2201)
#   vm.sh stop NAME          power off via QMP, wait
#   vm.sh reset NAME         press the reset button
#   vm.sh type NAME TEXT     type TEXT + Enter on the serial console
#   vm.sh snap NAME SNAP     save disk + vars + TPM together (VM must be stopped)
#   vm.sh restore NAME SNAP  roll all three back together
#   vm.sh clearkeys NAME     delete PK/KEK/db/dbx (firmware Setup Mode), keep boot entries
#   vm.sh swapfw NAME [CODE] boot with a different OVMF build next time (firmware "update" test)
set -euo pipefail
cd "$(dirname "$0")"
OVMF=/usr/share/edk2/ovmf
cmd=$1 name=$2 dir=run/$2 PORT=${PORT:-2201}

qmp() { python3 - "$dir/qmp.sock" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(json.dumps({"execute": sys.argv[2]}) + '\n'); f.flush(); print(f.readline().strip())
PY
}

running() { [ -f "$dir/qemu.pid" ] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null; }

case $cmd in
new)
  rm -rf "$dir"; mkdir -p "$dir/tpm"
  qemu-img create -q -f qcow2 -b "../../images/${BASE:-target-base}.qcow2" -F qcow2 "$dir/disk.qcow2"
  if [ "${3:-}" = ms ]; then   # factory state: Microsoft keys enrolled, Secure Boot on
    cp $OVMF/OVMF_VARS_4M.secboot.qcow2 "$dir/vars.qcow2"
  else                         # no keys enrolled: Setup Mode
    cp $OVMF/OVMF_VARS_4M.qcow2 "$dir/vars.qcow2"
  fi
  echo $OVMF/OVMF_CODE_4M.secboot.qcow2 > "$dir/code"
  ;;
start)
  running && { echo "already running"; exit 1; }
  swtpm socket --tpm2 --tpmstate dir="$dir/tpm" --ctrl type=unixio,path="$dir/swtpm.sock" \
    --log file="$dir/swtpm.log" --terminate --daemon
  for _ in $(seq 50); do [ -S "$dir/swtpm.sock" ] && break; sleep 0.1; done
  qemu-system-x86_64 -name "$name" -machine q35,smm=on,accel=kvm -cpu host -m 3072 -smp 4 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=qcow2,unit=0,readonly=on,file="$(cat "$dir/code")" \
    -drive if=pflash,format=qcow2,unit=1,file="$dir/vars.qcow2" \
    -chardev socket,id=chrtpm,path="$dir/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -drive if=none,id=d0,file="$dir/disk.qcow2",format=qcow2 -device nvme,serial=tpmlab0,drive=d0 \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$PORT-:22 \
    -chardev socket,id=s0,path="$dir/serial.sock",server=on,wait=off,logfile="$dir/serial.log",logappend=on \
    -serial chardev:s0 -qmp unix:"$dir/qmp.sock",server=on,wait=off \
    -display none -daemonize -pidfile "$dir/qemu.pid"
  ;;
stop)
  running || exit 0
  # Ask the guest to power off (SSH first, ACPI as fallback) and wait. A hard kill loses
  # unflushed ESP (FAT) writes, so say so loudly if it ever comes to that.
  ./lab-ssh.sh "$PORT" 'sync; systemctl poweroff' 2>/dev/null || qmp system_powerdown >/dev/null
  for i in $(seq 180); do running || { echo "stopped after ${i}s"; exit 0; }; sleep 1; done
  echo "WARNING: guest did not power off in 180s, killing QEMU (ESP may be dirty)"
  qmp quit >/dev/null || true; sleep 1
  ;;
reset)
  qmp system_reset >/dev/null   # like the reset button, for a guest that halted
  ;;
type)
  python3 type.py "$dir/serial.sock" "$3"
  ;;
snap)
  running && { echo "stop the VM first"; exit 1; }
  rm -rf "run/$name@$3"; mkdir -p "run/$name@$3"
  cp -a --reflink=auto "$dir/disk.qcow2" "$dir/vars.qcow2" "$dir/tpm" "$dir/code" "run/$name@$3/"
  ;;
restore)
  running && { echo "stop the VM first"; exit 1; }
  rm -rf "$dir/tpm"; cp -a --reflink=auto "run/$name@$3/." "$dir/"
  ;;
clearkeys)
  # Like "Clear Secure Boot keys" in firmware setup: delete PK/KEK/db/dbx, keep boot entries.
  running && { echo "stop the VM first"; exit 1; }
  qemu-img convert -f qcow2 -O raw "$dir/vars.qcow2" "$dir/vars.raw"
  virt-fw-vars -i "$dir/vars.raw" -d PK -d KEK -d db -d dbx -o "$dir/vars.cleared.raw" >/dev/null
  qemu-img convert -f raw -O qcow2 "$dir/vars.cleared.raw" "$dir/vars.qcow2"
  rm -f "$dir/vars.raw" "$dir/vars.cleared.raw"
  ;;
swapfw)
  # Firmware "update" test: boot a different edk2 build next time, so PCR 0 changes. Default target is
  # images/OVMF_CODE_alt.qcow2 (an OVMF_CODE_4M.secboot.qcow2 from another edk2 version), or pass a path.
  fw=${3:-$PWD/images/OVMF_CODE_alt.qcow2}
  [ -f "$fw" ] || { echo "missing $fw"; exit 1; }
  echo "$fw" > "$dir/code"
  ;;
*) echo "unknown command"; exit 1 ;;
esac
