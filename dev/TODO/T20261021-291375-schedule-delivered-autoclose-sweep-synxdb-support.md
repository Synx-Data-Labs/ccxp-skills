---
status: Open
scheduled: 2026-11-02
estimation: 2
source: follow-up of T20261021-266225 (design decision: no cron in the skill PR)
related: T20261021-266225
---

# T20261021-291375: Schedule the customer-support delivered-autoclose sweep (cron) for synxdb-support

## Problem

- **Type**: feature
- `customer-support/scripts/sweep.sh` (T20261021-266225) closes `delivered` issues idle for 14 days, but nothing runs it; it is dry-run by default.
- Decide and implement scheduling: a daily workflow in `Synx-Data-Labs/synxdb-support` that checks out ccxp-skills and runs `sweep.sh Synx-Data-Labs/synxdb-support --apply`.
- Needs a token with issue write access to synxdb-support (secret setup is a human step) and the support team's go-ahead after reviewing a dry-run list.
- First eligible issues (all delivered 2026-10-21): #30, #31, #32 become closable on 2026-11-04.
- Done: workflow merged, one observed scheduled dry-run, then `--apply` enabled by the maintainer.
