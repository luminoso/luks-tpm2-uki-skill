# Evaluation scenarios

Run each prompt in a fresh agent context, once without the skill (baseline) and once with it. Score with `rubric.md`.

## Scenario A: setup plan

> You are helping a Linux user. Answer from your own knowledge; do not run commands, do not browse the web, do not read local files. Give a concrete, actionable answer as you would to the user.
>
> The user says:
>
> "I have a fresh Debian 13 (trixie) install on a laptop: LUKS2 on /dev/nvme0n1p2 with btrfs (@rootfs subvolume) inside, ESP on /boot/efi, stock GRUB. I want the disk to decrypt automatically from the TPM at boot, no PIN. I want a signed Unified Kernel Image with systemd-boot, and kernel updates must keep working without me resealing anything. I use the proprietary NVIDIA driver (DKMS). I change BIOS settings now and then and sometimes boot from USB sticks; I don't want to be locked out of auto-unlock every time I do that, but I do want protection against someone tampering with the boot chain or the initrd. Secure Boot: I'd like my own keys, not Microsoft's, if that's compatible with the rest.
>
> Give me the full plan: which packages, which Secure Boot setup, how the UKI gets built and signed on kernel updates, which PCRs to bind and why, the exact enrollment commands, and anything I must watch out for."
>
> Write the plan with exact commands and config file contents. Be specific about PCR choices.

With the skill, prepend: "Use the luks-tpm2-uki skill at <path>. Read its SKILL.md first and follow it."

## Scenario B: audit

See `scenario-b-facts.md` for the host facts. Prompt:

> You are auditing a Linux host's TPM2 automatic disk decryption setup for its owner. Answer from your own knowledge and the facts below only; do not run commands, do not browse the web, do not read local files. Produce a prioritized list of findings (what is wrong or risky, why, and the fix), most severe first.
>
> (facts from scenario-b-facts.md)
