# Guide §12, option 1: enroll the DKMS module signing key as a MOK (confirmed in MokManager on reboot).
set -euxo pipefail
dkms generate_mok
mokutil --import /var/lib/dkms/mok.pub ${MOK_HASH_FILE:+--hash-file "$MOK_HASH_FILE"}   # test bench: no prompt
mokutil --list-new | grep 'Subject:'
