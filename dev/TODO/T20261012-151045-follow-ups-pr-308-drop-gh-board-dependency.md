---
status: Open
estimation: 1
source: PR #308 (merge commit 7e29dff) follow-ups, this conversation, 2026-10-12
related: T20261005-554581
---

# T20261012-151045: follow-ups from [PR #308](https://github.com/Synx-Data-Labs/ccxp-skills/pull/308) (drop gh board dependency)

## Problem

- **Type**: chore
- [PR #308](https://github.com/Synx-Data-Labs/ccxp-skills/pull/308) (https://github.com/Synx-Data-Labs/ccxp-skills/pull/308, merge 7e29dff) dropped the GitHub Project board from the IPM drain gate. Four loose ends; each re-checked against `main` at 004550a.
- **(a) Drain-check input handling** (verified by reading the code):
  - A malformed `--today` is not validated: `_ipm_drain_monday_of` (`_ipm/ipm-iteration-drain-check.sh:77-85`) feeds it to `date.fromisoformat`, which raises, so the script exits 1 instead of the usage-error code 2 used for bad args (`:117-119`, `:134`).
  - `_ipm_drain_fm_get` (`:99-108`) matches `$0=="---"` and `^field:` literally, so CRLF task files have no frontmatter and a field value keeps a trailing `\r`.
  - Done: bad `--today`/`--prev-start` exits 2 with a message; a CRLF task file is read like an LF one; bats cases for both in `tests/ipm_iteration_drain_check.bats`.
- **(b) "No GitHub Project board anywhere" overclaims**:
  - Claims: `lifecycle.md:119`, `_session/task_claim.sh:23` ("anywhere in this suite"); softer: `lifecycle.md:111`, `todo/SKILL.md:60`, `ipm/SKILL.md:46`.
  - Still present: `_session/status.sh:2,8` (Project Status mirror), `_session/README.md:5,13,15,93`, `README.md:63-69` (`PROJECT_OWNER`/`PROJECT_NUMBER`/`PROJECT_PAT`) and `README.md:304`.
  - Done: reword the claims to "the iteration/IPM flow has no board dependency; the optional `_session/` mirror remains" (or retire the mirror in a separate task); no doc contradicts another.
- **(c) Stale hour-budget wording**: `glossary.md:20` still says IPM "budgets focused-work hours", but [PR #308](https://github.com/Synx-Data-Labs/ccxp-skills/pull/308) dropped the hour budget. Done: reword to queue-order picks, no hours.
- **(d) Stale `epic-status.sh` header comments**: reported by the [PR #308](https://github.com/Synx-Data-Labs/ccxp-skills/pull/308) job but NOT located on current main; the header (`ccxp/scripts/epic-status.sh:12-20`) and `:148`, `:215` read accurately for the local-only design. Dropped unless a concrete stale line is found; done: either cite it or close this item with no change.
