# Test bench for the TPM2 + UKI guide

QEMU/KVM with OVMF Secure Boot firmware (`OVMF_CODE_4M.secboot`, blank vars so it starts in Setup Mode), a swtpm TPM 2.0 on `tpm-crb`, and an NVMe disk so device names match the guide.

Host tools come from a Fedora distrobox:

```bash
distrobox create --name tpmlab --image registry.fedoraproject.org/fedora:45 \
  --additional-packages "qemu-system-x86 qemu-img swtpm swtpm-tools edk2-ovmf openssh-clients xorriso"
```

## Build the base disk once

d-i preseeding cannot create LUKS without LVM, so a throwaway Debian cloud VM builds the target with debootstrap: ESP p1, LUKS2 p2 with btrfs `@rootfs`, ext4 `/boot` p3, stock GRUB, passphrase `testpass`.

```bash
ssh-keygen -t ed25519 -N '' -f lab_key            # then put lab_key.pub in seed/user-data
curl -LO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2   # into images/
distrobox enter tpmlab -- xorriso -as mkisofs -o images/seed.iso -V cidata -J -r seed/
distrobox enter tpmlab -- ./builder-up.sh
./lab-ssh.sh 2222 'bash -s' < build-target.sh
./lab-ssh.sh 2222 poweroff
```

## Run the guide

```bash
distrobox enter tpmlab -- env OPTION=1 ./run-all.sh o1   # own Secure Boot keys (default)
distrobox enter tpmlab -- env OPTION=2 ./run-all.sh o2   # factory Microsoft keys, UKI key as MOK
```

`steps/NN-*.sh` are the guide's commands. `run-all.sh` picks the ones for each option, in guide order: keys, packages, config, switch to shim + systemd-boot with the re-sign hook, firmware keys and MOKs, Debian's certificate denied (`10-distrust-debian.sh`), TPM sealing, then checks. `steps/04-uki-bootloader.sh` is the stricter no-shim variant, not used by `run-all.sh`.

`tests/` holds the negative tests. `tests/dkms-insmod.sh` builds and loads a module signed with the DKMS key. `tests/n5-prepare.sh` and `tests/n5-replay.py` are the Debian-kernel attack: stage a Debian-signed kernel with a stock initrd, boot it, replay the missing PCR 7 and PCR 11 events, ask the TPM for the key.

`mok-enroll.sh NAME NKEYS PASSWORD` reboots a VM and confirms a pending `mokutil --import` in MokManager by sending keys to the serial console. MokManager's serial output lags one keypress behind, so it sends a fixed sequence instead of reading the screen.

VM control (`vm.sh`): `new` (add `ms` for factory Microsoft keys), `start`, `stop`, `type` (serial console input), `snap`/`restore` (disk, UEFI vars and TPM state together, never one without the others). `boot.sh NAME` boots and prints `RESULT=AUTO` (reached SSH without a passphrase prompt), `RESULT=PROMPT` (prompt seen, passphrase typed) or `RESULT=FAIL`.

Differences from a real install:

- The kernel command line gets `console=tty0 console=ttyS0,115200` (`EXTRA_CMDLINE`) so the passphrase prompt shows up on the serial console.
- Root has password `root` and an SSH key.
- Both options start from OVMF's Microsoft-enrolled variables, like a new PC. "Clear Secure Boot keys" in firmware setup is simulated with `vm.sh clearkeys` (deletes PK/KEK/db/dbx with `virt-fw-vars`, keeps boot entries).
- `mokutil --import` gets its password from `--hash-file` instead of a prompt (`MOK_HASH_FILE`), and MokManager is driven with a fixed key sequence (`mok-enroll.sh`).
- The base system comes from debootstrap, not d-i, so the package set is smaller.
- Firmware updates and real GPU option ROMs are not tested. The virtio NIC's iPXE ROM does exercise `sbctl enroll-keys --tpm-eventlog`.
