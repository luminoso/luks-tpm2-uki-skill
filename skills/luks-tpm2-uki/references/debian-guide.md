# Debian 13 TPM2 disk decryption with a signed UKI

Automatic LUKS2 decryption from the TPM, no PIN, on Debian 13 (trixie). The chain is: Secure Boot, Debian's shim restricted to your own keys, systemd-boot, a Unified Kernel Image built by `kernel-install` + `ukify` + dracut, and a TPM2 policy made of `systemd-pcrlock` (firmware and Secure Boot state) plus a signed PCR 11 (kernel, initrd, command line).

There are two ways to set up Secure Boot. Section 2 explains how to choose:

- Option 1 (default): only your own keys in the firmware. Microsoft is removed.
- Option 2: the factory Microsoft keys stay. Your key is added to shim as a MOK.

Both keep DKMS modules (NVIDIA, VirtualBox, ZFS) working, and in both, shim is told to distrust Debian's own signing certificate so that only code you signed runs (section 2 explains why that matters). Steps that differ are marked "Option 1" or "Option 2". Everything else applies to both.

Kernel updates keep working without resealing. Nothing has to be "predicted" for a new kernel: each UKI carries a signature over the PCR 11 value it will produce, and the TPM accepts any value signed by your key.

Every command below was run on Debian 13.7 (systemd 257.13, dracut 106, sbctl 0.18, shim 16.1) in a QEMU/KVM VM with OVMF Secure Boot firmware and a swtpm TPM 2.0, starting from the factory state of a new PC (Microsoft keys, Secure Boot on). The one exception is `sbctl enroll-keys --microsoft` in section 4. The test bench is in `testbench/`. `OPTION=1 testbench/run-all.sh` and `OPTION=2 testbench/run-all.sh` repeat the whole guide from a clean install.

Example values used throughout. Replace them with yours (section 5 shows how to find them):

| What | Example |
|---|---|
| LUKS partition | `/dev/nvme0n1p2` |
| Mapper name | `nvme0n1p2_crypt` |
| Btrfs root subvolume | `@rootfs` |
| ESP mount point | `/boot/efi` |

## 1. What this protects, and what it does not

TPM-only decryption protects a disk that is removed from the machine, and a machine booted into anything other than your signed kernel: another OS, a USB stick, a modified initrd, a changed kernel command line, a Debian kernel with someone else's initrd, or the same machine with Secure Boot turned off.

It does not protect a stolen laptop that is powered on or can be powered on. The disk opens by itself and the attacker gets your login screen, so your login password, screen lock and any network services become the barrier. Physical attacks on a discrete TPM chip (bus sniffing) and DMA attacks are also out of scope. If that matters to you, add a PIN (`systemd-cryptenroll --tpm2-with-pin=yes`), which this guide leaves out on purpose.

## 2. Concepts and design choices

Read this first if disk encryption, Secure Boot or TPMs are new to you. The steps make more sense when you know what each piece defends against.

### The words used in this guide

LUKS is Linux disk encryption. Your data is encrypted with a random master key, and that master key is stored several times in "keyslots", each one locked by something different: your passphrase, a recovery key, the TPM. Adding the TPM adds a keyslot. The passphrase keeps working.

The TPM (Trusted Platform Module) is a small security chip, or a firmware feature of the CPU, on the motherboard. It can keep a secret and hand it out only when certain conditions hold.

PCRs (Platform Configuration Registers) are those conditions. Before each boot stage starts the next one, it hashes the next one and "extends" a PCR with it: new value = hash(old value + measurement). A PCR cannot be set, only extended, and every PCR resets when the machine powers on. The final values are a fingerprint of everything that ran, in order. Change one byte of the boot loader and the fingerprint is different.

Sealing means the TPM encrypts the LUKS key under a policy such as "release this only if PCR 7 has value X". A different boot chain produces different PCRs, and the TPM refuses.

Secure Boot is the firmware checking a signature on every program before running it. Four lists of keys in firmware storage drive it: PK (the platform owner), KEK (who may change the next two), db (signers and file hashes that are allowed) and dbx (revoked ones).

Secure Boot and the TPM do different jobs. Secure Boot decides what may run. The TPM records what did run and decides whether the disk key comes out. This guide uses both.

shim is a small first-stage boot loader that Linux distributions use. The firmware checks shim's signature. shim then checks the next program itself, against three sources: the distribution's own certificate built into shim (Debian's, here), the firmware's `db`, and the MOK list. It also has a deny list, MokListX.

MOK (Machine Owner Key) is a list of extra keys that you add yourself with `mokutil`. shim trusts them, and passes them to the Linux kernel, which accepts them for kernel modules. Adding a MOK, or a MokListX entry, needs a confirmation at the console on the next boot (MokManager), so software alone cannot add one.

The ESP (EFI System Partition) is a small FAT partition the firmware reads boot programs from. It cannot be encrypted, because the firmware has to read it before anything is decrypted. Anyone with a screwdriver or a USB stick can change its files, which is why everything on it is signed.

The initrd (initial RAM disk) is a small filesystem the kernel starts before your real root filesystem exists. It holds the tools that open LUKS. It is the program that asks for your passphrase, or asks the TPM for the key, so whoever controls the initrd controls your key.

A UKI (Unified Kernel Image) is one EFI program that bundles the kernel, the initrd, the kernel command line and some metadata, signed as one file.

DKMS builds kernel modules that Debian does not ship ready-made, such as the proprietary NVIDIA driver, VirtualBox or ZFS, and signs them with its own key in `/var/lib/dkms/`. With Secure Boot on, the kernel loads such a module only if that key is a MOK.

### Choosing an option

| | Option 1 (default): your own keys | Option 2: Microsoft keys kept |
|---|---|---|
| Firmware `db` trusts | only your key, plus option ROM hashes of your hardware | Microsoft's Windows and third-party certificates (factory state) |
| shim then trusts | your `db` key and your MOKs (Debian's certificate denied) | your MOKs (Debian's certificate denied) |
| What the firmware will start | only your copy of shim | your shim, plus anything Microsoft signed: other distributions, Windows, old boot loaders with known holes until they are revoked |
| Firmware Setup Mode | needed once | not needed |
| sbctl (built from source) | needed | not needed |
| Option ROM risk (GPU, add-in cards) | hashes enrolled, a swapped card may not start | none |
| Windows dual boot | no (unless you enroll Microsoft's keys too) | yes |
| DKMS modules | yes, through MOK | yes, through MOK |

Choose option 1 when you want the machine to run as little foreign code as possible and you control the hardware. Choose option 2 when the firmware cannot enter Setup Mode, when you dual boot Windows, when you cannot risk a GPU that will not start, or when you want fewer moving parts.

For the disk key the two are close, with one difference. In option 2 the firmware still starts anything Microsoft signed. Another distribution's shim leads to a different PCR 7, so the TPM refuses (by design, not tested). But an old Microsoft-signed boot program with an exploitable bug would let an attacker run code before your chain and fake the remaining measurements. That is the class of attack BlackLotus used (see below). Option 1 does not start such programs at all.

A stricter variant removes shim entirely: firmware, then systemd-boot signed by you, then your UKI. It passed the same tests, but DKMS modules cannot load without shim. Its steps are in `testbench/steps/04-uki-bootloader.sh` and are not covered here.

### Why a UKI instead of a separate kernel and initrd

On a standard Debian install with Secure Boot, the firmware checks shim, shim checks GRUB, and GRUB checks the kernel. Nobody checks the initrd. Debian cannot sign it, because `update-initramfs` builds it on your machine, and it sits on the unencrypted `/boot` partition. The kernel command line comes from `grub.cfg`, also unsigned.

That leaves the classic "evil maid" attack: someone with a few minutes alone with your laptop adds a line to the initrd that saves your passphrase, and collects it later. Secure Boot does not notice, because the initrd was never part of the signature.

You could seal the TPM key to the PCR that measures the initrd, but the initrd changes on every kernel, dracut or microcode update, so you would reseal after each one.

A UKI fixes both. One signature covers the whole bundle, command line included, so shim refuses a modified one (tested in section 16). systemd-stub, the small program at the front of every UKI, measures those parts into PCR 11 in a way `ukify` can calculate in advance. `ukify` signs the expected PCR 11 value with your key, and the TPM accepts any value carrying that signature. A new kernel brings its own signature, so nothing needs resealing.

### Why systemd-boot instead of GRUB

GRUB is close to a small operating system: filesystem drivers, a scripting language, an editable command line, a shell. Every one of those runs before the disk is decrypted, and every one is attack surface. BootHole (CVE-2020-10713) was a buffer overflow in GRUB's config file parser that let an attacker run code past Secure Boot.

systemd-boot does one job: show a menu and start EFI programs from the ESP. A UKI is an EFI program, so that is all this setup needs.

Measurements matter too. GRUB measures each command it runs and the files it reads into PCRs 8 and 9, and those values change whenever `grub.cfg` is regenerated. With systemd-boot and a UKI, everything that matters ends up in PCR 11 in a predictable form, and PCR 8 stays zero.

Finally, `kernel-install`, `ukify`, `bootctl`, systemd-stub and `systemd-pcrlock` come from one project and are designed to work together. The Debian systemd-boot package even sets up shim in front of systemd-boot by itself once GRUB is gone (section 10).

What you give up: GRUB's extras, such as booting btrfs snapshots from the menu. systemd-boot still lists Windows if it sits on the same ESP.

### Why your own Secure Boot keys (option 1), and where MOK fits

Most PCs ship with two Microsoft certificates in `db`: one for Windows, and the "Microsoft UEFI CA" for third parties. The second signs the shim of nearly every Linux distribution, plus various tools and the option ROMs of most add-in cards. Anything signed by either one boots on your machine. That includes old versions with known holes until they are added to `dbx`. The BlackLotus bootkit (2023) used CVE-2022-21894, a flaw in an old but still validly signed Windows boot manager, to switch Secure Boot off on fully patched machines.

In option 1, `db` holds only your certificate plus the option ROM hashes of your hardware. The firmware starts your copy of shim, which you signed, and nothing from Microsoft.

In option 2, Microsoft's certificates stay in `db`. MOK is how your own UKI signing key gets in: shim trusts it because you enrolled it.

In both options, MOK is also what lets DKMS modules load: the DKMS key becomes a MOK, and the kernel accepts modules signed with it.

What option 1 costs you:

- Windows no longer boots unless you also enroll Microsoft's keys (`sbctl enroll-keys --microsoft`), which brings their trust back.
- Add-in cards need their option ROM hashes enrolled (section 4).
- The keys in `/var/lib/sbctl/keys` are now the root of trust for your machine. Anyone who copies them can sign code your firmware will run, so back them up offline (section 17) and protect root on this machine.

### Why shim must distrust Debian's certificate

shim has Debian's certificate built in, so out of the box it runs anything Debian ever signed: Debian's GRUB, every Debian kernel, MokManager. A Debian kernel accepts any initrd, signed or not. That opens a way around the TPM:

1. An attacker with access to the ESP copies a stock Debian kernel and an initrd of their own there, and adds a boot entry for it.
2. shim accepts the kernel, because Debian signed it. The attacker's initrd runs.
3. The PCRs the TPM checks are almost right. PCR 0 to 3 match, because it is your firmware. PCR 7 matches except for its last entry, the one that records your key approving the UKI. PCR 11 is empty.
4. PCRs can be extended from software. The initrd adds the missing PCR 7 entry, and the PCR 11 measurements of your UKI, which anyone can compute from the UKI file on the ESP. The `.pcrsig` signature is in that file too.
5. The TPM now sees exactly the values it expects and releases the disk key.

In the test VM this worked on both options until Debian's certificate was denied (`testbench/tests/n5-*`). With Debian's certificate in shim's deny list (MokListX), shim refuses the Debian kernel with "Security Policy Violation", and the refusal itself adds an entry to PCR 7, so the TPM stays shut for that boot as well.

Denying Debian means shim also refuses Debian's signed systemd-boot and MokManager. Section 10 re-signs both with your key, and an apt hook repeats that after every package update. The Debian kernel inside your UKI is not affected: shim checks the UKI as a whole, and the UKI carries your signature.

### Why dracut instead of initramfs-tools

The TPM setup here needs systemd inside the initrd. `systemd-cryptsetup` reads the TPM2 token and the PCR signature, and `systemd-pcrphase` measures the boot phase into PCR 11. Debian's default, `initramfs-tools`, builds an initrd without systemd, so neither runs. dracut builds a systemd-based initrd.

### Why pcrlock and a signed PCR 11 instead of fixed PCR values

The simplest TPM setup, `systemd-cryptenroll --tpm2-pcrs=0+7+11`, seals the key to today's exact values. The next kernel update changes PCR 11, the TPM refuses, and you type the passphrase and enroll again, on every update.

This guide splits the PCRs into two groups that change for different reasons:

- PCR 11 (kernel, initrd, command line) changes on every update. Instead of a fixed value, the TPM checks that the value is signed by your PCR key. Each new UKI carries its own signature. This is how the guide "predicts" the next kernel's values: `ukify` calculates them when it builds the UKI, and signs them.
- Firmware and Secure Boot PCRs (0 to 3, 7) change rarely: firmware updates, BIOS settings. `systemd-pcrlock` predicts their values from the TPM event log and stores the allowed values in a small storage area inside the TPM (an NV index), not in the LUKS header. When firmware changes, you rewrite the NV index with your recovery PIN (section 15) instead of enrolling the disk again.

### Why no PIN, and why keep the passphrase

A TPM PIN makes the TPM refuse the key until someone types it. That protects a stolen laptop much better (see section 1), but you type something at every boot, which this guide's goal rules out. Adding a PIN later is one `systemd-cryptenroll` command.

Keep the passphrase no matter what. Every TPM refusal (firmware update, BIOS change, new motherboard, a detected attack) falls back to it. A recovery key (section 17) is a second fallback.

## 3. How the pieces fit

```
UEFI firmware, Secure Boot
  option 1: db = your key only; option 2: db = Microsoft's keys
  measures firmware code and config into PCR 0-3, Secure Boot state into PCR 7
  verifies shim (option 1: your signature; option 2: Microsoft's)
        |
shim (Debian's: option 1 shim-unsigned in ESP/EFI/shim/, option 2 shim-signed in ESP/EFI/debian/)
  Debian's certificate denied via MokListX
  measures MOK lists into PCR 14, its SBAT level and approving certificates into PCR 7
  verifies systemd-boot and UKIs: only your db key (option 1) or your MOK (option 2)
        |
systemd-boot (re-signed by you)
  measures loader.conf into PCR 5, starts UKIs from ESP/EFI/Linux/
        |
systemd-stub inside the UKI (signed by you)
  measures the kernel, initrd, embedded command line and PCR public key into PCR 11
  ignores any command line passed by the boot loader (Secure Boot is on and the UKI has one)
        |
dracut initrd
  systemd-pcrphase measures "enter-initrd" into PCR 11
  systemd-cryptsetup asks the TPM for the key. The TPM checks:
    - pcrlock NV index policy: the PCRs you chose, at least PCR 7
    - PolicyAuthorize: PCR 11 matches a value signed by your PCR key, for the enter-initrd phase only
  after switch-root PCR 11 changes again, so the running system can no longer get the key
        |
kernel: loads Debian's modules and DKMS modules signed with a MOK
```

What the PCRs hold on this setup (measured in the test VM):

| PCR | Contents | Locked by |
|---|---|---|
| 0, 2 | Firmware code, option ROMs | pcrlock (optional) |
| 1, 3 | Firmware settings, boot order | pcrlock (optional, fragile) |
| 4 | Hashes of shim, systemd-boot and the UKI | not locked: changes with every update |
| 5 | systemd-boot `loader.conf`, GPT | not locked: pcrlock drops it |
| 7 | Secure Boot on/off, PK/KEK/db/dbx, shim's SBAT level, which certificate approved each step, refusals by MokListX | pcrlock (required) |
| 8 | Always zero with systemd-boot | nothing to lock |
| 11 | UKI sections + boot phase | signed policy (always) |
| 12 | pcrlock's own credential from the ESP | must not be locked |
| 13 | sysexts (zero here) | pcrlock (optional) |
| 14 | shim's MOK lists | not locked: pcrlock drops it |

### Choosing PCRs

The signed PCR 11 is always part of the policy. On top of it, pcrlock locks a set of PCRs you choose per host. That set must include PCR 7:

- PCR 7 is required. PCR 11 is extended by software, so your genuine UKI booted with Secure Boot off produces the same signed PCR 11 value. PCR 7 is what ties the signature to a boot chain that ran only signed code. Section 16 shows the key being released with Secure Boot off when PCR 7 is left out.
- PCR 0 and 2 add firmware code and option ROMs. Firmware updates then need a re-lock (section 15).
- PCR 1 and 3 add firmware settings, including boot order. Any BIOS setting change, or `efibootmgr -o`, sends you to the passphrase prompt until you re-lock. Leave them out if you change BIOS settings often.
- `make-policy` refuses PCRs it cannot predict from the event log and prints what it kept. Read the line `PCRs in protection mask:` after running it. If 7 is not in it, stop and do not enroll.

The minimum is `PCRS=7`. The examples use `PCRS=0,1,2,3,7,13`.

There is no right number. Each extra PCR catches one more kind of tampering, and also adds one more kind of routine event that sends you to the passphrase prompt and a re-lock. Section 13 shows how to check which PCRs your host can support before you decide. Then drop any you would trip over:

| If you... | Leave out |
|---|---|
| change BIOS settings or the boot order, or boot from USB now and then | 1, 3 |
| install firmware updates often (fwupd, vendor tools) | 0, 2 |
| swap GPUs or other add-in cards | 2 |
| none of the above | nothing, use what `predict` keeps |

### Where things live

Every path in this guide, and whether it is a standard location:

| Path | What | Whose convention |
|---|---|---|
| `/var/lib/sbctl/keys/{PK,KEK,db}/` | Option 1: Secure Boot keys and certificates | sbctl's default |
| `/usr/local/bin/sbctl` | Option 1: sbctl built from source | FHS: locally built software |
| `/etc/kernel/secure-boot-private-key.pem`, `/etc/kernel/secure-boot-certificate.pem` (+ `.der`) | Option 2: your signing key, enrolled as a MOK | systemd: example paths in Debian's `/usr/lib/kernel/uki.conf` |
| `/var/lib/dkms/mok.key`, `/var/lib/dkms/mok.pub` | DKMS module signing key, enrolled as a MOK | Debian dkms default |
| `/etc/systemd/tpm2-pcr-private-key.pem`, `/etc/systemd/tpm2-pcr-public-key.pem` | Key that signs PCR 11 values, and its public half | systemd: example paths in `/usr/lib/kernel/uki.conf`; `systemd-cryptenroll` uses the public one by default |
| `/etc/kernel/uki.conf` | ukify settings used by kernel-install | systemd (replaces `/usr/lib/kernel/uki.conf` as a whole) |
| `/etc/kernel/install.conf`, `/etc/kernel/cmdline` | UKI layout, embedded command line | systemd kernel-install |
| `/etc/dracut.conf.d/50-tpm2-uki.conf` | dracut options | dracut drop-in directory |
| `/etc/crypttab` | LUKS volumes | standard |
| `/var/lib/pcrlock.d/`, `/var/lib/systemd/pcrlock.json` | Recorded components, current policy | systemd-pcrlock defaults |
| `ESP/EFI/shim/shimx64.efi`, `mmx64.efi` | Option 1: shim and MokManager, from `shim-unsigned`, signed by you | this guide |
| `ESP/EFI/debian/shimx64.efi`, `mmx64.efi`, `fbx64.efi`, `ESP/EFI/BOOT/BOOTX64.EFI` | Option 2: shim, MokManager, fallback loader, removable-media copy of shim | Debian's systemd-boot package |
| `ESP/EFI/systemd/systemd-bootx64.efi` | systemd-boot | systemd-boot |
| `ESP/loader/credentials/pcrlock.<machine-id>.cred` | Copy of the policy for the initrd | written by systemd-pcrlock |
| `ESP/EFI/Linux/<machine-id>-<version>.efi` | Signed UKIs | Boot Loader Specification, Type #2 |
| `ESP/loader/loader.conf` | systemd-boot menu settings | systemd-boot |
| `/etc/kernel/esp-signing.conf`, `/usr/local/sbin/resign-esp`, `/etc/apt/apt.conf.d/99-resign-esp`, `/var/lib/resign-esp/` | Which key re-signs which boot files, the script, its apt hook, hashes of the last copied shim files | this guide (FHS: local scripts) |
| `/etc/kernel/debian-secure-boot-ca.der` | Debian's certificate, as denied in MokListX | this guide only |
| `/etc/apt/preferences.d/no-grub` | Package pins | apt drop-in directory |
| `/etc/kernel/pcrlock-pcrs` | Your chosen pcrlock PCR list | this guide only |

Putting keys at the conventional paths does not turn signing on by itself. All settings in Debian's `/usr/lib/kernel/uki.conf` are commented out. In the test VM, with keys copied to `/etc/kernel/secure-boot-private-key.pem`, `/etc/kernel/secure-boot-certificate.pem` and the two `/etc/systemd/tpm2-pcr-*` files and no `/etc/kernel/uki.conf`, kernel-install wrote an unsigned UKI with no PCR signature, which Secure Boot refuses. `/etc/kernel/uki.conf` is what makes the signing happen.

## 4. Before you start

1. Set a root password, so the emergency shell works if the initrd fails. Debian may leave root locked.

   ```bash
   passwd root
   passwd -S root      # second field must be P
   ```

2. Make sure the LUKS volume has a passphrase keyslot that you know. Every TPM failure falls back to it.

   ```bash
   cryptsetup luksDump /dev/nvme0n1p2 | grep -A2 '^Keyslots'
   cryptsetup luksAddKey /dev/nvme0n1p2      # only if you have no passphrase slot
   ```

3. You need a keyboard and screen on the machine for a few reboots. Enrolling a MOK, or denying a certificate, is confirmed in MokManager, a blue text screen shown by shim before anything else loads. On a headless server, use the remote console (IPMI, iDRAC, iLO) for those reboots.

4. Option 1: check that your firmware can clear the Secure Boot keys or enter Setup Mode, and can turn Secure Boot off again. You need the first at the end of section 10 and the second if something goes wrong.

5. Option 1: discrete GPU or other add-in cards with option ROMs. Without the Microsoft CA in `db`, the firmware only runs option ROMs whose hashes you enroll. Section 12 enrolls the hashes from the TPM event log. If a card is swapped later, it may not initialize until you re-enroll. If that risk is unacceptable, use option 2, or enroll with `sbctl enroll-keys --microsoft`, which trusts Microsoft's option ROM CA.

## 5. Find your device names

```bash
lsblk -o NAME,FSTYPE,UUID,MOUNTPOINTS
cryptsetup luksUUID /dev/nvme0n1p2         # UUID of the LUKS container
dmsetup ls --target crypt                  # current mapper name, e.g. nvme0n1p2_crypt
btrfs subvolume show / | head -1           # root subvolume, e.g. @rootfs
findmnt /boot/efi                          # ESP mount point
```

The commands below set two shell variables. Use the same shell for sections 8 to 10, or set them again.

```bash
DEV=/dev/nvme0n1p2
NAME=nvme0n1p2_crypt
UUID=$(cryptsetup luksUUID $DEV)
```

`/etc/fstab` needs no change if it already mounts `/dev/mapper/$NAME` (or the filesystem UUID) with `subvol=@rootfs`. A Debian installer layout already does.

## 6. Create your signing keys

This comes before installing the boot packages on purpose. Installing systemd-boot adds a boot entry at the front of the boot order that factory firmware refuses, and it replaces the removable-media fallback `EFI/BOOT/BOOTX64.EFI`. In the test VM that left nothing bootable. Option 2 enrolls its key here, so the MokManager reboot happens while shim and GRUB still boot normally.

### Option 1: build sbctl and create Secure Boot keys

Why your own keys: section 2.

sbctl is not packaged in Debian (not in trixie, backports or sid), and upstream publishes only a signed source tarball. It builds with trixie's Go:

```bash
apt install golang-go gpg libpcsclite-dev pkgconf
cd /root
V=0.18
curl -fsSLO https://github.com/Foxboron/sbctl/releases/download/$V/sbctl-$V.tar.gz
curl -fsSLO https://github.com/Foxboron/sbctl/releases/download/$V/sbctl-$V.tar.gz.sig
gpg --keyserver hkps://keys.openpgp.org --recv-keys C100346676634E80C940FB9E9C02FF419FECBE16
gpg --verify sbctl-$V.tar.gz.sig sbctl-$V.tar.gz      # must say "Good signature from Morten Linderud"
tar xzf sbctl-$V.tar.gz && cd sbctl-$V
GOTOOLCHAIN=local go build -trimpath -o sbctl ./cmd/sbctl
install -m 0755 sbctl /usr/local/bin/sbctl
```

`GOTOOLCHAIN=local` stops Go from downloading a newer toolchain behind your back.

Create the keys. They go to `/var/lib/sbctl/keys/{PK,KEK,db}/`:

```bash
sbctl create-keys
```

Nothing is enrolled in the firmware yet. That happens in section 12.

### Option 2: create a signing key and enroll it as a MOK

Create a key for signing UKIs and boot files, and the DKMS key, then ask shim to trust both:

```bash
apt install mokutil dkms
(umask 077; openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -subj "/CN=$(hostname) UKI signing key/" \
  -keyout /etc/kernel/secure-boot-private-key.pem -out /etc/kernel/secure-boot-certificate.pem)
openssl x509 -in /etc/kernel/secure-boot-certificate.pem -outform DER -out /etc/kernel/secure-boot-certificate.der
dkms generate_mok
mokutil --import /etc/kernel/secure-boot-certificate.der /var/lib/dkms/mok.pub    # asks for a one-time password
mokutil --list-new | grep Subject:
```

Reboot now and confirm the keys in MokManager (next subsection). After the reboot (passphrase prompt as usual), check:

```bash
mokutil --list-enrolled | grep 'Subject: CN'     # must list "UKI signing key" and "DKMS module signing key"
```

### Confirming a request in MokManager

`mokutil --import` (or `mokutil --mokx --import`) only queues the request. On the next boot shim shows MokManager:

1. "Press any key to perform MOK management". You have 10 seconds. If you miss it, the machine boots normally and the request is dropped: run the `mokutil` command again.
2. Choose "Enroll MOK" (or "Enroll MOKX" for a deny-list entry).
3. Optionally "View key N" to check the subject, then "Continue".
4. "Enroll the key(s)?": choose "Yes".
5. Type the password you gave `mokutil`.
6. Choose "Reboot".

## 7. Install packages

```bash
apt update
apt install systemd-boot systemd-ukify systemd-cryptsetup dracut tpm2-tools sbsigntool efibootmgr mokutil dkms
```

Installing dracut removes `initramfs-tools`. That is expected.

Installing `systemd-boot` immediately runs `bootctl install`, adds a "Linux Boot Manager" boot entry at the front, and writes a Type #1 entry for each installed kernel. Do not reboot between here and the end of section 10: the firmware refuses the new "Linux Boot Manager" entry.

## 8. crypttab, kernel command line and dracut

Why dracut instead of initramfs-tools: section 2.

`/etc/crypttab`:

```bash
echo "$NAME UUID=$UUID none luks,discard,tpm2-device=auto,x-initrd.attach" > /etc/crypttab
```

`/etc/kernel/cmdline` becomes the command line embedded in every UKI:

```bash
echo "rd.luks.name=$UUID=$NAME rd.luks.options=$UUID=tpm2-device=auto,discard root=/dev/mapper/$NAME rootflags=subvol=@rootfs rw quiet rd.shell=0 rd.emergency=halt" > /etc/kernel/cmdline
```

| Parameter | Why |
|---|---|
| `rd.luks.name=<UUID>=<name>` | Opens the container as `/dev/mapper/<name>`, the name `root=` and fstab use. The UKI then does not depend on the crypttab copy inside the initrd. |
| `rd.luks.options=<UUID>=tpm2-device=auto,discard` | Try the TPM token first, fall back to the passphrase. |
| `root=/dev/mapper/<name>` | Root filesystem device. |
| `rootflags=subvol=@rootfs` | Mount the Btrfs subvolume, not the top-level tree. |
| `rw` | Mount root read-write from the start. |
| `quiet` | Less console output. Optional. |
| `rd.shell=0 rd.emergency=halt` | If the initrd fails, halt instead of offering a shell. A shell at that point still has PCRs that match the policy. Debian's dracut already refuses (root is locked in the initrd); this makes it explicit. Tested: a forced failure printed "Could not boot. Halting." and stopped |

`kernel-install` appends `systemd.machine_id=...` by itself.

`/etc/dracut.conf.d/50-tpm2-uki.conf`:

```ini
hostonly="yes"
hostonly_cmdline="no"
compress="zstd"
add_dracutmodules+=" systemd-cryptsetup systemd-pcrphase tpm2-tss btrfs "
omit_dracutmodules+=" network cifs nfs iscsi nbd "
```

`systemd-pcrphase` is required: it measures the `enter-initrd` phase into PCR 11, and the PCR signature is made for that value. Without it the signed policy never matches. `hostonly_cmdline="no"` keeps dracut from baking a second command line into the initrd, because the UKI already carries one.

## 9. kernel-install, ukify, PCR signing key

Why a UKI, and why PCR 11 gets signed instead of fixed: section 2.

Tell `kernel-install` to build UKIs with dracut and ukify, `/etc/kernel/install.conf`:

```ini
layout=uki
initrd_generator=dracut
uki_generator=ukify
```

Create the key that signs PCR 11 values:

```bash
(umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /etc/systemd/tpm2-pcr-private-key.pem)
openssl pkey -in /etc/systemd/tpm2-pcr-private-key.pem -pubout -out /etc/systemd/tpm2-pcr-public-key.pem
```

`/etc/kernel/uki.conf`. The two `SecureBoot` lines depend on the option:

```ini
[UKI]
# Option 1:
SecureBootPrivateKey=/var/lib/sbctl/keys/db/db.key
SecureBootCertificate=/var/lib/sbctl/keys/db/db.pem
# Option 2 instead:
# SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem
# SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem
PCRPKey=/etc/systemd/tpm2-pcr-public-key.pem

[PCRSignature:initrd]
PCRPrivateKey=/etc/systemd/tpm2-pcr-private-key.pem
PCRPublicKey=/etc/systemd/tpm2-pcr-public-key.pem
Phases=enter-initrd
```

ukify signs the UKI with that key (through `sbsign`) and adds a `.pcrsig` section. `Phases=enter-initrd` matters: by default ukify signs every boot phase, which would let the fully booted system, or an attacker's root filesystem that the initrd was tricked into switching to, ask the TPM for the disk key. With only `enter-initrd` signed, the key is released in the initrd and nowhere else.

There is no `Linux=`, `Initrd=` or `Cmdline=` here: `kernel-install` passes the kernel, the dracut initrd and `/etc/kernel/cmdline` for each kernel version.

## 10. Switch to shim, systemd-boot and signed UKIs

Why systemd-boot instead of GRUB: section 2.

Build a signed UKI for every installed kernel first, so something bootable exists before anything is removed:

```bash
for k in /boot/vmlinuz-*; do kernel-install add "${k#/boot/vmlinuz-}" "$k"; done
bootctl list          # one "Type #2 (.efi)" entry per kernel
```

Each kernel now has `/boot/efi/EFI/Linux/<machine-id>-<version>.efi`. systemd-boot picks the newest by default and keeps older ones in the menu as a fallback.

Remove GRUB:

```bash
apt purge --allow-remove-essential grub-efi-amd64 grub-efi-amd64-signed grub-efi-amd64-bin \
  grub-efi-amd64-unsigned grub-common grub2-common os-prober \
  cryptsetup-initramfs initramfs-tools initramfs-tools-core initramfs-tools-bin
```

Debian marks the signed GRUB package as protected, hence `--allow-remove-essential`. Without the flag, apt asks you to type a confirmation phrase.

Install shim. The two options use different packages. Run only the block for your option.

Option 1, the same shim unsigned (you sign it yourself):

```bash
apt purge shim-signed shim-signed-common shim-helpers-amd64-signed systemd-boot-efi-amd64-signed
apt install shim-unsigned mokutil
apt autoremove --purge
```

Option 2, shim signed by Microsoft, which your firmware trusts:

```bash
apt install shim-signed systemd-boot-efi-amd64-signed mokutil
apt autoremove --purge
```

Option 1 cannot use `shim-signed`. Its pre-install script checks whether the firmware's `db` trusts Microsoft's signature on shim and refuses otherwise. In the test VM, with only your key in `db`, every reinstall or upgrade of `shim-signed` failed with "FATAL ERROR - your system will not currently boot with this signed shim installed" and left dpkg half-configured. `shim-unsigned` is the same shim without Microsoft's signature, which option 1 does not need.

Keep GRUB, `initramfs-tools` and (option 1) the signed shim packages from coming back:

```bash
cat > /etc/apt/preferences.d/no-grub <<'EOF'
Package: grub-efi-amd64-signed grub-efi-amd64
Pin: release *
Pin-Priority: -1

Package: initramfs-tools initramfs-tools-core
Pin: release *
Pin-Priority: -1
EOF
```

Option 1 also keeps the signed shim packages out, so an upgrade never pulls them back in:

```bash
cat >> /etc/apt/preferences.d/no-grub <<'EOF'

Package: shim-signed shim-helpers-amd64-signed systemd-boot-efi-amd64-signed
Pin: release *
Pin-Priority: -1
EOF
```

The second block matters. `intel-microcode` and `amd64-microcode` recommend `initramfs-tools`. In the test VM, `apt install intel-microcode` without this pin removed dracut, rebuilt the UKI with an initramfs-tools initrd that has no cryptsetup, and the next boot stopped in a BusyBox shell. With the pin, apt skips the recommendation and dracut rebuilds the UKI with the new microcode.

Put shim in front of systemd-boot on the ESP. Both options start with:

```bash
ESP=$(bootctl --print-esp-path)
rm -f "$ESP"/EFI/debian/grub* "$ESP"/EFI/BOOT/grub*
```

Option 1, your own directory. The boot entry comes after the files are signed (below):

```bash
rm -rf "$ESP/EFI/debian"
bootctl install --no-variables       # keeps systemd-boot as the removable-media fallback EFI/BOOT/BOOTX64.EFI
install -d "$ESP/EFI/shim"
```

Option 2, Debian's systemd-boot package does it. With signed GRUB gone and signed shim present, it installs shim and MokManager in `EFI/debian/` and creates a "Debian" boot entry:

```bash
dpkg-reconfigure systemd-boot
```

Option 1 keeps shim out of `EFI/debian/` on purpose. Without `shim-signed`, the systemd-boot package deletes `EFI/debian/shim*` whenever the shim packages change.

Drop the Type #1 entries the systemd-boot package created:

```bash
TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id)
rm -rf "${ESP:?}/$TOKEN" "$ESP"/loader/entries/"$TOKEN"-*.conf
```

Lock the boot menu, `$ESP/loader/loader.conf`:

```
timeout 3
editor no
```

`editor no` hides the command line editor. The real protection is systemd-stub: with Secure Boot on, it ignores any command line the boot loader passes to a UKI that has an embedded one (tested in section 16).

### Re-sign the boot files with your key

shim will soon distrust Debian's certificate (section 12), so every boot file shim loads (systemd-boot, MokManager, the fallback loader, all from Debian) must carry your signature instead of Debian's, and only yours: a file that still carries Debian's signature next to yours is refused. In option 1 the firmware also needs your signature on shim, and shim must be copied from `/usr/lib/shim` whenever the package updates it. `sbctl sign` adds a signature next to the existing one, so it does not fit here. A small script copies, strips and re-signs instead.

Which key signs what, `/etc/kernel/esp-signing.conf`:

```bash
# Option 1:
KEY=/var/lib/sbctl/keys/db/db.key
CERT=/var/lib/sbctl/keys/db/db.pem
COPY="/usr/lib/shim/shimx64.efi:/boot/efi/EFI/shim/shimx64.efi /usr/lib/shim/mmx64.efi:/boot/efi/EFI/shim/mmx64.efi"
FILES="/boot/efi/EFI/shim/shimx64.efi /boot/efi/EFI/shim/mmx64.efi /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI"
# Option 2 instead (shim keeps Microsoft's signature, so it is not in the list):
# KEY=/etc/kernel/secure-boot-private-key.pem
# CERT=/etc/kernel/secure-boot-certificate.pem
# COPY=""
# FILES="/boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/debian/mmx64.efi /boot/efi/EFI/debian/fbx64.efi /boot/efi/EFI/BOOT/mmx64.efi /boot/efi/EFI/BOOT/fbx64.efi"
```

The script, `/usr/local/sbin/resign-esp` (`chmod 0755`):

```sh
#!/bin/sh
# Copy updated shim files to the ESP (COPY), then leave every boot file in FILES with exactly one
# signature: yours. Runs after every apt operation.
set -eu
. /etc/kernel/esp-signing.conf
mkdir -p /var/lib/resign-esp
for pair in $COPY; do
  src=${pair%%:*} dst=${pair#*:} stamp=/var/lib/resign-esp/$(basename "${pair#*:}").sha256
  sum=$(sha256sum < "$src")
  if [ ! -f "$dst" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$sum" ]; then
    cp "$src" "$dst" && echo "$sum" > "$stamp" && echo "resign-esp: copied $src"
  fi
done
for f in $FILES; do
  [ -f "$f" ] || continue
  n=$(sbverify --list "$f" 2>/dev/null | grep -c '^signature [0-9]') || true
  if [ "$n" = 1 ] && sbverify --cert "$CERT" "$f" >/dev/null 2>&1; then continue; fi
  while sbattach --remove "$f" >/dev/null 2>&1; do :; done
  sbsign --key "$KEY" --cert "$CERT" --output "$f" "$f" >/dev/null 2>&1
  echo "resign-esp: signed $f"
done
```

Run it after every package operation, `/etc/apt/apt.conf.d/99-resign-esp`:

```
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/resign-esp ]; then /usr/local/sbin/resign-esp; fi"; };
```

Then run it once by hand:

```bash
/usr/local/sbin/resign-esp
```

Package updates of shim or systemd-boot change the boot files: option 2's packages put Debian-signed copies back on the ESP, and in option 1 a new shim lands in `/usr/lib/shim`. In the test VM, reinstalling those packages did exactly that, and the hook copied and re-signed every file before the next boot.

Option 1 only, the boot entry: the firmware starts your shim, and shim starts systemd-boot. This is the same form Debian's own script uses for option 2:

```bash
part=$(findmnt -nvo SOURCE "$ESP"); disk=/dev/$(lsblk -no PKNAME "$part"); num=$(cat /sys/class/block/${part##*/}/partition)
efibootmgr --create --disk "$disk" --part "$num" --loader '\EFI\shim\shimx64.efi' \
  --label 'Debian (own shim)' --unicode '\EFI\systemd\systemd-bootx64.efi \0'
```

`efibootmgr` puts the new entry first. The "Linux Boot Manager" entry points at systemd-boot directly, without shim, so DKMS modules would not load on that path. Delete it with `efibootmgr -b XXXX -B`, where XXXX is its number, or leave it as a later fallback.

Check:

```bash
efibootmgr | grep -E 'BootOrder|Debian'     # "Debian (own shim)" (option 1) or "Debian" (option 2) first
bootctl list
ukify inspect "$ESP"/EFI/Linux/*.efi | grep -A3 -E '^\.(cmdline|pcrsig)'
for f in $(. /etc/kernel/esp-signing.conf; echo $FILES); do [ -f "$f" ] && sbverify --list "$f" | grep subject; done
```

### Reboot

Option 1: reboot straight into the firmware setup, clear the Secure Boot keys (or choose "Setup Mode"), and boot Debian from there:

```bash
systemctl reboot --firmware-setup
```

A normal reboot fails at this point in option 1: the firmware still has Microsoft's keys and does not accept your shim. If that happens, enter the firmware setup and clear the keys.

Option 2: a normal reboot.

Both: you get a passphrase prompt (no TPM yet).

## 11. Check the measurements (optional)

```bash
bootctl status | grep -E 'Product|Secure Boot|Measured UKI'
systemd-analyze pcrs
```

Expect `Measured UKI: yes` and PCR 8 all zeros.

## 12. Enroll your keys and distrust Debian

### Option 1: enroll your Secure Boot keys and the DKMS key

The machine is in Setup Mode now (end of section 10):

```bash
sbctl status                       # Setup Mode: Enabled
sbctl enroll-keys --tpm-eventlog   # your PK/KEK/db plus option ROM hashes from the event log
sbctl status                       # Setup Mode: Disabled
```

Reboot. Some firmware turns Secure Boot on as soon as a PK is enrolled (OVMF does), others need it switched on in setup. Then:

```bash
mokutil --sb-state            # SecureBoot enabled
```

Enroll the DKMS key as a MOK, then reboot and confirm it in MokManager (section 6):

```bash
dkms generate_mok
mokutil --import /var/lib/dkms/mok.pub
```

After the reboot:

```bash
mokutil --list-enrolled | grep 'Subject: CN'     # must list "DKMS module signing key"
```

### Both options: deny Debian's certificate in shim

Why: section 2. Do this only after section 10's script has re-signed systemd-boot and MokManager, and after a successful boot through them. Otherwise shim refuses its own next stage and the machine stops at the firmware.

Check that every boot file shim needs is signed by you, then take Debian's certificate from shim's own list and deny it:

```bash
. /etc/kernel/esp-signing.conf
for f in $FILES; do [ -f "$f" ] && sbverify --cert "$CERT" "$f"; done     # all "Signature verification OK"
D=$(mktemp -d); (cd "$D" && mokutil --export)
for f in "$D"/MOK-*.der; do
  openssl x509 -inform der -in "$f" -noout -subject | grep -q 'CN *= *Debian Secure Boot CA' && cp "$f" /etc/kernel/debian-secure-boot-ca.der
done
openssl x509 -inform der -in /etc/kernel/debian-secure-boot-ca.der -noout -subject
mokutil --mokx --import /etc/kernel/debian-secure-boot-ca.der    # asks for a one-time password
```

Reboot and confirm it in MokManager: "Enroll MOKX", then the same steps as in section 6. After the reboot:

```bash
mokutil --mokx --list-enrolled | grep 'Subject: CN'     # Debian Secure Boot CA
```

From now on, if the machine ever shows "Verification failed: Security Policy Violation" followed by MokManager offering to enroll a hash, do not enroll anything. It means a file on the ESP is not yours.

Someone at the keyboard can still enroll a MOK of their own in MokManager. That does not change any locked PCR, so the disk keeps opening automatically, and it does not get them the key: anything their MOK approves adds an entry to PCR 7, and the TPM refuses (tested in section 16). It does let their code run on your machine, so check the list now and then:

```bash
mokutil --list-enrolled | grep 'Subject: CN'      # only Debian's CA (shim's own), your keys, the DKMS key
```

## 13. Seal the disk key to the TPM

Why pcrlock plus a signed PCR 11 instead of fixed PCR values: section 2.

Record the components pcrlock should lock:

```bash
DEV=/dev/nvme0n1p2
PCRLOCK=/usr/lib/systemd/systemd-pcrlock     # not in $PATH on Debian
$PCRLOCK lock-firmware-code                  # PCR 0, 2
$PCRLOCK lock-firmware-config                # PCR 1, 3
$PCRLOCK lock-secureboot-policy              # PCR 7: SecureBoot, PK, KEK, db, dbx
$PCRLOCK lock-secureboot-authority           # PCR 7: which certificates approved each step
$PCRLOCK lock-gpt                            # PCR 5 (dropped later, see below)
```

### Check which PCRs this host supports

`predict` is a dry run of `make-policy`: it reads the TPM event log, matches every event against the components recorded above, and says which PCRs it could lock. It writes nothing.

```bash
$PCRLOCK predict 2>&1 | grep -E '^PCR|protection mask'
```

Output from the test VM:

```
PCR 7 (secure-boot-policy) matches event log and fully consists of recognized measurements. Including in set of PCRs.
PCR 14 (shim-policy) event log contains unrecognized measurements. Removing from set of PCRs.
...
PCRs in protection mask: 0 (platform-code), 1 (platform-config), 2 (external-code), 3 (external-config), 7 (secure-boot-policy), 12 (kernel-config), 13 (sysexts)
```

The protection mask is the most this host supports. PCRs 4, 5, 11, 14 and 15 are always dropped on this setup, and PCR 12 must be left out by you (see below). To see why a PCR was dropped, look for its events with `-` in the COMPONENT column:

```bash
$PCRLOCK log
```

If PCR 7 is dropped, stop here. Some vendors measure extra Secure Boot events that pcrlock does not recognize. Find out which event it is before going further. With shim in the chain, pcrlock recognized shim's PCR 7 events (SBAT level, MOK list, `db`) in both options.

Then check the candidates stay the same across a plain reboot. Some firmware measures data that changes on every boot (counters, timestamps), and a PCR like that never matches a policy:

```bash
systemd-analyze pcrs 0 1 2 3 7 > /root/pcrs.before
systemctl reboot
# after the reboot (passphrase prompt):
systemd-analyze pcrs 0 1 2 3 7 | diff /root/pcrs.before - && echo stable
```

Drop any PCR that shows up in the diff. In the VM, all five were stable.

Your set is what remains, minus what the table in section 3 tells you to leave out, and it must still contain 7.

### Make the policy

Make the policy with the PCRs you chose and a recovery PIN you will remember. If you rebooted for the stability check, set `DEV` and `PCRLOCK` again first (top of this section):

```bash
PCRS=0,1,2,3,7,13          # your choice from section 3; must contain 7
echo "PCRS=$PCRS" > /etc/kernel/pcrlock-pcrs     # so section 15 reuses the same list
$PCRLOCK make-policy --pcr=$PCRS --recovery-pin=query 2>&1 | tee /tmp/make-policy.out
grep 'PCRs in protection mask:.*\b7 (secure-boot-policy)' /tmp/make-policy.out || echo "STOP: PCR 7 not locked"
```

Keep PCR 12 out of the list. `make-policy` stores its policy as a credential in `$ESP/loader/credentials/`, systemd-stub measures that credential into PCR 12, and a policy that locks PCR 12 to its old value never matches again.

Write the recovery PIN down. It is the only way to update the policy once the machine has drifted away from it (section 15). With the default, `--recovery-pin=hide`, a random PIN is generated and never shown, and the only way out is to remove the policy and enroll the disk again.

Enroll the LUKS volume:

```bash
systemd-cryptenroll --wipe-slot=tpm2 \
  --tpm2-device=auto \
  --tpm2-pcrlock=/var/lib/systemd/pcrlock.json \
  --tpm2-public-key=/etc/systemd/tpm2-pcr-public-key.pem \
  --tpm2-public-key-pcrs=11 \
  --tpm2-pcrs= \
  $DEV
systemd-cryptenroll $DEV          # lists: password + tpm2
```

`--tpm2-pcrs=` (empty) means no literal PCR binding. pcrlock and the signature cover everything, and pcrlock's NV index can be updated later without touching the LUKS header.

Reboot. The disk opens with no prompt. The journal may show `Esys_Unseal ... ErrorCode (0x00000128)` first. That is TPM_RC_PCR_CHANGED (another service extended a PCR mid-check), and systemd retries:

```bash
journalctl -b -u 'systemd-cryptsetup@*'
```

## 14. Kernel and module updates

Nothing to do. On `apt upgrade`, the kernel package runs `/etc/kernel/postinst.d/zz-systemd-boot`, which calls `kernel-install`, which runs dracut and ukify. ukify signs the UKI with your key and signs its PCR 11 value with your PCR key. Tested in the VM with both options: an upgrade from 6.12 to the 7.2 backports kernel booted and decrypted without resealing.

DKMS rebuilds its modules for the new kernel and signs them with `/var/lib/dkms/mok.key`. Because that key is a MOK, they load. In the VM, a module signed that way loaded with Secure Boot on and kernel lockdown active, in both options.

Updates to shim or systemd-boot change the boot files. The apt hook from section 10 copies (option 1) and re-signs them before you can reboot.

Old UKIs are removed when their kernel package is removed.

Updates to dracut and to microcode packages also rebuild and re-sign the UKIs (through dracut's `update-initramfs` trigger). An update to systemd-stub alone (package `systemd-boot-efi`) does not. The new stub reaches the boot path with the next kernel update, or right away with:

```bash
for k in /boot/vmlinuz-*; do kernel-install add "${k#/boot/vmlinuz-}" "$k"; done
```

`kernel-install add-all` does not work for this on Debian: it looks for kernels under `/usr/lib/modules/*/vmlinuz`, where Debian does not put them.

## 15. Firmware updates, BIOS changes and shim updates

Anything that changes a locked PCR makes the next boot ask for the passphrase: a firmware update, a BIOS setting, the boot order, Secure Boot `db`/`dbx` updates. A shim update that raises its SBAT level changes PCR 7 as well (expected from how shim measures, not tested). To re-lock:

1. Boot with the passphrase.
2. Re-record what changed, for example:

   ```bash
   PCRLOCK=/usr/lib/systemd/systemd-pcrlock
   . /etc/kernel/pcrlock-pcrs             # PCRS from section 13
   $PCRLOCK lock-firmware-code            # after a firmware update
   $PCRLOCK lock-firmware-config          # after a settings or boot order change
   $PCRLOCK lock-secureboot-policy        # after a db/dbx update
   $PCRLOCK lock-secureboot-authority     # after a shim update
   ```

3. Update the policy. It asks for the recovery PIN, because the current state no longer satisfies the old policy:

   ```bash
   $PCRLOCK make-policy --pcr=$PCRS --recovery-pin=query
   ```

No `systemd-cryptenroll` needed: the LUKS token points to the same NV index. Tested in the VM by changing the boot order, and by the PCR 7 change that denying Debian's certificate causes.

If you run `make-policy` without `--recovery-pin=query` in this situation, it fails with `Failed to add OR policy to TPM: tpm:parameter(1):value is out of range` (TPM_RC 0x1c4). That error means "the current PCRs match none of the predicted values".

After a `shim-signed` update, check that the certificate built into the new shim is still the one you denied. If Debian ever ships a shim with a new certificate, deny that one too, the same way as in section 12. Not tested, since no such shim exists yet:

```bash
D=$(mktemp -d); (cd "$D" && mokutil --export)
for f in "$D"/MOK-*.der; do openssl x509 -inform der -in "$f" -noout -subject -fingerprint -sha256; done
openssl x509 -inform der -in /etc/kernel/debian-secure-boot-ca.der -noout -fingerprint -sha256
```

## 16. Verify the protections

Results from the test VM. `testbench/run-all.sh` runs the rows marked "run-all" for one option from a factory-state VM. "Earlier chain" rows were run on the same option before Debian's certificate was denied. "No shim" is the stricter variant from section 2, tested before shim was added. Rows only run there test pcrlock and package behaviour that does not depend on shim.

| Test | Expected | Option 1 | Option 2 | No shim |
|---|---|---|---|---|
| Normal reboot (run-all) | No prompt | Pass | Pass | Pass |
| Kernel upgrade, 6.12 to 7.2 backports (run-all) | No prompt, no reseal | Pass | Pass | Pass |
| DKMS-signed module, Secure Boot on (run-all) | Loads | Pass | Pass | Rejected: `Key was rejected by service` |
| Extra boot entry passing `init=/bin/sh` to the signed UKI (run-all) | Option ignored, no prompt | Pass | Pass | Pass |
| Debian-signed kernel + stock initrd from the ESP, PCR 7 and 11 replayed from software (run-all) | Kernel refused | Pass | Pass | Pass: firmware refuses the kernel |
| Same, before Debian's certificate was denied | Kernel refused | Fails: key released | Fails: key released | |
| Attacker enrolls their own MOK at the console, signs the Debian kernel with it, replays PCR 7 and 11 | TPM refuses | Pass: the new MOK's approval adds a PCR 7 entry that cannot be undone | | |
| TPM-sealed credential `systemd.extra-unit.*` planted in `ESP/loader/credentials/` | Ignored | Pass: systemd marks ESP credentials untrusted and does not apply them | | |
| Reinstall of the shim and systemd-boot packages (run-all) | Hook copies and re-signs, no prompt | Pass | Pass | systemd-boot only: Pass |
| Unsigned (modified) UKI made the next boot | Refused | Pass: shim, `Security Policy Violation` (earlier chain) | Pass: shim, `Security Policy Violation` (earlier chain) | Pass: firmware, `Access denied` |
| Secure Boot keys cleared in firmware | Passphrase prompt | Pass (earlier chain) | Pass (earlier chain) | Pass |
| Forced initrd failure (LUKS header UUID changed, no key needed) to reach a shell while PCRs still match | No shell | | | Pass: dracut's emergency mode refuses, the root account is locked in the initrd |
| Same, with `rd.shell=0 rd.emergency=halt` in the UKI command line | Halts | | | Pass: "Could not boot. Halting."; normal boots still open automatically |
| Boot order changed (PCR 1) | Passphrase prompt, re-lock with PIN restores automatic decryption | | | Pass |
| Running system asks the TPM for the key with the UKI's signature | Refused: no signature for the post-initrd PCR 11 | | | Pass |
| Policy without PCR 7 (13, 14 only), Secure Boot keys cleared | Should prompt | | | Fails: key released. This is why PCR 7 is required |
| Policy with PCR 7 only, Secure Boot keys cleared | Passphrase prompt | | | Pass |
| Old kernel package purged | Its UKI removed from the ESP | | | Pass |
| Recovery key enrolled next to the TPM slot | Still no prompt | | | Pass |
| `apt install intel-microcode amd64-microcode` with the `initramfs-tools` pin | dracut kept, UKI rebuilt, no prompt | | | Pass |
| Same without the pin | | | | Fails: dracut removed, boot stops in BusyBox |

On your own machine you can repeat the unsigned-UKI and cmdline tests safely: keep the passphrase handy, and delete the extra file from the ESP afterwards.

## 17. Backups and disaster recovery

If the motherboard or TPM is replaced or cleared, the TPM slot is useless and you use the passphrase. MOKs and the MokListX entry live in firmware storage too. On a new motherboard, redo section 12 (and in option 2 the MOK enrollment from section 6), then section 13. Back up:

```bash
DEV=/dev/nvme0n1p2
install -d -m 0700 /root/recovery-backup
cryptsetup luksHeaderBackup $DEV --header-backup-file /root/recovery-backup/luks-header.img
cp -a /etc/systemd/tpm2-pcr-private-key.pem /etc/systemd/tpm2-pcr-public-key.pem /etc/kernel/pcrlock-pcrs /root/recovery-backup/
cp -a /var/lib/dkms/mok.key /var/lib/dkms/mok.pub /etc/kernel/esp-signing.conf /etc/kernel/debian-secure-boot-ca.der /root/recovery-backup/
if [ -d /var/lib/sbctl ]; then                      # option 1
  cp -a /var/lib/sbctl /root/recovery-backup/sbctl
else                                                # option 2
  cp -a /etc/kernel/secure-boot-private-key.pem /etc/kernel/secure-boot-certificate.* /root/recovery-backup/
fi
tar -C /root/recovery-backup -cf - . | gpg --symmetric --cipher-algo AES256 -o /root/recovery-backup.tar.gpg
rm -rf /root/recovery-backup
```

Move `/root/recovery-backup.tar.gpg` to offline storage and delete the local copy. The archive holds your signing keys: anyone who has them can sign a kernel or a module your machine will trust.

A LUKS recovery key is a good second fallback next to your passphrase:

```bash
systemd-cryptenroll --recovery-key $DEV
```

## 18. Changes from the previous version of this guide

Found by running the old guide's steps in the VM:

- sbctl is not in any Debian release. It now gets built from the signed upstream tarball. Its keys live in `/var/lib/sbctl/keys`, not `/usr/share/secureboot/keys`.
- The custom `update-uki.sh` and postinst hook are gone. They built the initramfs for the running kernel instead of the new one (`dracut --force` with no version), and overwrote a single `linux-signed.efi`, leaving no fallback. Debian's own `kernel-install` with `layout=uki` does the job, one UKI per kernel.
- `[Sign]` is not a ukify section, and `PCRBanks=` is not valid under `[PCRSignature:...]` (ukify prints "Unknown config setting"). The keys moved to `SecureBootPrivateKey=` and `SecureBootCertificate=` under `[UKI]`.
- dracut needs the `systemd-pcrphase` module, or the PCR 11 signature never matches.
- The PCR signature is now limited to `Phases=enter-initrd`. The default signs all phases, so the booted system could unseal the key.
- PCR 8 binding is removed. With systemd-boot and a UKI, PCR 8 is always zero. Command line protection comes from the signed UKI and systemd-stub, verified by test.
- The pcrlock PCR set is a per-host choice kept in one place (`/etc/kernel/pcrlock-pcrs`), with PCR 7 required. Without PCR 7 the VM released the key with Secure Boot off.
- `make-policy` now gets an explicit PCR list without PCR 12, and a recovery PIN. With the defaults, the first reboot failed (PCR 12 changed) and the policy could not be repaired without re-enrolling.
- Debian's shim stays in the boot chain, set up by the systemd-boot package itself, so MOK and DKMS modules work. Without shim, DKMS modules were rejected.
- shim distrusts Debian's certificate (MokListX), and systemd-boot and MokManager carry your signature instead. Without that, a Debian kernel with an attacker's initrd got the disk key from the TPM in the VM.
- Option 1 uses `shim-unsigned`, signed by you, in its own ESP directory. `shim-signed` refuses to install or upgrade when Microsoft is not in `db`, which broke apt in the VM.
- Two Secure Boot options instead of one: your own keys (default) or the factory Microsoft keys with your key as a MOK. Option 2 enrolls its key before the boot packages are installed, and option 1 reboots straight into Setup Mode, because both were unbootable in the VM otherwise.
- GRUB and `initramfs-tools` are pinned away. Installing a microcode package otherwise swaps dracut out and makes the machine unbootable.
- An apt hook re-signs the boot files after package updates, leaving exactly one signature, yours.
- `systemd-pcrlock` lives in `/usr/lib/systemd/`, not in `$PATH`.
- The PCR signing key moved to systemd's conventional `/etc/systemd/tpm2-pcr-private-key.pem` and `/etc/systemd/tpm2-pcr-public-key.pem`.
- The 0x1c4 error is not a "branch limit". It means the current PCR values match none of the policy's predicted values.
