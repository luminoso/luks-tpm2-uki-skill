#!/usr/bin/env bash
# Read-only fact collector for a LUKS2 + TPM2 + signed UKI setup.
#   bash audit.sh          as a normal user: everything readable without root
#   sudo bash audit.sh     adds the ESP, LUKS header, keys, journal and TPM event log
# Writes nothing. Commands that are missing or not permitted are reported, not fatal.
set -u
export LC_ALL=C
ROOT=no; [ "$(id -u)" = 0 ] && ROOT=yes
G=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f          # systemd-boot loader variables
EFIVARS=/sys/firmware/efi/efivars

sec() { printf '\n===== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { printf '$ %s\n' "$*"; if have "$1"; then timeout 30 "$@" 2>&1; else echo "(not installed: $1)"; fi; }
needroot() { [ "$ROOT" = yes ] || { echo "(needs root: rerun with sudo)"; return 1; }; }
loadervar() { local f="$EFIVARS/$1-$G"; [ -r "$f" ] && cat "$f" 2>/dev/null | tail -c +5 | iconv -f UTF-16LE -t UTF-8 2>/dev/null | tr '\0' ' '; }
ESP=$(bootctl --print-esp-path 2>/dev/null || findmnt -no TARGET /boot/efi 2>/dev/null || echo /boot/efi)

sec "System"
echo "root: $ROOT"
grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release
echo "running kernel: $(uname -r)"; echo "installed module trees: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
echo "boot time: $(uptime -s 2>/dev/null)"
have pveversion && pveversion

sec "Secure Boot and boot loader"
run bootctl status --no-pager
run efibootmgr
for v in LoaderEntries LoaderEntryDefault LoaderEntrySelected LoaderEntryOneShot; do printf '%s: %s\n' "$v" "$(loadervar $v)"; done
have mokutil && { run mokutil --sb-state; run mokutil --list-enrolled --short; run mokutil --mokx --list-enrolled --short; }

sec "Firmware key lists (PK, KEK, db, dbx)"
python3 - "$EFIVARS" <<'PY'
import glob, struct, subprocess, sys, uuid
X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
SHA256 = uuid.UUID("c1c41626-504c-4092-aca9-41f936934328").bytes_le
for name in ("PK", "KEK", "db", "dbx"):
    f = glob.glob(f"{sys.argv[1]}/{name}-*")
    if not f:
        print(f"{name}: absent"); continue
    try:
        data = open(f[0], "rb").read()[4:]
    except OSError as e:
        print(f"{name}: {e.strerror}"); continue
    certs, hashes, i = [], 0, 0
    while i + 28 <= len(data):
        lsize, hsize, ssize = struct.unpack("<III", data[i+16:i+28])
        body = data[i+28+hsize:i+lsize]
        for j in range(0, len(body), ssize):
            sig = body[j+16:j+ssize]
            if data[i:i+16] == X509:
                certs.append(subprocess.run(["openssl", "x509", "-inform", "der", "-noout", "-subject"],
                                            input=sig, capture_output=True).stdout.decode().strip())
            elif data[i:i+16] == SHA256:
                hashes += 1
        i += lsize
    print(f"{name}: {len(certs)} certificate(s), {hashes} sha256 hash(es)")
    for c in certs:
        print("   ", c)
PY

sec "TPM"
ls /sys/class/tpm/ 2>/dev/null; cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null | sed 's/^/TPM major version: /'
run systemd-analyze pcrs 0 1 2 3 4 5 7 8 11 12 13 14 15

sec "Kernel command line and UKI build configuration"
echo "/proc/cmdline: $(cat /proc/cmdline)"
for f in /etc/kernel/cmdline /etc/kernel/install.conf /etc/kernel/uki.conf /etc/kernel/entry-token /etc/kernel/tries /etc/kernel/pcrlock-pcrs; do
  [ -e "$f" ] && { echo "--- $f"; cat "$f"; }
done
echo "--- /etc/kernel/*.d"; ls /etc/kernel/install.d /etc/kernel/postinst.d /etc/kernel/postrm.d 2>/dev/null

sec "initrd"
for p in dracut dracut-core initramfs-tools mkinitcpio cryptsetup-initramfs; do
  have dpkg-query && dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' "$p" 2>/dev/null
done
for d in /etc/dracut.conf.d /etc/mkinitcpio.conf.d; do [ -d "$d" ] && for f in "$d"/*; do echo "--- $f"; grep -v '^\s*#' "$f" | grep -v '^\s*$'; done; done
run systemctl status --no-pager systemd-pcrphase-initrd.service
run systemctl status --no-pager 'systemd-cryptsetup@*'

sec "crypttab and LUKS"
cat /etc/crypttab 2>/dev/null
if needroot; then
  for dev in $(lsblk -nrpo NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}'); do
    echo "--- $dev"
    cryptsetup luksDump "$dev" | sed -n '/^Keyslots:/,/^Digests:/p' | grep -E '^\s+[0-9]+: |^\s+tpm2-[a-z-]+:|Keyslot:|^\s+[0-9]+: systemd'
  done
fi

sec "pcrlock"
if [ -r /var/lib/systemd/pcrlock.json ]; then
  python3 -c 'import json; d=json.load(open("/var/lib/systemd/pcrlock.json")); print("policy PCRs:", sorted({v["pcr"] for v in d.get("pcrValues", [])}), "NV index:", hex(d.get("nvIndex", 0)))'
else
  echo "no /var/lib/systemd/pcrlock.json"
fi
ls /var/lib/pcrlock.d 2>/dev/null
for f in /var/lib/pcrlock.d/*/*.pcrlock; do
  [ -e "$f" ] && [ "$(basename "$f")" != generated.pcrlock ] && echo "extra component variant: $f"
done

sec "ESP contents and signatures"
if needroot; then
  echo "ESP: $ESP"
  find "$ESP" -type f | sort
  echo "--- loader.conf"; cat "$ESP/loader/loader.conf" 2>/dev/null
  for e in "$ESP"/loader/entries/*.conf; do [ -e "$e" ] && { echo "--- boot entry $e"; cat "$e"; }; done
  for f in $(find "$ESP" -iname '*.efi' | sort); do
    printf '%s: %s\n' "$f" "$(sbverify --list "$f" 2>/dev/null | grep -E 'subject' | tr -s ' \n' ' ')"
  done
  for u in "$ESP"/EFI/Linux/*.efi; do
    [ -e "$u" ] || continue
    echo "--- $u"
    have ukify && ukify --json=short inspect "$u" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sig = json.loads(d[".pcrsig"]["text"]) if ".pcrsig" in d else {}
print("  uname:", d.get(".uname", {}).get("text", "?").strip())
print("  .pcrsig:", {bank: len(v) for bank, v in sig.items()} or "MISSING")
print("  .pcrpkey:", "present" if ".pcrpkey" in d else "MISSING")
print("  .cmdline:", d.get(".cmdline", {}).get("text", "?").strip())'
  done
fi

sec "Packages, update hooks, pins"
have dpkg-query && dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' 'systemd-boot*' 'shim*' 'grub*' 'sbctl' 'sbsigntool' 'efitools' 'mokutil' 'dkms' '*-microcode' 'proxmox-kernel-helper' 2>/dev/null | awk '$3 ~ /^ii/'
have dpkg && { echo "--- dpkg --verify (empty = unmodified)"; dpkg --verify systemd-boot-efi-amd64-signed systemd-boot-efi shim-signed shim-unsigned 2>/dev/null; }
have apt-cache && apt-cache policy initramfs-tools grub-pc shim-signed 2>/dev/null | grep -E '^[a-z]|Candidate'
echo "--- apt hooks that run after dpkg"; grep -rl 'Post-Invoke' /etc/apt/apt.conf.d 2>/dev/null | xargs -r grep -H 'Post-Invoke' 2>/dev/null
echo "--- apt preferences"; ls /etc/apt/preferences.d 2>/dev/null
for f in /usr/local/sbin/resign-esp /etc/kernel/esp-signing.conf; do [ -e "$f" ] && echo "present: $f"; done
[ -e /etc/kernel/esp-signing.conf ] && cat /etc/kernel/esp-signing.conf

sec "DKMS and kernel module trust"
echo "lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null)"
DKMS=$(command -v dkms || echo /usr/sbin/dkms); [ -x "$DKMS" ] && "$DKMS" status 2>&1
MODINFO=$(command -v modinfo || echo /usr/sbin/modinfo)
for m in /lib/modules/"$(uname -r)"/updates/dkms/*.ko*; do
  [ -e "$m" ] || continue
  printf '%s: signer=%s, loaded=%s\n' "$(basename "$m")" "$("$MODINFO" -F signer "$m" 2>/dev/null)" "$(grep -q "^$(basename "$m" | sed 's/\.ko.*//; s/-/_/g') " /proc/modules && echo yes || echo no)"
done
grep -s '' /etc/dkms/framework.conf.d/*.conf | grep -E 'mok_' || echo "dkms signing key: default (/var/lib/dkms/mok.key)"

sec "Private keys stored on this host (names only)"
if needroot; then
  for d in /etc/secureboot /etc/secureboot/keys /var/lib/sbctl/keys /var/lib/sbctl/keys/* /etc/kernel /etc/systemd /var/lib/dkms; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -type f \( -name '*.key' -o -name '*private*' \) -printf '%m %u %p\n' 2>/dev/null
  done
fi

sec "This boot: disk unlock and TPM messages"
if needroot; then
  journalctl -b -o short-monotonic --no-pager 2>/dev/null | grep -iE 'systemd-cryptsetup|unseal|TPM2 operation|tpm2.*token|Please enter passphrase|pcrphase' | head -30
  [ -r /run/log/systemd/tpm2-measure.log ] && echo "enter-initrd measured: $(grep -c enter-initrd /run/log/systemd/tpm2-measure.log) time(s)"
fi

sec "Option ROMs in the TPM event log"
if needroot && [ -x /usr/lib/systemd/systemd-pcrlock ]; then
  echo "boot-services drivers (option ROMs) measured: $(/usr/lib/systemd/systemd-pcrlock log 2>/dev/null | grep -c 'efi-boot-services-driver')"
fi
echo
echo "(audit.sh finished; nothing was changed)"
