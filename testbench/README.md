# Test bench for the TPM2 + UKI guide

QEMU/KVM with OVMF Secure Boot firmware (`OVMF_CODE_4M.secboot`, blank vars so it starts in Setup Mode), a swtpm TPM 2.0 on `tpm-crb`, and an NVMe disk so device names match the guide.

Host tools come from a Fedora distrobox:

```bash
distrobox create --name tpmlab --image registry.fedoraproject.org/fedora:45 \
  --additional-packages "qemu-system-x86 qemu-img swtpm swtpm-tools edk2-ovmf openssh-clients xorriso python3-virt-firmware cpio rpm"
```

`ci.sh` does everything below (base disk, second firmware build, one chain end to end) in one go, and is what `.github/workflows/e2e.yml` runs in a Fedora container with `/dev/kvm`:

```bash
distrobox enter tpmlab -- env OPTION=1 SHIM=0 bash ci.sh
```

## Build the base disk once

d-i preseeding cannot create LUKS without LVM, so a throwaway Debian cloud VM builds the target with debootstrap: ESP p1, LUKS2 p2 with btrfs `@rootfs`, ext4 `/boot` p3, stock GRUB, passphrase `testpass`. `SUITE=forky` builds Debian testing instead of 13.

```bash
ssh-keygen -t ed25519 -N '' -f lab_key            # then put lab_key.pub in seed/user-data
curl -LO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2   # into images/
distrobox enter tpmlab -- xorriso -as mkisofs -o images/seed.iso -V cidata -J -r seed/
distrobox enter tpmlab -- ./builder-up.sh
./lab-ssh.sh 2222 'bash -s' < build-target.sh
./lab-ssh.sh 2222 poweroff
```

The firmware-update test boots a second edk2 build, `images/OVMF_CODE_alt.qcow2` (`OVMF_CODE_4M.secboot.qcow2` from Fedora 42's `edk2-ovmf`; `ci.sh` fetches it).

## Run the guide

```bash
distrobox enter tpmlab -- env OPTION=1 ./run-all.sh e0          # own Secure Boot keys, no shim (default)
distrobox enter tpmlab -- env OPTION=1 SHIM=1 ./run-all.sh e1   # own keys + shim + MOK
distrobox enter tpmlab -- env OPTION=2 ./run-all.sh e2          # factory Microsoft keys, UKI key as MOK
```

Add `PORT=2202` (any free port) to run several VMs at once; each needs about 3 GB of RAM.

`steps/NN-*.sh` are the guide's commands. `run-all.sh` picks the ones for each chain, in guide order: keys, packages, config, switch to systemd-boot (`04-uki-bootloader.sh`) or shim + systemd-boot (`04-uki-bootloader-shim.sh`) with the re-sign hook, firmware keys and MOKs, Debian's certificate denied (`10-distrust-debian.sh`), TPM sealing. Then it checks: reboots without a prompt, a DKMS-style module (loads with a MOK; refused when signed only with the `db` key), command-line injection, the Debian-kernel attack, package reinstalls, then the operations from the skill's `scripts/`: `check-next-boot`, boot counting with a broken UKI (`12-broken-uki.sh`, fails three times, then skipped), a kernel upgrade, a planned firmware update with `pcrlock-update`, an unplanned one opened with the recovery key (`13-recovery-key.sh`) and the `tpm-unlock-check` alert.

`tests/` holds the negative tests. `tests/dkms-insmod.sh` builds and loads a module signed with the DKMS key. `tests/n5-prepare.sh` and `tests/n5-replay.py` are the Debian-kernel attack: stage a Debian-signed kernel with a stock initrd, boot it, replay the missing PCR 7 and PCR 11 events, ask the TPM for the key.

`mok-enroll.sh NAME NKEYS PASSWORD` reboots a VM and confirms a pending `mokutil --import` in MokManager by sending keys to the serial console. MokManager's serial output lags one keypress behind, so it sends a fixed sequence instead of reading the screen.

VM control (`vm.sh`): `new` (add `ms` for factory Microsoft keys), `start`, `stop`, `type` (serial console input), `snap`/`restore` (disk, UEFI vars and TPM state together, never one without the others). `reset` (reset button, for a halted guest), `swapfw NAME [CODE]` (boot another firmware build next time). `boot.sh NAME` boots and prints `RESULT=AUTO` (reached SSH without a passphrase prompt), `RESULT=PROMPT` (prompt seen, `$PASS` or the passphrase typed) or `RESULT=FAIL` (also when the initrd halts).

Differences from a real install:

- The kernel command line gets `console=tty0 console=ttyS0,115200` (`EXTRA_CMDLINE`) so the passphrase prompt shows up on the serial console.
- Root has password `root` and an SSH key.
- Both options start from OVMF's Microsoft-enrolled variables, like a new PC. "Clear Secure Boot keys" in firmware setup is simulated with `vm.sh clearkeys` (deletes PK/KEK/db/dbx with `virt-fw-vars`, keeps boot entries).
- `mokutil --import` gets its password from `--hash-file` instead of a prompt (`MOK_HASH_FILE`), and MokManager is driven with a fixed key sequence (`mok-enroll.sh`).
- The base system comes from debootstrap, not d-i, so the package set is smaller.
- A firmware update is simulated by switching to an edk2 build from another release; capsule updates (fwupd) are not tested. Real GPU option ROMs are not tested. The virtio NIC's iPXE ROM does exercise `sbctl enroll-keys --tpm-eventlog`.
- The test bench keeps the recovery key in `/root/recovery-key.txt` so it can type it. A real machine must not.
