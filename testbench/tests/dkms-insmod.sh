# Build a trivial module, sign it with KEY/CERT (default: the DKMS key), try to load it.
# Last line: INSMOD-OK or INSMOD-REJECTED. Shows whether the kernel trusts that key for modules.
set -eux
export DEBIAN_FRONTEND=noninteractive
V=$(uname -r)
apt-get install -yq build-essential "linux-headers-$V" >/dev/null
mkdir -p /root/hello && cd /root/hello
cat > hello.c <<'C'
#include <linux/module.h>
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("MOK test");
static int __init h(void) { pr_info("hello from a DKMS-signed module\n"); return 0; }
static void __exit b(void) {}
module_init(h);
module_exit(b);
C
echo "obj-m := hello.o" > Makefile
rm -f hello.ko hello.o     # fresh, unsigned build
make -s -C "/lib/modules/$V/build" M="$PWD" modules
rmmod hello 2>/dev/null || true
# Control: the same module unsigned must be refused, or the test proves nothing.
cp hello.ko hello-unsigned.ko
if insmod hello-unsigned.ko 2>/dev/null; then rmmod hello; echo "ENFORCEMENT-OFF"; exit 1; fi
"/usr/src/linux-headers-$V/scripts/sign-file" sha256 "${KEY:-/var/lib/dkms/mok.key}" "${CERT:-/var/lib/dkms/mok.pub}" hello.ko
if insmod hello.ko; then echo INSMOD-OK; else echo INSMOD-REJECTED; fi
