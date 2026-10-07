---
status: Done
scheduled: 2026-10-05
estimation: 1
source: Split off T20260928-101526 (2026-09-28 skill-review findings, README §1) — the design-score gate failed on the parent 8-point task (56/100), so this first, self-contained bug is being driven to merge on its own per /drive's "break into subtasks" guidance.
related: T20260928-101526
description: Quote two SKILL.md descriptions whose unquoted ": " breaks YAML frontmatter parsing
claimed_by:
claimed_role:
---

# T20261006-138216: Fix invalid YAML frontmatter in migrate-task and statusline-setup SKILL.md

## TLDR

- **Type**: bug
- **Problem**: `migrate-task/SKILL.md` and `statusline-setup/SKILL.md` have an unquoted `": "` inside their plain-scalar `description:` value, which is invalid YAML — `yaml.safe_load` raises on both.
- **Solution**: quote the two description values (double-quote for `migrate-task`, single-quote for `statusline-setup` to avoid escaping its embedded double quotes), add a repo-wide regression test, and re-lock the two affected skill-quality baseline scores.

## Problem

- 2026-09-28 skill-review finding (`dev/quality/skill-review-2026-09-28/README.md` §1, carried into T20260928-101526's Problem list): "`migrate-task/SKILL.md:3` and `statusline-setup/SKILL.md:3` have invalid YAML frontmatter (an unquoted colon-space in the description), so their triggers may never load."
- Reproduced directly:

  ```
  $ python3 -c "import yaml,re; t=open('migrate-task/SKILL.md').read(); m=re.match(r'^---\n(.*?)\n---\n', t, re.DOTALL); yaml.safe_load(m.group(1))"
  yaml.scanner.ScannerError: mapping values are not allowed here
    in "<unicode string>", line 2, column 143:
       ...  — e.g. a mis-scoped target-repo: task, or a task filed in the w ...
  ```

  Same failure mode on `statusline-setup/SKILL.md` (column 119, the `"ctx: N% left | TASK: ...` text).
- Impact: `skill_score.py`'s `split_frontmatter()` catches the `yaml.YAMLError` and returns `fm=None` (silent — no exception bubbles up), so both skills score `0/10` on the `frontmatter` check and `0/5` on `trigger` — confirmed via `dev/quality/skill-scores.json`'s locked baseline: `migrate-task: 61`, `statusline-setup: 69`, both well under the parent task's "no skill below 70" Done criterion. Any consumer that parses `description:` out of frontmatter (not just the scorer) would hit the same parse error.

## Context

- Both files' `description:` is a plain (unquoted) YAML scalar, written on one line, that happens to contain a literal `": "` later in the sentence — YAML's block-scalar grammar reads `": "` as the start of a nested mapping key, which is a syntax error at that position inside an already-opened scalar context.
- `migrate-task/SKILL.md:3`: `"...e.g. a mis-scoped target-repo: task, or..."` — the offending text is `target-repo:` followed by a space.
- `statusline-setup/SKILL.md:3`: `"...the Claude Code statusline script — the "ctx: N% left | TASK: ..." line..."` — two offending spots (`"ctx:` and `TASK:`), plus the value already contains embedded double quotes.
- Both files trace back to `5051a9e` ("Initial public release") in this repo's visible history — the original company-internal authorship/SHA that introduced the typo predates the public-release history squash and isn't recoverable here. Given how narrow and clearly-unintentional the break is (a prose sentence using a colon for emphasis, not a deliberate YAML construct), this reads as an oversight, not a deliberate choice — **assumed**, not independently verifiable past the squash point.

## Solution

- **`migrate-task/SKILL.md`**: wrap the whole `description:` value in double quotes. No embedded double quotes in the string, so no escaping needed (two apostrophes — `repo's` — are fine unescaped inside a double-quoted scalar).
- **`statusline-setup/SKILL.md`**: wrap the whole `description:` value in single quotes instead — the string has three embedded double-quoted substrings (`"ctx: ..."`, `"ap:[r]/[b]/[s] ..."`, `"last=<slug>"`) that double-quoting would force escaping (`\"` ×6), but only one embedded apostrophe (`settings.json's`), which single-quoting escapes by doubling (`settings.json''s`) — the smaller, more readable diff.
- **Alternatives rejected**:
  - *Double-quote both, escaping embedded quotes* — correct but produces a noisier diff on `statusline-setup` (6 escape points vs. 1); rejected for readability, not correctness.
  - *Rewrite the sentences to avoid `": "` entirely* — would touch skill-trigger prose that's tuned for model-invocation matching (per `skill-conventions`); quoting is the minimal, behavior-preserving fix.
- **Regression test**: added `RepoFrontmatterTest.test_every_skill_frontmatter_is_valid_yaml` to `skill-conventions/scripts/test_skill_quality.py` — walks every real `*/SKILL.md` via `skill_score.iter_skills()` + `split_frontmatter()` and asserts none come back `fm=None`. Confirmed red (`['migrate-task', 'statusline-setup']`) before the fix, green after (`git stash push -- migrate-task/SKILL.md statusline-setup/SKILL.md` to isolate).
- **Baseline re-lock**: `dev/quality/skill-scores.json` — `migrate-task: 61 → 91`, `statusline-setup: 69 → 99` (re-measured via `skill_score.py --repo .` after the fix). Scoped to just these two entries, not a full-repo `--write-baseline` (the parent task's "re-lock the baseline" Done criterion covers the full-repo pass once every README §1 bug is fixed).
- Does **not** attempt the rest of T20260928-101526 (script-path convention, concision, shared helpers, Cloudflare family, company residue) — those remain on the parent task, which stays `In Progress`/open with this slice checked off.

## Test plan

- [x] `python3 -c "import yaml,re; ..."` on both files — frontmatter parses, `description` value unchanged in content (verified via printed value).
- [x] `python3 skill-conventions/scripts/test_skill_quality.py` — 19/19 pass, including the new `RepoFrontmatterTest` case.
- [x] Confirmed the new test fails on the pre-fix files (`git stash push -- migrate-task/SKILL.md statusline-setup/SKILL.md` + re-run → `AssertionError: ['migrate-task', 'statusline-setup'] != []`) and passes after `git stash pop`.
- [x] `python3 skill-conventions/scripts/skill_score.py --check dev/quality/skill-scores.json` — `✅ 50 skills at or above baseline`.
- [x] `bats tests/` — 836/836 pass.
- [x] `bash _docs/lint-docs.sh migrate-task/SKILL.md statusline-setup/SKILL.md` — 0 errors.

## Done criteria

- [x] `migrate-task/SKILL.md` frontmatter parses as valid YAML — `skill-conventions/scripts/test_skill_quality.py::RepoFrontmatterTest::test_every_skill_frontmatter_is_valid_yaml`.
- [x] `statusline-setup/SKILL.md` frontmatter parses as valid YAML — same test.
- [x] Regression coverage exists so a future skill reintroducing this mistake fails CI before merge — `skill-conventions/scripts/test_skill_quality.py:137-149` (new test) + `dev/quality/skill-scores.json` baseline ratchet (re-locked scores mean a regression back toward 61/69 now fails `skill_score.py --check`).
- [x] Parent task `T20260928-101526` updated to record this split-off and link back here.

## Root cause

- Mechanism: an unquoted YAML plain scalar cannot contain `": "` (colon immediately followed by a space) — the parser treats it as the start of a nested block mapping, which is a syntax error when it appears mid-scalar rather than at the start of a line. `yaml.safe_load` raises `ScannerError: mapping values are not allowed here` at the exact column of the offending `": "`.
- Introduced: both files predate this repo's visible history (squashed at `5051a9e`, "Initial public release" — see `git log --follow`, which shows no earlier commit for either file in this clone). Given the narrowness of the mistake (natural-language use of a colon inside prose that happens to collide with YAML's mapping-key grammar), this is assessed as an **oversight**, not a deliberate authoring choice — assumed, since the pre-squash history isn't available to confirm intent directly.
- Why it went undetected: `skill_score.py`'s `split_frontmatter()` swallows `yaml.YAMLError` and returns `None` rather than raising, so the breakage shows up only as a depressed frontmatter/trigger score — and the `skill-quality` CI check (`skill_score.py --check`) is a baseline **ratchet**, not an absolute threshold, so a baseline already locked at the broken score (61, 69) passed CI indefinitely without a human cross-referencing the "no skill below 70" Done criterion by hand.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `migrate-task/SKILL.md` | `3` | frontmatter `description:` — now double-quoted |
| `statusline-setup/SKILL.md` | `3` | frontmatter `description:` — now single-quoted |
| `skill-conventions/scripts/test_skill_quality.py` | `129-149` | new `RepoFrontmatterTest` regression case |
| `dev/quality/skill-scores.json` | `migrate-task`, `statusline-setup` entries | baseline re-locked to the post-fix scores |
| `skill-conventions/scripts/skill_score.py` | `42-52` (`split_frontmatter`), `231-236` (`iter_skills`) | reused, unmodified, by the new test |

## Closed (2026-10-06)

- Shipped in **PR #273** (`t20261006-138216-fix-yaml-frontmatter`): https://github.com/Synx-Data-Labs/ccxp-skills/pull/273
- Met: both YAML parse errors fixed (verified unchanged description content), new repo-wide regression test added and confirmed red→green, baseline re-locked for the two affected skills, full `bats` (836/836) and python unittest (19/19) suites green, parent task T20260928-101526 updated with a link back here.
- External/unverified: none — this task's scope was fully self-contained and verified pre-merge.
- Follow-up tasks filed: none new. The parent, **T20260928-101526**, remains open and now carries a recommendation (in its own body) to decompose its remaining phases into further split-off tasks before resuming.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote `RepoFrontmatterTest`, confirmed it failed against the unmodified files (`git stash` isolation), then fixed and confirmed green.
- Verification (`superpowers:verification-before-completion`): yes — full `bats tests/` (836/836), full python unittest suite (19/19), `skill_score.py --check`, and `lint-docs.sh` all run and confirmed passing before PR, and again at close.
- Systematic debugging (`superpowers:systematic-debugging`): no — root cause was already identified by the 2026-09-28 review; this was confirm-and-fix, not open-ended debugging.
- Receiving code review (`superpowers:receiving-code-review`): no pushback needed — the independent review agent returned a clean bill on PR #273 with no findings to contest.
