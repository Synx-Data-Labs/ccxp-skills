---
status: Open
estimation: 1w
source: Skill quality review, this conversation, 2026-09-28 (dev/quality/skill-review-2026-09-28/)
related: [T20260922-155006, T20260925-159860, T20260923-584914, T20260922-409644, T20260923-292618]
description: Fix the correctness bugs, script-path breakage and concision debt found by the 2026-09-28 review of all 47 skills
---

# T20260928-101526: Fix the 2026-09-28 skill-review findings (bugs → script paths → concision)

## Problem

- **Type**: bug
- The 2026-09-28 review ([README](../quality/skill-review-2026-09-28/README.md), per-skill detail in `batch1.md`–`batch5.md`) found real correctness and safety bugs. Severe ones were spot-checked by hand:
  - `cleanup-branch/scripts/cleanup-branch.sh:89-92` falls back to `git branch -D` for any branch with a merged PR, so it deletes local commits made after the merge.
  - `drive/SKILL.md:151` sets `trap 'rm -rf "$TARGET"' EXIT` inside one Bash tool call, which deletes the cross-repo clone when that call ends.
  - `migrate-task/SKILL.md:3` and `statusline-setup/SKILL.md:3` have invalid YAML frontmatter (an unquoted colon-space in the description), so their triggers may never load.
  - `slack/SKILL.md:64`: `SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_FOO"` expands to empty when the var lives only in `~/.claude/.env`, so the message goes to the default channel.
  - The rest are in the README's §1 table: `autopilot` re-dispatches `/address-pr` every 60 s on WAITING, `top --before` reverses blocker order, `incept` lints repo-wide, `gcpr` hardcodes the trailer, `rca` + `labrun-rca` double-post, `email-triage` claims to be read-only.
- Script paths only resolve from the ccxp-skills root. A live eval confirmed it: `bash todo/scripts/todo-next.sh` exits 127 from a consumer repo. `todo/evals/evals.json` case `next-skips-done-and-is-read-only` (`command_succeeded`) is red until this is fixed.
- Concision debt: `ccxp` (90 KB), `drive` (66 KB), `retro` (42 KB) and `address-pr` (33 KB) score 53–61. They lose points for size and for 173 task-ID changelog asides across skills. Several restate other skills' behavior and have drifted, e.g. `ccxp`/`drive` describe `/todo next` wrongly.
- Done looks like:
  - Every README §1 bug is fixed, each with a regression eval case or a BATS test.
  - `todo`'s eval suite passes.
  - No skill scores below 70.
  - The baseline in `dev/quality/skill-scores.json` is re-locked at the new scores.

## Solution

Work in the README §5 order. Split any phase into its own task if it outgrows this one; the queue-lib extraction and the Cloudflare family are the likeliest candidates.

1. **Bugs (README §1).** For each bug:
   - Add the failing eval case (`<skill>/evals/evals.json`, using the case suggested in `batchN.md`) or a BATS test for script bugs.
   - Fix the bug, and show the test going red → green.
   - Quote the two broken frontmatters first; it's a 5-minute job.
2. **One script-path convention.** Pick one base-dir rule, record it in `skill-conventions` §9, and apply it to every skill that calls `scripts/` or a `_lib`. Verify with `python3 skill-conventions/scripts/skill_eval.py todo --record`.
3. **Concision.**
   - Move changelog asides into JOURNAL.
   - Replace restated algorithms with "run X, then apply this judgment".
   - Replace paraphrases of other skills with phase-anchor citations.
   - Re-score after each skill.
4. **Shared helpers.** Extract `_queue/queue.sh` (used by stage/top/bottom/todo sweep/migrate.sh) and a shared land-as-PR helper, both with BATS tests.
5. **Cloudflare family.**
   - Turn `cloudflare` into a router with "not for X → use Y" lines.
   - Drop the duplicated `cloudflare/references/*` copies.
   - Decide between normalizing vendored skills and marking them `upstream:` with a scorer exemption.
6. **Company residue.** Remove `#acme-*`, `America/Chicago`, `synx-merge-bot`, `private-skills-repo/…`, `vpn/scripts/vpn.sh`, and the dead `dev/branch-merge-policy.md` references.

## Test plan

- [ ] `python3 skill-conventions/scripts/test_skill_quality.py` and `bats tests/*.bats` are green.
- [ ] Each README §1 bug has a named eval case or BATS test that failed before its fix and passes after.
- [ ] `python3 skill-conventions/scripts/skill_eval.py todo --record` passes (≥ 90%) from a consumer-repo fixture.
- [ ] `python3 skill-conventions/scripts/skill_score.py --check dev/quality/skill-scores.json` passes, and no skill scores below 70.

## Done criteria

- [ ] All README §1 bugs are fixed with regression coverage (see Test plan).
- [ ] The script-path convention is documented in `skill-conventions` and applied repo-wide.
- [ ] The baseline is re-locked with `--write-baseline`; `ccxp`, `drive`, `retro` and `address-pr` are each ≥ 70.
- [ ] Any phase split off is filed as its own `dev/TODO/` task and linked here.
