# Guide §12: enroll your own Secure Boot keys (firmware must be in Setup Mode), plus option ROM hashes.
set -euxo pipefail
sbctl status
sbctl enroll-keys --tpm-eventlog
sbctl status
