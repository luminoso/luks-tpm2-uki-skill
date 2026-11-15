# Test only: stage a correctly signed UKI for a "newer kernel" that cannot find its root device,
# with 3 boot tries. Expect 3 failed starts (the initrd halts), then systemd-boot skips it.
set -euxo pipefail
ESP=$(bootctl --print-esp-path)
T=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)
V=$(uname -r)
U=$(ls "$ESP"/EFI/Linux/"$T-$V"*.efi | head -1)
python3 - "$U" /root/initrd.broken <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", b, 0x3C)[0]
n, opt = struct.unpack_from("<H", b, pe + 6)[0], struct.unpack_from("<H", b, pe + 20)[0]
for i in range(n):
    name, vs, _, rs, rp = struct.unpack_from("<8sIIII", b, pe + 24 + opt + 40 * i)
    if name.rstrip(b"\0") == b".initrd":
        open(sys.argv[2], "wb").write(b[rp:rp + min(vs, rs)])
PY
sed 's|root=[^ ]*|root=/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000 rd.retry=10|' /etc/kernel/cmdline > /root/cmdline.broken
ukify build --config=/etc/kernel/uki.conf --linux="/boot/vmlinuz-$V" --initrd=/root/initrd.broken \
  --cmdline="@/root/cmdline.broken" --uname=9.9.9 --os-release=@/etc/os-release \
  --output="$ESP/EFI/Linux/$T-9.9.9+3.efi"
ls "$ESP"/EFI/Linux/
bootctl list --no-pager | grep -E 'title|id:' | head -4
