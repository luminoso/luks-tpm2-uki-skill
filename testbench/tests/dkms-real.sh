# A real DKMS module, signed by DKMS with the key in /etc/dkms/framework.conf.d (guide §12), loaded.
# Run once to install; run again after a kernel upgrade to check DKMS rebuilt and signed it.
# Last line: DKMS-OK <signer> or DKMS-FAIL.
set -eux
export DEBIAN_FRONTEND=noninteractive
V=$(uname -r)
apt-get install -yq dkms build-essential "linux-headers-$V" >/dev/null
if [ ! -d /usr/src/tbhello-1.0 ]; then
  mkdir -p /usr/src/tbhello-1.0
  cat > /usr/src/tbhello-1.0/tbhello.c <<'C'
#include <linux/module.h>
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("test bench DKMS module");
static int __init h(void) { pr_info("tbhello loaded\n"); return 0; }
static void __exit b(void) {}
module_init(h);
module_exit(b);
C
  echo 'obj-m := tbhello.o' > /usr/src/tbhello-1.0/Makefile
  cat > /usr/src/tbhello-1.0/dkms.conf <<'C'
PACKAGE_NAME="tbhello"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="tbhello"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
C
  dkms add tbhello/1.0
fi
dkms install tbhello/1.0 -k "$V" || true
signer=$(modinfo -F signer "$(modinfo -n tbhello)")
modprobe -r tbhello 2>/dev/null || true
if modprobe tbhello; then echo "DKMS-OK $signer"; else echo DKMS-FAIL; fi
