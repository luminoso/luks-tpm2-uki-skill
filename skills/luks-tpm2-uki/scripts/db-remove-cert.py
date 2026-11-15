#!/usr/bin/env python3
"""Build a new firmware db signature list: the current db minus one certificate.

    python3 db-remove-cert.py REMOVE.der KEEP.der OUT.esl

REMOVE.der: the certificate to drop (DER), e.g. /var/lib/dkms/mok.pub.
KEEP.der:   your db signing certificate (DER). The script refuses unless it stays in the list.
OUT.esl:    written only if exactly one REMOVE entry was found and KEEP is still present.

Reads /sys/firmware/efi/efivars/db-*; writes nothing else. Then, as root, sign and write it with
your KEK, after keeping the old state as a pcrlock variant (references/pcr-selection.md):
    sign-efi-sig-list -k KEK.key -c KEK.pem db OUT.esl OUT.auth
    chattr -i /sys/firmware/efi/efivars/db-*; efi-updatevar -f OUT.auth db
"""
import struct, sys, uuid

X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
DB = "/sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f"

remove, keep, out = (open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read(), sys.argv[3])
var = open(DB, "rb").read()[4:]
new, dropped, kept, i = b"", 0, 0, 0
while i + 28 <= len(var):
    lsize, hsize, ssize = struct.unpack("<III", var[i+16:i+28])
    lst = var[i:i+lsize]
    if var[i:i+16] == X509:
        if lsize - 28 - hsize != ssize:
            sys.exit("an X509 list holds more than one certificate; not writing anything")
        der = lst[28+hsize+16:]
        if der == remove:
            dropped += 1
            i += lsize
            continue
        kept += der == keep
    new += lst
    i += lsize
if dropped != 1 or kept != 1:
    sys.exit(f"expected to drop 1 and keep 1, got dropped={dropped} kept={kept}; not writing anything")
open(out, "wb").write(new)
print(f"wrote {out}: {len(new)} bytes")
