# Guide §13: seal the LUKS key: pcrlock (firmware, GPT, Secure Boot) + signed PCR 11 (UKI, initrd only).
set -euxo pipefail
DEV=/dev/nvme0n1p2
PCRLOCK=/usr/lib/systemd/systemd-pcrlock
$PCRLOCK lock-firmware-code
$PCRLOCK lock-firmware-config
$PCRLOCK lock-secureboot-policy
$PCRLOCK lock-secureboot-authority
$PCRLOCK lock-gpt
# Pick the PCRs to lock for this host (make-policy drops any it cannot predict). PCR 12 must
# stay out: make-policy writes its policy as a credential to the ESP, measured into PCR 12.
PCRS=${PCRS:-0,1,2,3,7,13}   # PCR 7 is required, the rest is per host
echo "PCRS=$PCRS" > /etc/kernel/pcrlock-pcrs
$PCRLOCK make-policy --pcr=$PCRS --recovery-pin=query 2>&1 | tee /tmp/make-policy.out
# Stop if PCR 7 did not make it into the policy.
grep "PCRs in protection mask:.*\b7 (secure-boot-policy)" /tmp/make-policy.out
# --tpm2-pcrs= (empty): no literal PCR binding, pcrlock and the signature cover everything.
systemd-cryptenroll --wipe-slot=tpm2 \
  --tpm2-device=auto \
  --tpm2-pcrlock=/var/lib/systemd/pcrlock.json \
  --tpm2-public-key=/etc/systemd/tpm2-pcr-public-key.pem \
  --tpm2-public-key-pcrs=11 \
  --tpm2-pcrs= \
  $DEV
systemd-cryptenroll $DEV
cryptsetup luksDump $DEV | sed -n '/^Tokens:/,/^Digests:/p'
