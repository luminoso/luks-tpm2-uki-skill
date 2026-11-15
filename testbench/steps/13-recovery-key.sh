# Guide §17: add a recovery key. Test bench only keeps it in /root/recovery-key.txt so the runner can
# type it; on a real machine it goes on paper or into a password manager, never into a file or log.
set -euo pipefail
DEV=/dev/nvme0n1p2
systemd-cryptenroll --recovery-key "$DEV" 2>&1 | grep -oE '([a-z]{8}-){7}[a-z]{8}' | head -1 > /root/recovery-key.txt
grep -cE '^([a-z]{8}-){7}[a-z]{8}$' /root/recovery-key.txt
systemd-cryptenroll "$DEV"
