# Evaluation rubric

Two scenarios, run with and without the skill, on a strong and a weak model. Each answer is scored by hand against the items below: 1 point per item the answer gets right, 0 if missing or wrong. False claims are counted separately.

The prompts are in `scenarios.md`. The ground truth comes from the VM test bench (`testbench/`) and from a real host audit.

## Scenario A: setup plan (Debian 13, NVIDIA via DKMS, own keys, changes BIOS settings)

| # | Item | Why it is ground truth |
|---|---|---|
| A1 | Keeps PCR 7 in the policy | Without PCR 7 the VM released the key with Secure Boot off |
| A2 | Does not bind PCR 8, or says it is useless here | Always zero with systemd-boot + UKI |
| A3 | Does not lock PCR 12 with pcrlock | pcrlock's own ESP credential is measured into PCR 12; first reboot failed |
| A4 | Uses a signed PCR 11 policy (`--tpm2-public-key`) so kernel updates need no reseal | Tested across a 6.12 to 7.2 upgrade |
| A5 | Limits the PCR signature to `Phases=enter-initrd` | Default signs all phases; the booted system could unseal |
| A6 | Uses a systemd-based initrd (dracut) with `systemd-pcrphase` | initramfs-tools has no systemd; signed policy never matches without pcrphase |
| A7 | Recognizes that DKMS modules need MOK, so shim in the chain (on Debian kernels) | Module without MOK: `Key was rejected by service` |
| A8 | Handles shim trusting Debian's certificate (MokListX deny, or equivalent) | Debian kernel + attacker initrd replayed PCR 7/11 and got the key |
| A9 | Knows sbctl is not packaged in Debian, or uses packaged tools correctly | Not in trixie, backports or sid |
| A10 | Re-signs boot files after package updates (hook) | systemd-boot/shim updates copy unsigned or Debian-signed files to the ESP |
| A11 | Keeps initramfs-tools from replacing dracut (pin) | microcode Recommends pulled it in; boot stopped in BusyBox |
| A12 | Sets a known pcrlock recovery PIN (or equivalent recovery path) | Default `hide` PIN made the policy unrepairable without re-enrolling |
| A13 | Leaves PCR 1/3 out (or makes it the user's choice) given BIOS changes, and checks PCR stability across a reboot | User requirement; some firmware measures changing data |
| A14 | Keeps a passphrase or recovery key slot | Every TPM refusal falls back to it |
| A15 | Makes sure a forced initrd failure cannot give a shell while the PCRs still match (checks it, or adds `rd.shell=0 rd.emergency=halt`) | Debian's dracut initrd refused (root locked); the initramfs-tools initrd gave a passwordless BusyBox shell |

## Scenario B: audit of a real host (facts given as text)

| # | Item | Severity |
|---|---|---|
| B1 | Next systemd-boot package update puts a Debian-signed loader on the ESP (hand-replaced `.signed`, no re-sign hook) and the firmware refuses it | High |
| B2 | No `EFI/BOOT/BOOTX64.EFI` fallback; boot depends on one NVRAM entry | High/Medium |
| B3 | PK and KEK private keys stored on the host | Medium |
| B4 | DKMS certificate in firmware `db`: firmware runs EFI binaries signed with it | Medium |
| B5 | Nothing stops initramfs-tools from replacing dracut | Medium |
| B6 | GRUB still installed, recommended by new kernels, grub-pc in a failed state | Low |
| B7 | crypttab typo `tpm-device=` | Low |
| B8 | Stale `LoaderEntryDefault` pointing at a removed UKI | Low |
| B9 | Says to check that a forced initrd failure cannot give a shell while the PCRs still match | Check |

False claims to count (each one is a point against): saying TPM decryption is not working, saying `systemd-pcrphase` is missing from the initrd, saying there is no passphrase slot, saying PCR 7 is missing from the policy, recommending binding PCR 8 or locking PCR 12.
