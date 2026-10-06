---
status: Done
estimation: 2
source: 2026-09-25 conversation — surfaced live while /address-pr claiming
  T20260916-232402 in build-pipeline-repo
related: T20260809-355059 (same file, same `status:` field, different bug —
  that one is about the `Coding` literal being domain-inappropriate; this
  one is about _tc_fm_set corrupting any multi-line frontmatter value it
  overwrites, `Coding` or otherwise)
claimed_by:
claimed_role:
scheduled: 2026-10-05
---

# T20260925-383305: `_tc_fm_set` leaves orphaned continuation lines when overwriting a multi-line YAML frontmatter value

## TLDR

- **Type**: bug
- **Problem**: `_tc_fm_set` (`_session/task_claim.sh`) replaces a frontmatter field's
  first line but leaves its folded continuation lines behind as garbage.
- **Solution**: track a `skipping` state in the existing awk script — once the
  matched `field:` line is replaced, consume every subsequent indented
  (continuation) line until a non-indented line or the closing fence appears.

## Problem

- `_session/task_claim.sh:157-189` (`_tc_fm_set`, called from `acquire` to set
  `status: In Progress`, and elsewhere for `claimed_by`/`claimed_role`/
  `scheduled`) matches a field with a single-line awk test —
  `index($0, f":") == 1` finds the line starting `field:` and swaps it for
  the new `field: value` line — but a plain YAML scalar can fold across
  multiple lines when continuation lines are indented more than the key.
  The awk script never detects or consumes those continuation lines, so they
  fall through to the unconditional `print` and survive as orphaned garbage
  under the new value.
- Reproduced live: `T20260916-232402` in `build-pipeline-repo` had:

  ```
  status: Review — SUPERVISED (PR merged, hashdata-docmind#1; needs a human
    with a real DocMind deployment to spot-check the zh-TW UI before this
    task can close — no live backend in any sandbox we control)
  ```

  Running `task_claim.sh acquire T20260916-232402` produced:

  ```
  status: Coding
    with a real DocMind deployment to spot-check the zh-TW UI before this
    task can close — no live backend in any sandbox we control)
  ```

  — the two continuation lines from the old value are now dangling under
  `status: Coding`, technically still valid YAML (plain-scalar folding makes
  them part of the same value again), but garbled content. Had to hand-fix
  by deleting the two orphaned lines before the file was usable.
- Impact: any multi-line frontmatter value is at risk, not just `status` —
  `_tc_fm_set` is generic and is also called for `claimed_by`/`claimed_role`/
  `scheduled`; those happen to usually be single-line in practice, but
  nothing in the function prevents the same corruption the moment one wraps.
  This task file's own `source:`/`related:` fields are multi-line and were
  — by luck, not by guarantee — never the field `_tc_fm_set` was asked to
  overwrite.

## Context

- `_tc_fm_set` is a pure, idempotent frontmatter setter used everywhere a
  claim/status/schedule write happens: `acquire`, `release`,
  `release-others`, `_tc_stamp_scheduled_if_needed`, and the legacy-claim
  migration path (`_session/task_claim.sh:536-551, 561-568, 608-611, 217`).
  A single shared bug surfaces at every one of those call sites.
- Reproduction environment: any task file whose targeted field's *existing*
  value folds onto a second line (common for narrated statuses like
  `Review — SUPERVISED (...)` or `Blocked by T{id} — waiting on ...` that
  wrap past typical line-length conventions).
- No repo lint currently catches this — `lint_tasks.py` validates frontmatter
  shape, not that a `_tc_fm_set` call left the file well-formed; the only
  reason it's been caught at all is a human noticing garbled status text.

## Solution

- Add a `skipping` state to the existing `_tc_fm_set` awk script
  (`_session/task_claim.sh:169-187`):
  - When the matched `field:` line is found and replaced, set `skipping=1`
    instead of immediately resuming normal `print`.
  - While `skipping`, consume (do not print) every line that starts with
    whitespace (`^[ \t]`) — a continuation line of the old value — leaving
    `skipping=1`.
  - The first line that does **not** start with whitespace (a new `key:` at
    column 0, or the closing `---` fence, neither of which is ever indented)
    clears `skipping` and falls through to the normal per-line handling for
    that line (so a new field or the closing fence is still processed
    exactly as before).
- Alternatives considered and rejected:
  - **Full YAML parse (e.g. `python3 -c 'import yaml; ...'`) instead of
    awk** — rejected: `_tc_fm_set` is called from a hot path (every
    `acquire`/`release`) in pure bash/awk with no external interpreter
    dependency today; adding a hard `python3`+`pyyaml` runtime dependency to
    a core claim-lock primitive is a bigger blast radius than fixing the
    8-line awk script that already does the job for the single-line case.
  - **Reject/refuse to overwrite a multi-line value** (fail loud instead of
    silently corrupting) — rejected: every real call site (`status`,
    `claimed_by`, `scheduled`) legitimately needs to overwrite whatever was
    there before, multi-line or not; refusing would just move the breakage
    from "silent corruption" to "claim acquisition hard-fails," which is
    worse for the claim-lock's core job.
  - **Strip continuation lines at read time instead of write time** —
    rejected: `_tc_fm_get` already returns only the first line correctly
    (never a bug there); the corruption is purely a write-side leftover, so
    fixing the write path is the minimal, root-cause fix.

## Test plan

- [x] Unit: new BATS case in `tests/task_claim.bats` — set a multi-line
  `status:` value (3-line fold, mirroring the live repro), call
  `_tc_fm_set ... status "In Progress"`, assert:
  - [x] no leftover continuation-line text survives anywhere in the file
  - [x] exactly 2 `---` fence lines (frontmatter wasn't corrupted/widened)
  - [x] `_tc_fm_get` round-trips the new value
  - [x] an adjacent field (`claimed_by`) directly after the multi-line value
        is untouched
- [x] Unit: the resulting frontmatter re-parses cleanly via
  `python3 -c 'import yaml; yaml.safe_load(...)'` (same pattern as
  `tests/claimant_id.bats`'s YAML round-trip test; skips gracefully if
  `pyyaml` is unavailable).
- [x] Regression: existing `_tc_fm_set` BATS cases (replace, never-touch-owner,
  empty-value, insert-absent-field) still pass unmodified — full suite:
  `bats tests/task_claim.bats` 108/108, `bats tests/` 839/839.
- [ ] Post-merge: next live multi-line-status claim/release in any consumer
  repo produces no orphaned lines (observational — no dedicated CI for this,
  covered going forward by the new unit test instead).

**Doc-impact review** (`_docs/doc-impact.sh`): flagged ~10 `*/SKILL.md` files
that mention `task_claim.sh` by filename. Reviewed — no change needed: this
fix is an internal correctness fix to `_tc_fm_set`'s write path (no new verb,
no changed call signature, no documented-behavior change), so none of those
SKILL.md references need updating.

**Quality probe**: `bash quality-probe/scripts/probe.sh --task T20260925-383305`
— 0 errors/warnings (shellcheck), 1 pre-existing SC1091 info (unrelated line
534, `source "$HOME/.claude/.env"`) counted as a delta against an empty
baseline (first probe run for this file) — record+warn only, no regression
introduced by this change.

## Done criteria

- [x] `_tc_fm_set` consumes continuation lines of the field it overwrites —
  `tests/task_claim.bats::"_tc_fm_set consumes continuation lines of a
  multi-line value it overwrites"`.
- [x] Fix is minimal and scoped to `_session/task_claim.sh`'s `_tc_fm_set`
  function (`_session/task_claim.sh:161-192`) — no behavior change to
  `_tc_fm_get` or any caller's call signature.
- [x] All pre-existing `_tc_fm_set`/`task_claim.sh` BATS cases still pass —
  `bats tests/task_claim.bats`.

## Root cause

- `_session/task_claim.sh:161-189` (`_tc_fm_set`) was written assuming every
  frontmatter value is single-line — introduced in the original
  `task_claim.sh` design (build-pipeline-repo T20260611-104067, ported to
  ccxp-skills). The awk match (`index($0, f":") == 1`) correctly finds and
  replaces the *first* line of a field, but the function has no concept of
  "the rest of this value" — it was never extended when narrated,
  multi-sentence `status:`/other values (e.g. `Review — SUPERVISED (...)`)
  started being written in practice, which is what let a plain scalar value
  fold across lines in the first place.
- This is an **oversight**, not a deliberate trade-off: no commit or review
  comment discusses the multi-line case; the single-line assumption was
  simply never revisited as narrated-status values grew longer over time.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | `161-189` | `_tc_fm_set` — the function being fixed |
| `_session/task_claim.sh` | `143-159` | `_tc_fm_get` — unaffected; confirms read-side is already correct |
| `tests/task_claim.bats` | `59-87` | existing `_tc_fm_set` coverage; new continuation-line case added alongside |

## Closed (2026-10-06)

- Shipped in three PRs, per `/drive`'s Claim PR → Design PR → Implementation PR sequence:
  - Claim: [#261](https://github.com/Synx-Data-Labs/ccxp-skills/pull/261)
  - Design: [#262](https://github.com/Synx-Data-Labs/ccxp-skills/pull/262) — design-score 87/100 (PASS, threshold 70); one independent review round, clean bill (no findings — every `file:line` citation verified exact against the actual source).
  - Implementation: [#263](https://github.com/Synx-Data-Labs/ccxp-skills/pull/263)
- All Done criteria met — see the checked boxes above:
  - `_tc_fm_set` now consumes continuation lines via an awk `skipping` state — proven by the new BATS case and the YAML-round-trip case.
  - Fix scoped entirely to `_tc_fm_set`; `_tc_fm_get` and every caller's signature unchanged.
  - Full regression stayed green throughout: `bats tests/task_claim.bats` 108/108, `bats tests/` 839/839.
- A real TDD gotcha surfaced and was fixed mid-task: the first draft of the new BATS assertions used a bare `! grep -q ...` line, which — per POSIX/bash `set -e` semantics — never aborts the test even when the underlying `grep` finds the orphaned text (a `!`-negated command's failure is specifically exempted from triggering `errexit`). That silently turned a would-be RED assertion into a false "ok". Caught during the RED-phase verification step (the test passed against KNOWN-buggy code, which should never happen) and fixed by switching to `run grep ...; [ "$status" -ne 0 ]`, which does propagate correctly.
- The implementation PR's independent review (`/address-pr` §2.d) found a real, unaddressed edge case: the skip test `$0 ~ /^[ \t]/` only matched indented lines, so a completely **blank** line mid-fold cleared `skipping` early and leaked every continuation line after it. Verified by manual repro, then fixed via the standard red-green cycle (new BATS case fails against the old `/^[ \t]/`-only condition, passes against the widened "indented OR blank" condition) — pushed as a follow-up commit on the same PR. Full suite: 840/840 after the fix.
- External/unverified: the Test plan's one post-merge item (observational — no dedicated CI for a multi-line-status claim/release in a consumer repo) stays unchecked by design; the new unit tests are the durable regression guard going forward.
- No follow-up tasks filed — this was a fully self-contained single-function fix.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0, code-class. All three new BATS cases (continuation-line consumption, YAML round-trip, blank-line-mid-fold) were written first and verified RED against the unfixed code, then GREEN after the corresponding awk fix.
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 (fresh full-suite runs before each PR push: `bats tests/` 839/839 then 840/840, `bats tests/task_claim.bats` 108/108 then 109/109, shellcheck clean) and this Phase 7.0 block.
- Systematic debugging (`superpowers:systematic-debugging`): no — both root causes (the orphaned-continuation bug and the blank-line gap) were pinned by direct manual repro, not an extended hypothesis-driven session.
- Receiving code review (`superpowers:receiving-code-review`): yes on the implementation PR — the independent review (`/address-pr` §2.d) found the blank-line gap; verified it myself with a manual repro before fixing (not blind implementation), then fixed via the standard red-green cycle and pushed a follow-up commit. The design PR's own review returned a clean bill (no findings to respond to).
