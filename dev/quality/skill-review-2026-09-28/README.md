# Skill quality review — 2026-09-28

A one-time review of all 47 skills, plus a quality loop you can re-run. Per-skill findings are in `batch1.md`–`batch5.md`: grades, line refs, stale refs, and 2–3 eval cases per skill.

- **Static score**: `python3 skill-conventions/scripts/skill_score.py` gives a mean of **86.0**. The low scorers are the biggest skills, which fail on context cost and changelog noise.
- **Maturity**: 1 skill at L0, 45 at L1, 1 at L2 (`todo`, which has the first eval suite). None at L3 or above yet, because no skill has a recorded eval run.
- **Judgment review**: 5 parallel reviewers each read a batch of skills, and the severe claims were spot-checked by hand. The findings below are ordered by risk.

## 1. Fix first — correctness and safety bugs

| Skill | Bug | Ref |
|---|---|---|
| `cleanup-branch` | Force-deletes (`branch -D`) any branch with a merged PR, including local commits made after the merge. Compare the branch tip to the PR's `headRefOid` first. | `cleanup-branch/scripts/cleanup-branch.sh:89-92` |
| `drive` | `trap 'rm -rf "$TARGET"' EXIT` inside a Bash tool call deletes the clone when that call ends. `$TARGET` doesn't persist between calls either. | `drive/SKILL.md:151` |
| `migrate-task`, `statusline-setup` | The frontmatter isn't valid YAML (an unquoted colon-space inside the description), so the trigger description may never load. Quote the value. | line 3 of each |
| `slack` | `SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_FOO"` expands to empty when the var is only in `~/.claude/.env`, so the message silently goes to the default channel. | `slack/SKILL.md:64` |
| `todo` (and most script-calling skills) | `bash todo/scripts/todo-next.sh` fails with exit 127 from a consumer repo. **Confirmed by a live eval run** (see §4). Standardize on one base-dir convention. | `todo/SKILL.md:83,126` |
| `autopilot` | A `WAITING` result counts as progress, so it re-dispatches `/address-pr` on the same unapproved PR every 60 s. | `batch1.md` |
| `top` | `--before` inserts tasks in reverse order, which puts blockers *behind* the tasks they block. | `top/SKILL.md:108-129` |
| `incept` | Says "lint only the touched file", then runs `lint-docs.sh --fix` across the whole doc set. | `incept/SKILL.md:111-115` |
| `gcpr` | Hardcoded `Co-Authored-By: Claude Opus 4.6` trailer. Step 6.5 edits the task file after the PR is created and never commits it. | `gcpr/SKILL.md:163,172` |
| `rca` + `labrun-rca` | A delegated RCA posts twice, once to the channel root, which breaks labrun-rca's own rule. | `batch2.md` |
| `email-triage` | Says "read-only" because it assumes the Gmail connector can't write, but the connector exposes send, trash and label tools. | `batch4.md` |

## 2. Cross-cutting patterns (fix once, many skills benefit)

- **Paraphrasing other skills goes stale.** `ccxp` and `drive` restate `/todo next` ("top 5, skips blocked") and both are now wrong. The script returns the top 3 in queue order and skips neither.
  - Rule: cite a phase anchor or call the script, never re-describe another skill's behavior.
- **Changelog narrative in skill bodies.** There are 150+ task-ID mentions, 40 in `ccxp` alone, many of them for tasks that aren't in this repo. Per the reviewers they're 15–25% of the big skills. Move them to JOURNAL. The scorer's `changelog_noise` check keeps them out afterwards.
- **Logic duplicated in prose.**
  - Queue editing is written out 4 times (`stage`, `top`, `bottom`, `todo sweep`) and coded a 5th time in `migrate.sh`. Extract it to `_queue/queue.sh` with BATS tests.
  - Commit/PR boilerplate is copied 3 times, all pointing at a `dev/branch-merge-policy.md` that doesn't exist.
- **Company residue.** Examples: `#acme-*` channels, `America/Chicago`, `synx-merge-bot`, `private-skills-repo/…`, `vpn/scripts/vpn.sh`. This contradicts the README's "no company-specific dependency" promise.
- **Cloudflare family triggers overlap.** `cloudflare`'s "any Cloudflare development task" competes with all 10 of its siblings, and it also ships duplicate copies of their references (~6k lines).
  - `sandbox-sdk` never says "Cloudflare", and `turnstile-spin` fires on any "CAPTCHA".
  - Make `cloudflare` a fallback router and add a "not for X → use Y" line to each sibling.
- **`skill-conventions` isn't self-sufficient.** It defers to `superpowers:writing-skills`, which isn't installed. §10 (added here) now provides the local rubric.

## 3. Concision targets (reviewers' cuttable estimates)

| Skill | Size | Cuttable | How |
|---|---:|---:|---|
| `ccxp` | 90 KB / 1011 lines | 55–60% | Drop history, split the IPM ritual (already filed as T20260923-584914), cite `/todo` instead of restating it |
| `wrangler` | 18 KB / 923 lines | ~75% movable | Move per-product command reference into `references/` |
| `drive` | 66 KB / 654 lines | ~40% | Drop history; replace the duplicated solo-repo claim section with a link to `/claim` |
| `address-pr` | 33 KB | ~45% | Copilot-era leftovers; the gate prose restates `pre-merge-check.sh` |
| `retro` | 42 KB | ~40% | Five mechanical phases should become scripts (§9) |
| `todo`, `design-score`, `quality-probe`, `repo-conventions`, `statusline-setup` | — | 40–50% | Each restates its own bundled script's algorithm, which will drift |

Rule of thumb: when a script exists, the SKILL.md says *when* to run it and *what judgment* to apply to its output, never *how* it works.

## 4. The quality loop (what was built)

Defined in `skill-conventions/SKILL.md` §10:

- **`skill_score.py`**: a deterministic 0–100 static score and maturity level. The CI ratchet (`--check dev/quality/skill-scores.json`) means a skill's score can go up but never drop below its recorded baseline.
- **`skill_eval.py`**: runs `<skill>/evals/evals.json` through `claude -p` in a throwaway fixture repo with credentials scrubbed. Assertions are regex and file checks over the transcript, never an LLM judge. Each case runs N times, and a case passes at ≥ 90% of runs.
  - First suite: `todo/evals/`. Its `command_succeeded` assertion catches the exit-127 path bug above, which a live run confirmed. The suite stays red until the path is fixed; that's the point of writing the failing test first.
- **`skill_feedback.py`**: the log of real-use misbehavior. An open item blocks L4 Master and closes only when codified as an eval case, so a fixed mistake can't silently come back.
- **Ladder**: L0 Draft → L1 Novice (score ≥ 60) → L2 Apprentice (≥ 3 eval cases) → L3 Practitioner (latest run ≥ 90%) → L4 Master (score ≥ 85, last 3 runs ≥ 90%, no open feedback).
- **Cadence**: `/retro` Phase 4c now reads the scorer and the feedback log and still acts on only one skill per week.

## 5. Suggested order of work

1. Quick fixes: the §1 bugs, plus quoting the two broken frontmatters. Each is small; add the matching eval case from `batchN.md` with each fix.
2. One base-dir convention for script paths, applied everywhere. This turns `todo`'s eval green and unblocks writing evals for every script-backed skill.
3. Cut changelog noise and restated algorithms. This should lift `ccxp`, `drive`, `retro` and `address-pr` by 20–40 points each; re-baseline afterwards.
4. Extract `_queue/queue.sh` and a shared land-as-PR helper.
5. Cloudflare family: a router description, "not for" lines, drop the duplicated references, and either mark vendored skills `upstream:` in frontmatter or normalize them to the `Use when…` convention.
6. Grow evals from real use: every `skill_feedback.py add` becomes a case. Aim for 3 cases per daily-use skill (`todo`, `drive`, `gcpr`, `address-pr`, `claim`) first.
