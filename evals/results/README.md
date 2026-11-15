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
- With it, every run picked shim + MOK for NVIDIA on a Debian kernel, used `Phases=enter-initrd`, `systemd-pcrphase`, `--recovery-pin=query`, the re-sign hook, and kept PCR 7.

Haiku's first run with the skill missed the emergency-shell item; the guide then got a tested `rd.shell=0 rd.emergency=halt` step and the re-run scored 15. Opus and Haiku audit runs used the skill before that change; Sonnet runs and the Haiku re-run used the current version.

Sample size is one run per cell. Treat the numbers as a smoke test, not a statistic.
