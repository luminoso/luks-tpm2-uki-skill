# Guide §12: deny Debian's certificate in shim (MokListX). After the confirmation reboot, shim runs only
# what your keys signed. Run only after section 10's hook has re-signed systemd-boot and MokManager.
set -euxo pipefail
. /etc/kernel/esp-signing.conf
for f in $FILES; do
  [ -f "$f" ] || continue
  sbverify --cert "$CERT" "$f" >/dev/null           # stop if anything shim needs is not signed by you
done
D=$(mktemp -d)
(cd "$D" && mokutil --export)
for f in "$D"/MOK-*.der; do
  if openssl x509 -inform der -in "$f" -noout -subject | grep -q 'CN *= *Debian Secure Boot CA'; then
    cp "$f" /etc/kernel/debian-secure-boot-ca.der
  fi
done
openssl x509 -inform der -in /etc/kernel/debian-secure-boot-ca.der -noout -subject -fingerprint -sha256
mokutil --mokx --import /etc/kernel/debian-secure-boot-ca.der ${MOK_HASH_FILE:+--hash-file "$MOK_HASH_FILE"}   # test bench: no prompt
mokutil --mokx --list-new | grep 'Subject:'
