---
status: Done
scheduled: 2026-10-12
estimation: 1
source: PR #286 round-5 independent review, 2026-10-10
blocks: T20261009-154870
claimed_by:
claimed_role:
---

# T20261010-129025: `mode.sh`'s no-op fast path trusts doc text over live GitHub state

## TLDR

- **Type**: bug
- **Problem**: `mode.sh`'s "already in mode" fast path trusts doc text
  and exits before ever checking live GitHub state, so a freshly
  `sync`-templated doc can falsely claim team protection is live when
  it isn't.
- **Solution**: verify live branch-protection state before trusting the
  text match; fall through to the real apply path on disagreement.

## Problem

- **Type**: bug
- `repo-conventions/scripts/mode.sh`'s "already in $MODE mode" fast path
  (`mode.sh:69-73` pre-fix) exits **before** ever calling GitHub's
  branch-protection API, based purely on a text-match heuristic
  (`grep -qi "no ci"` + `grep -qi "direct.to.main"` on the policy doc).
- Discovered independently during T20261009-154870's PR #286 design
  review (round 5): `repo-conventions/templates/guidelines.md:11-20`'s
  team-worded text never matches that heuristic, so **any** freshly
  `/repo-conventions sync`-templated `guidelines.md` reads as
  `CURRENT=team` the instant it's created — even on a genuinely fresh
  repo where GitHub branch protection was never actually enabled.
  `mode.sh team` on such a repo exits 0 claiming "already in team mode,"
  and `main` stays unprotected while the doc claims otherwise.
- Pre-existing gap, not introduced by T20261009-154870's design — that
  task's new `setup` verb is just the first caller to expose it, by
  making "apply team policy" an automatic default rather than a
  deliberately human-invoked `mode team`.
- Blocks T20261009-154870: that task's design currently assumes
  `mode.sh`'s no-op fast path is a reliable signal; it isn't, until this
  is fixed.
- Done = the fast path verifies live GitHub state before trusting a
  doc-text match, for every `mode.sh` caller — not just the new `setup`
  verb.

## Context

- `mode.sh:48-61` resolves the target doc (`dev/guidelines.md`, falling
  back to `CLAUDE.md`).
- `mode.sh:63-68` (pre-fix) detects `CURRENT` from that doc's text alone.
- `mode.sh:70-73` (pre-fix) exits 0 immediately when `CURRENT == $MODE`
  — before the CI-presence check (`:85-90` pre-fix), the confirmation
  gate (`:93-104` pre-fix), and the actual API call (`:107-133` pre-fix).
- `$REPO` was resolved *after* the fast-path check (`:75-82` pre-fix) —
  too late to be available for a live-state query from inside that check.
- `tests/mode.bats` has 15 existing tests exercising this script via a
  stubbed `$GH_SH` that logs every invocation.

## Solution

- Move `$REPO` resolution to before the fast-path check (same resolution
  call, same "could not determine repo" hard-fail — just runs earlier,
  since both the new live-state check and the existing apply path need
  it).
- When the text heuristic says `CURRENT == $MODE` (no-op candidate): query
  live state first — `bash "$GH_SH" api repos/$REPO/branches/main/protection`
  (reuses the same 404-tolerant pattern the existing solo-DELETE path
  already uses at `mode.sh:127-132` pre-fix) — before trusting the text:
  - Live state agrees with `$MODE` → genuine no-op, exit 0 as before
    (preserves existing idempotency for the common already-correct case).
  - Live state disagrees → do **not** exit early; fall through into the
    normal apply path (CI check → confirm → API call → doc rewrite)
    exactly as if `CURRENT` had been detected as different from `$MODE`.
  - The live-state query itself fails in a way that isn't a recognizable
    404 → hard error (fail-safe, same philosophy as the existing non-404
    DELETE-failure handling) rather than silently guessing either way.
- Only one extra read-only API call, only on the no-op-candidate path —
  not added to every invocation's hot path (the mismatch path already
  calls the API regardless, so it doesn't need a separate check).
- **Alternatives considered and rejected:**
  - Document-only band-aid (flag the gap in `setup`'s summary instead of
    fixing `mode.sh`): rejected by the maintainer — fixes only the
    symptom for one caller, leaves the root cause (and every other
    `mode.sh` caller) still wrong.
  - Changing `/repo-conventions sync`'s template behavior to omit the
    policy section on a brand-new file: rejected — widens blast radius to
    every `sync` caller, not just this bug.
  - A `mode.sh --force` flag to bypass the text check entirely: rejected
    — the live-state check achieves the same correctness without adding
    a footgun flag a caller could misuse to skip verification deliberately.

## Root cause

- `mode.sh`'s "already in mode" check (pre-fix `:70-73`) was written on
  the assumption that doc text and live GitHub state are always in sync
  — true as long as `mode.sh` is the *only* code path that ever writes
  the `## Branch and Merge Policy` section. That assumption silently
  broke the moment a second code path started writing team-worded text
  into that section without ever calling the API:
  `/repo-conventions sync` (`repo-conventions/SKILL.md:132-141`) copies
  `repo-conventions/templates/guidelines.md:11-20` verbatim into a
  brand-new `guidelines.md` — team-worded, with no corresponding
  `PUT .../protection` call.
- Git archaeology: `templates/guidelines.md`'s team-worded §Branch and
  Merge Policy and `mode.sh`'s own `TEAM_BLOCK` (`mode.sh:148-158`
  pre-fix) have carried identical text since the repo's conventions were
  first established — this isn't a recent drift, it's a gap that existed
  from the start and was simply never exercised: historically, `mode.sh`
  was always invoked deliberately by a human who already knew the live
  state, so the two code paths writing the same section never collided
  in a way that mattered. T20261009-154870's new `setup` verb is the
  first caller to make "apply team policy automatically on a fresh repo"
  a default, unattended action — an oversight surfacing, not a
  deliberate trade-off anyone signed off on.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/mode.sh` | 63-91 (post-fix) | The fast-path check being fixed: doc-text detection, `$REPO` resolution, live-state verification, fallthrough |
| `repo-conventions/templates/guidelines.md` | 11-20 | The team-worded template text `sync` copies verbatim, with no API call — the trigger for the false no-op |
| `repo-conventions/SKILL.md` | 132-141 | `sync`'s own workflow description — confirms it only copies templates, never calls `mode.sh` |
| `tests/mode.bats` | 120-205 | Updated/added BATS coverage for the fix |

## Test plan

- [x] Confirm red: run `tests/mode.bats` against the pre-fix script —
  there is no existing test for "doc says team, live state is NOT
  protected" (the bug), so the gap itself isn't caught by the existing
  15 tests; added 3 new cases exercising it. Verified: ran the 3 new
  cases against the unpatched script (PATH-adjusted to avoid an
  unrelated sandbox `python3` SIGKILL quirk) — all 3 failed red, the 14
  unaffected original tests still passed, confirming both the bug and a
  clean baseline.
- [x] `bats tests/mode.bats` — all original 15 tests still pass unchanged
  (verifies the fix preserves existing idempotency behavior for the
  common already-correct case). Verified: 17/17 green post-fix (14
  original unaffected + 1 updated no-op test + 2 new).
- [x] New case: doc says `team`, live state already protected (GET
  returns 200) → no-op preserved (no PUT/DELETE call), doc unchanged.
  Verified green.
- [x] New case: doc says `team`, live state NOT protected (GET 404) → no
  longer a false no-op — falls through, calls PUT, doc stays `team`
  (already correct wording, so the rewrite is a no-op content-wise, but
  the API call happens). Verified green.
- [x] New case: doc says `solo`, live state already unprotected (GET 404)
  → no-op preserved, no DELETE call. Verified green.
- [x] Full repo-wide `bats tests/*.bats` run (841 cases) — zero
  regressions, exit code 0.
- [ ] Manual verification against the real GitHub API is out of scope —
  this repo's own CI already runs `mode team` indirectly via its branch
  protection state, so `bats`'s stubbed-`$GH_SH` coverage is the
  verification surface; a live run happens naturally the next time
  `/repo-conventions mode` or `setup` is invoked for real.

## Done criteria

- [x] `mode.sh`'s fast path verifies live state before a no-op exit —
  test: the 3 new BATS cases above (all green).
- [x] All 15 pre-existing `tests/mode.bats` cases still pass unchanged —
  test: `bats tests/mode.bats` (17/17 green, including the 14 untouched
  by this change).
- [x] `$REPO` resolution runs before the fast-path check — test: code
  inspection (`git diff` on `mode.sh`), confirmed by the new live-state
  test cases actually exercising a `$REPO`-dependent API call from
  inside that branch.
