---
status: Done
estimation: 4h
source: maintainer conversation, 2026-09-15
description: Add `/repo-conventions mode {solo|team}` to toggle a repo's Branch and Merge Policy plus actual GitHub branch protection
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260915-315552: Add `/repo-conventions mode {solo|team}` to switch a repo between solo and team branch policy

## TLDR

- **Type**: feature
- **Problem**: "solo-repo mode" only exists as hand-edited free text a
  maintainer must keep in sync with what `/claim`/`/drive` parse — no
  command sets it, and switching modes never touches the actual GitHub
  branch-protection state, so the doc and reality can drift.
- **Solution**: a new `repo-conventions/scripts/mode.sh solo|team` script,
  wired to `/repo-conventions mode {solo|team}`, that (a) rewrites the
  target repo's `## Branch and Merge Policy` section to the canonical
  wording for that mode and (b) calls the GitHub branch-protection API to
  match (`DELETE` for solo, `PUT` for team, after a CI-configured check).

## Problem

- Today, "solo-repo mode" (direct-to-`main`, no feature-branch PRs) exists
  only as free-text a repo's own `dev/guidelines.md`/`CLAUDE.md` Branch and
  Merge Policy section declares by hand — see `claim/SKILL.md:27-33` (the
  detection heuristic: `grep -qi "no ci"` + `grep -qi "direct.to.main"`) and
  `drive/SKILL.md:114`. There's no command that sets or flips this; a
  maintainer hand-edits the policy prose and hopes it still matches what
  `/claim`/`/drive` grep for.
- Worse, the doc text and GitHub's actual branch-protection state are two
  independent things today — a repo's `main` can be GitHub-protected while
  its doc still reads "solo, no CI", or vice versa, and nothing catches the
  mismatch. This task closes that gap for the one flow that changes mode
  deliberately (there's no attempt at periodic drift-reconciliation — see
  Alternatives rejected).

## Context

- Consumers of the mode signal (read-only, unaffected by this task):
  `claim/SKILL.md`'s "Solo-repo mode" section and `drive/SKILL.md:114`'s
  parallel text, both keyed off the same `grep -qi "no ci"` /
  `grep -qi "direct.to.main"` heuristic against `dev/guidelines.md` (falling
  back to `CLAUDE.md`).
- Canonical **team** wording already exists verbatim as this repo's own
  `## Branch and Merge Policy` (`dev/guidelines.md:11-20`) and its template
  (`repo-conventions/templates/guidelines.md:11-20`) — reuse it exactly,
  don't invent new phrasing.
- No canonical **solo** wording exists yet anywhere in-repo (grepped for
  `"no CI"` outside `SKILL.md` files — zero hits) — `claim/SKILL.md:28-29`'s
  own illustrative quote (*"This is a solo repo with no CI — direct-to-
  `main`, not feature-branch PRs."*) is the closest precedent and is reused
  near-verbatim as the new canonical block, since it already satisfies the
  detection heuristic by construction.
- `address-pr/scripts/pre-merge-check.sh:24` establishes the seam this
  task reuses: an overridable `GH_SH` variable defaulted to the sibling
  `_gh/gh.sh`, resolved *relative to the script's own directory* — so
  tests can stub `GH_SH` instead of hitting real GitHub. **Not** the same
  as `quality-probe/scripts/probe.sh:45`'s `QP_GH`, which hardcodes
  `$HOME/.claude/skills/_gh/gh.sh` — exactly the retired symlink-install
  layout `pre-merge-check.sh:21-22` calls out as deprecated (T20260914-871616).
  `pre-merge-check.sh` is the pattern to follow; `probe.sh` is the
  anti-pattern it replaced.

## Solution

- **New script**: `repo-conventions/scripts/mode.sh <solo|team> [--repo OWNER/NAME] [--doc PATH] [--skip-ci-check] [--yes]`
  1. Resolve the target doc: `dev/guidelines.md` if it has a
     `## Branch and Merge Policy` heading, else `CLAUDE.md`, else error
     ("no Branch and Merge Policy section found — run `/repo-conventions
     sync` first"). `--doc` overrides for testing/non-standard layouts.
  2. Detect current mode from that file with the *same* heuristic
     `claim/SKILL.md` already uses (`no ci` + `direct.to.main`, case-
     insensitive) — reusing the reader's own detection avoids a second,
     possibly-drifting definition of "what counts as solo."
  3. **No-op** if requested mode already matches detected mode: print
     "already in <mode> mode" and exit 0 — no doc rewrite, no API call
     (see Alternatives rejected on why this doesn't also reconcile
     protection state).
  4. **API call FIRST, doc rewrite SECOND** — deliberate ordering, not
     arbitrary: the live GitHub state is the harder-to-recover-from side
     (a stuck doc rewrite is just an uncommitted diff; a stuck protection
     change is the repo's actual security posture), so it goes first and
     the doc is only rewritten once it succeeds. If the API call fails,
     exit non-zero **without touching the doc** — the repo is left in
     whatever state it was already in (doc and reality still agree,
     just not with what was requested), never in the "doc claims X, API
     never confirmed it" drift state this task exists to prevent.
     **`team`**: verify CI is plausibly configured first —
     `.github/workflows/*.yml` must exist in the repo root, else error
     (unless `--skip-ci-check`, for repos whose CI lives outside GitHub
     Actions). Then:
     `bash "$GH_SH" api -X PUT repos/<owner>/<repo>/branches/main/protection --input -`
     with a body requiring PR-based merges but no named status checks or
     mandatory human approval (`required_status_checks.contexts: []`,
     `required_pull_request_reviews.required_approving_review_count: 0`,
     `enforce_admins: false`, `restrictions: null`) — deliberately loose:
     the goal is "no direct push", not gating on specific check names.
     The `0`-count default matches this suite's default auto-merge tier
     (`/address-pr` §3, CI-gated not human-review-gated); a repo that
     wants the suite's separate wait-for-approval tier instead can raise
     the count later via GitHub's own UI/API directly — this command
     doesn't need to special-case that, it only sets the starting point.
     **`solo`**: `bash "$GH_SH" api -X DELETE repos/<owner>/<repo>/branches/main/protection`
     — tolerate a 404 (no protection existed) as success; anything else
     non-2xx is a real failure, reported and non-zero exit, doc untouched.
  5. Only after step 4 succeeds: rewrite the section — replace everything
     from the `## Branch and Merge Policy` heading line up to (not
     including) the next `^##` heading (or EOF) with the canonical block
     for the target mode (team = the exact `dev/guidelines.md:11-20`
     wording; solo = the new canonical block, Context above). Python-based
     in-place edit (same idiom as `_ipm/stamp-scheduled.sh`'s frontmatter
     rewrite), so the replacement is line-precise rather than a fragile
     shell regex.
  6. `--yes` skips a one-line interactive confirmation before step 4's API
     call (`sync`'s own "always show a diff and ask before overwriting"
     precedent, `repo-conventions/SKILL.md:114`) — default requires it
     since this mutates live repo security settings; unattended callers
     (a future `/ccxp`/`/drive` invocation) pass `--yes` explicitly.
- **Skill wiring**: `repo-conventions/SKILL.md` gets a `mode {solo|team}`
  line in `## Argument` and a `### mode (solo/team switch)` workflow
  section under `## Workflow` that just delegates to the script (same
  pattern as `check`/`sync` already delegating to `lint.sh`).
- **Alternatives rejected**:
  - *Reconcile doc-vs-protection drift on every mode call, not just on a
    change* — rejected: doubles the script's scope (now a drift-detector
    *and* a mode-setter) for a case this task wasn't asked to solve; the
    no-op path (step 3) already covers "you asked for the mode you're
    already in," and a dedicated drift-check is a separable future task if
    it turns out to matter in practice.
  - *Default to a minimum approving-review count > 0 for team mode* —
    rejected as the **default**, not as a capability: this suite's
    default auto-merge tier merges once CI is green, no human reviewer in
    the loop, so a >0 default would fight the common case out of the box.
    The suite's own wait-for-approval tier already covers repos that want
    mandatory human review — they get there by raising the count via
    GitHub's UI/API after this command runs, not by this command guessing
    which tier a given repo wants.
  - *Auto-populate `required_status_checks.contexts` from the repo's
    actual workflow job names* — rejected for this pass: job names aren't
    stable across a repo's CI evolution, and a wrong/stale context list
    would silently block merges once a job is renamed; leaving `contexts:
    []` still requires the PR-based-merge property team mode cares about
    without a second thing to keep in sync. Flagged as a natural follow-up
    if a repo wants named-check enforcement.

## Test plan

- [x] `tests/mode.bats` (new, 14 tests) — `GH_SH` stubbed to a fake script
  recording its invocation args/stdin to a file instead of calling real
  GitHub:
  - [x] `solo` on a fresh team-mode fixture doc rewrites the Policy section
    to the solo wording (heuristic now matches "no ci" + "direct.to.main")
  - [x] `team` on a solo-mode fixture rewrites to the canonical team
    wording (the generic `repo-conventions/templates/guidelines.md:11-20`
    form, not this repo's own `_gh/gh.sh`-hardcoded copy — see `## Closed`)
  - [x] `team` calls `$GH_SH api -X PUT .../branches/main/protection` with
    the expected JSON body (asserted via the recorded stdin)
  - [x] `solo` calls `$GH_SH api -X DELETE .../branches/main/protection`
  - [x] `team` errors (non-zero, no API call recorded) when no
    `.github/workflows/*.yml` exists and `--skip-ci-check` is absent
  - [x] `team` proceeds (API call recorded) when `--skip-ci-check` is
    passed despite no workflows
  - [x] requesting the mode already in effect is a no-op: exit 0, doc
    unchanged, no `$GH_SH` invocation recorded
  - [x] prefers `dev/guidelines.md` over `CLAUDE.md` when both exist and
    only one has the Policy heading
  - [x] missing Policy heading in both files → non-zero exit, no API call
  - [x] (added during implementation) a 404 on `solo`'s DELETE is tolerated
    as success; a genuine non-404 API error on either mode hard-fails with
    the doc left untouched; `--doc` override works independent of cwd;
    missing/invalid mode argument is a usage error
- [x] `bats tests/mode.bats` green locally (14/14)
- [x] Full repo suite (`tests/*.bats _docs/*.bats`) still green — 703/703
  (one `task_claim.bats` flake reproduced once in the full-suite run,
  confirmed non-reproducing in isolation and in a full clean rerun; see
  `## Closed`)
- [ ] Manual, post-merge (cannot verify pre-merge without mutating a real
  repo's live branch protection): run `/repo-conventions mode team` /
  `mode solo` once against a disposable throwaway GitHub repo and confirm
  via `gh api repos/<owner>/<repo>/branches/main/protection` that the
  actual protection state matches what was requested

## Done criteria

- [x] `mode.sh` implemented and wired into `repo-conventions/SKILL.md`'s
  `## Argument` + a new workflow section — `repo-conventions/scripts/mode.sh`,
  `repo-conventions/SKILL.md`
- [x] `/repo-conventions mode team` on a solo repo rewrites the Policy
  section to team wording and issues the `PUT .../protection` call —
  `tests/mode.bats` team-mode cases
- [x] `/repo-conventions mode solo` on a team repo reverses both — `tests/mode.bats`
  solo-mode cases
- [x] `/claim` and `/drive`'s existing solo-repo detection heuristic
  continues to match the rewritten doc text unchanged — `tests/mode.bats`'s
  heuristic-match assertions, plus a direct literal-regex check against the
  actual rewritten `dev/guidelines.md` during implementation (no changes
  needed to `claim/SKILL.md` / `drive/SKILL.md` themselves)
- [x] Team mode refuses to enable protection with no CI configured, absent
  an explicit override — `tests/mode.bats`'s `--skip-ci-check` cases
- [ ] (external, manual — left unchecked until performed) the real GitHub
  branch-protection API call actually produces the intended protection
  state, not just the stubbed call shape `tests/mode.bats` asserts on —
  Test plan's disposable-repo manual check. Stubbed tests can't verify
  GitHub's own API accepted the body as intended; this is the one
  criterion that can only be confirmed against the genuine article.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/mode.sh` | new | the mode-switch script (doc rewrite + branch-protection API call) |
| `repo-conventions/SKILL.md` | `## Argument`, `## Workflow` | wire `mode {solo|team}` as a new argument/workflow section |
| `claim/SKILL.md` | `27-33` | the existing solo-mode detection heuristic this script's output must keep matching |
| `drive/SKILL.md` | `114` | the parallel solo-mode description, same heuristic |
| `repo-conventions/templates/guidelines.md` | `11-20` | canonical team wording actually stamped (generic, repo-agnostic — not this repo's own `dev/guidelines.md:11-20`, which hardcodes `../_gh/gh.sh`; see `## Closed`) |
| `address-pr/scripts/pre-merge-check.sh` | `24` | `GH_SH` override seam precedent this script follows |
| `tests/mode.bats` | new | test coverage (stubbed `GH_SH`, no real GitHub calls) |

## Closed (2026-09-23)

- Shipped in **PR #83** (design) and PR #TBD (implementation, this PR).
  `repo-conventions/scripts/mode.sh` (new, 14 BATS tests all green) plus
  `repo-conventions/SKILL.md` wiring (`## Argument` + new `### mode
  {solo|team}` workflow section). Full repo suite 703/703 green.
- Both non-external Done criteria met — script implemented, wired, and
  tested per the design; team-mode CI-check refusal, solo/team doc
  rewrites, and the PUT/DELETE API calls all covered by
  `tests/mode.bats`. The one external/manual Done criterion (real GitHub
  API behavior against a disposable repo) is intentionally left unchecked
  — nothing in this task's scope required mutating a real repo's live
  branch protection to ship it, and doing so from an unattended
  autopilot run isn't a call this session should make unilaterally
  (there is no disposable throwaway repo available here); flagging for a
  human to run manually rather than silently marking it done.
- **Implementation-time correction to the design**: the design's Context
  section claimed the `claim/SKILL.md:28-29` illustrative solo-mode quote
  ("direct-to-`` `main` ``") "already satisfies the detection heuristic by
  construction" — untrue, verified directly: `grep -qi "direct.to.main"`
  does **not** match that literal string, because the backtick between
  the second hyphen and `main` breaks the single-any-char `.` in the
  heuristic regex (confirmed with a live `grep` test before writing the
  canonical solo block). The solo wording this script actually stamps
  drops the backtick around the detection-critical phrase
  (`direct-to-main`, unformatted) specifically so the heuristic matches —
  verified against the real rewritten `dev/guidelines.md` output, not
  just the bats fixtures. `claim/SKILL.md`'s own illustrative quote is
  unaffected (it's prose, never machine-read) but carries the same latent
  mismatch — not fixed here (out of this task's scope; noted for whoever
  next touches that file).
- **Implementation-time correction #2**: the design cited this repo's own
  `dev/guidelines.md:11-20` as the literal team-mode text to stamp, but
  `dev/guidelines.md:11-20` hardcodes `../_gh/gh.sh` (a ccxp-skills-repo-
  specific relative path), which would be wrong when `mode.sh` runs
  against an arbitrary *other* repo. Used the generic
  `repo-conventions/templates/guidelines.md:11-20` wording instead
  (verified identical apart from that one path-specific merge-method
  line) — a design-time oversight caught during implementation, not a
  deviation from what the design actually needed.
- One `tests/task_claim.bats` test (`release-others frees every task held
  by self...`) failed once (exit 141, a SIGPIPE shape) inside a
  full-suite run unrelated to this change (that file/script isn't
  touched by this task); reproduced-clean in isolation, reproduced-clean
  re-running its whole file, and reproduced-clean on a full fresh
  703-test suite rerun — a pre-existing flake, not a regression from this
  PR.
- No follow-up tasks filed — scope stayed within the task's own bounds;
  the two implementation-time corrections above were fixed inline rather
  than deferred.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — `tests/mode.bats`
  written and run first (14 tests, confirmed failing with "command not
  found" / vacuous-exit-code RED against the not-yet-existing script),
  then `mode.sh` implemented to green, then re-verified all 14 pass for
  the intended reason (not just a coincidental non-zero exit) via direct
  content assertions and a manual sanity run against a real
  `dev/guidelines.md` copy
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (72/100 both pre- and post-merge of the design PR),
  shellcheck clean, full 703-test repo suite green (after chasing down
  and ruling out the one-off `task_claim.bats` flake above), doc-impact
  freshness check clean, quality-probe recorded (shellcheck 0/0/0/0)
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; the flaky-test investigation was a direct
  reproduce-in-isolation check, not a hypothesis-driven debugging session
- Receiving code review (`superpowers:receiving-code-review`): yes —
  `/address-pr` §2.d on the design PR (#83), 5 real findings (wrong
  `dev/guidelines.md:11-17` line-range citation — should be 11-20; a
  false "same seam" claim about `quality-probe/scripts/probe.sh`'s
  hardcoded `QP_GH`; no ordering/atomicity guarantee between the doc
  rewrite and the API call; a Test-plan-vs-Done-criteria gap on the
  external manual-verification item; an overstated alternatives-rejected
  argument against any review-count requirement), all fixed, 0 pushback
