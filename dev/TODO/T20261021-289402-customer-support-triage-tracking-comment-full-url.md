---
status: Open
estimation: 1
source: user request in this conversation, 2026-10-21
related: T20261019-181127
---

# T20261021-289402: customer-support triage: the tracking comment must carry a full clickable URL to the task file

## Problem

- **Type**: bug
- `/customer-support triage <issue> --task <repo>#T<id>` posts `Tracked internally as <owner>/<repo>#T<id>` (`customer-support/scripts/transition.sh:71`); `<repo>#T<id>` is not a GitHub autolink (only `owner/repo#<number>`), so the comment is not clickable and the reader cannot reach the task.
- Seen on synxdb-support #14, #29, #33, #34 (e.g. issues/34#issuecomment-6324361754, issues/33#issuecomment-6323908498).
- Fix: resolve the task file at triage time via the GitHub contents API (`dev/TODO/<id>-*.md` on the default branch); if only on an open PR, link that PR and say so; if moved to `dev/JOURNAL/`, link the journal file; if missing, fail loudly (no broken link).
- Link rot: decide the robust form (e.g. SHA-pinned permalink, or live path plus pinned permalink) in the design PR.
- Keep `Tracked internally as <repo>#T<id> — <title>` text, add a markdown link on the id plus the bare URL; keep `--task` backward compatible and the idempotency marker; no secrets.
- Update every doc/skill that documents the comment (`git grep 'Tracked internally as'`, `customer-support/SKILL.md`, `/to-task`) and BATS tests (fakes only): main, open PR, JOURNAL, missing, private repo (gh api auth). Label names from `customer-support/scripts/label_names.sh`.
- Follow-up (report only): list existing tracking comments on synxdb-support lacking `https://`; do not edit them.
