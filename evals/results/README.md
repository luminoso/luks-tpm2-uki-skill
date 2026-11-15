# Results

Scored by hand against `../rubric.md`. A = setup plan (15 items), B = audit of a real host (9 items). "Without" = no skill, "with" = the skill in the agent's context.

| Model | A without | A with | B without | B with |
|---|---|---|---|---|
| Opus 5.5 | 12 | 15 | 8 | 9 |
| Sonnet 5.5 | 8 | 15 | 7 (+1 false claim) | 9 |
| Haiku 5.5 | 7 | 14, then 15 | 6 | 9 |

What the skill fixed, across models:

- Without it, every model missed pinning out initramfs-tools. Haiku and Sonnet also suggested locking PCR 4 or PCR 12, and two proposed `apt install sbctl` (not packaged in Debian).
- Without it, no setup plan denied Debian's certificate in shim, and none checked PCR stability across a reboot. Two assumed Debian kernels accept DKMS modules signed only by a `db` key.
- With it, every run used `Phases=enter-initrd`, `systemd-pcrphase`, `--recovery-pin=query`, the re-sign hook, and kept PCR 7. Those runs also picked shim + MOK for NVIDIA, which the skill then recommended; a later VM test showed Debian's kernel accepts modules signed with the `db` key, so shim is not needed (rubric A7 and A8 were updated, see below).

Haiku's first run with the skill missed the emergency-shell item; the guide then got a tested `rd.shell=0 rd.emergency=halt` step and the re-run scored 15. Opus and Haiku audit runs used the skill before that change; Sonnet runs and the Haiku re-run used the current version.

## Second round (after the no-shim default, the operations scripts and the DKMS correction)

Haiku and Sonnet only, with the skill, plus the new scenario C (server without DKMS: BIOS update without a prompt, alerting, kernel fallback; 12 items) with and without it.

| Model | A with (15) | B with (9) | C without (12) | C with (12) |
|---|---|---|---|---|
| Sonnet 5.5 | 15 | 9 | 6 | 12 |
| Haiku 5.5 | 15 | 9 | 5 | 12 |

- A: both picked option 1 without shim and had DKMS sign NVIDIA with the `db` key, checked with `modinfo -F signer` and `modprobe`. Both warned against `systemd-pcrlock remove-policy`.
- C without the skill: both left shim out and used boot counting and a recovery key, but neither limited the PCR signature to `Phases=enter-initrd`, added `systemd-pcrphase`, pinned `initramfs-tools`, or planned the firmware update; both used `sbctl sign-all` style hooks that sign whatever is on the ESP. Sonnet added an external heartbeat, which the skill does not cover and which catches a machine stuck at the prompt.
- C with the skill: `pcrlock-update open 0,1,2,3` for the BIOS update, `check-next-boot`, `tpm-unlock-check`, `/etc/kernel/tries`, recovery key kept off the host. Both also noted that `tpm-unlock-check` cannot report a machine still waiting at the prompt.

Sample size is one run per cell. Treat the numbers as a smoke test, not a statistic.
