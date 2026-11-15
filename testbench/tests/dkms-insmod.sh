# Build a trivial module, sign it with the DKMS key, load it. Proves MOK keys reach the kernel.
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
make -s -C "/lib/modules/$V/build" M="$PWD" modules
"/usr/src/linux-headers-$V/scripts/sign-file" sha256 /var/lib/dkms/mok.key /var/lib/dkms/mok.pub hello.ko
rmmod hello 2>/dev/null || true
insmod hello.ko
echo INSMOD-OK
