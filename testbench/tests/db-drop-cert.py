# db-drop-cert.py SUBJECT_CN OUT.esl : copy the current firmware db into OUT.esl, minus every
# X509 signature list whose certificate subject CN equals SUBJECT_CN. Prints what it keeps.
import glob, struct, subprocess, sys, uuid
X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
cn, out = sys.argv[1], sys.argv[2]
data = open(glob.glob("/sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f")[0], "rb").read()[4:]
keep, dropped, i = b"", 0, 0
while i + 28 <= len(data):
    typ = data[i:i+16]
    lsize, hsize, ssize = struct.unpack("<III", data[i+16:i+28])
    lst = data[i:i+lsize]
    label = "hash list"
    if typ == X509:
        der = lst[28+hsize+16:lsize]
        label = subprocess.run(["openssl", "x509", "-inform", "der", "-noout", "-subject", "-nameopt", "multiline"],
                               input=der, capture_output=True).stdout.decode()
        label = [l.split("=", 1)[1].strip() for l in label.splitlines() if "commonName" in l][0]
    if typ == X509 and label == cn:
        dropped += 1
        print("drop:", label)
    else:
        keep += lst
        print("keep:", label)
    i += lsize
if dropped != 1:
    sys.exit(f"expected exactly one '{cn}' list, found {dropped}; nothing written")
open(out, "wb").write(keep)
