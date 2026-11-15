# luks-tpm2-uki

An agent skill for automatic LUKS2 disk decryption from a TPM2, without a PIN, on a boot chain you control: Secure Boot, a signed Unified Kernel Image, systemd-boot, `systemd-pcrlock` and a signed PCR 11 policy. Tested on Debian 13 and Proxmox VE 9; usable as a base for other distributions.

With it, an agent can set up a machine from scratch, audit an existing setup read-only, and write a fix script for you to run. It picks the PCRs with you: if you change BIOS settings or plug docks, those changes should not cost you a passphrase prompt, and the skill measures which PCRs they move on your machine.

## Install

```bash
git clone https://github.com/luminoso/luks-tpm2-uki-skill
cp -r luks-tpm2-uki-skill/skills/luks-tpm2-uki ~/.claude/skills/
```

Other agents that read the [Agent Skills](https://agentskills.io) format: copy the same folder into their skills directory.

Then ask, for example: "audit my TPM disk decryption setup" or "make this Debian machine decrypt its disk from the TPM with a signed UKI".

## Safety

The agent audits first, read-only, and hands you every root command. Changes come as a script with checks and backups. Keep your LUKS passphrase at hand: mistakes here end at a passphrase prompt, or at a machine that only boots with Secure Boot turned off.

## Evidence

Every step ran in a QEMU/OVMF/swtpm VM (`testbench/`), end to end from a new PC's factory state, for both Secure Boot options: kernel upgrades without resealing, DKMS modules, package updates, and attacks (tampered UKI, injected command line, a Debian kernel with an attacker's initrd replaying PCRs, a forced initrd failure). The audit checks come from a real host.

Benchmark (`evals/`): two scenarios, scored by hand, with and without the skill.

| Model | Setup plan (15) | Audit (9) |
|---|---|---|
| Opus 5.5 | 12 → 15 | 8 → 9 |
| Sonnet 5.5 | 8 → 15 | 7 → 9 |
| Haiku 5.5 | 7 → 15 | 6 → 9 |

Without the skill, models missed the initramfs-tools pin, the Debian-certificate attack, the PCR stability check and the boot-phase limit, and some suggested locking PCR 4 or PCR 12. Details in `evals/results/`.

## Layout

```
skills/luks-tpm2-uki/   SKILL.md, references/ (setup guide, PCR selection, audit, other distros, lessons), scripts/ (audit, re-sign hook, db tool)
testbench/              VM harness that replays the guide
evals/                  scenarios, rubric, results
```

Not tested: real laptops, GPU option ROMs, a real firmware update, distributions other than Debian and Proxmox.
