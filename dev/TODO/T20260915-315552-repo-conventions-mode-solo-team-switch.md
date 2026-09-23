---
status: Design
estimation: 4h
source: maintainer conversation, 2026-09-15
description: Add `/repo-conventions mode {solo|team}` to toggle a repo's Branch and Merge Policy plus actual GitHub branch protection
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
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
  `## Branch and Merge Policy` (`dev/guidelines.md:11-17`) and its template
  (`repo-conventions/templates/guidelines.md:11-17`) — reuse it exactly,
  don't invent new phrasing.
- No canonical **solo** wording exists yet anywhere in-repo (grepped for
  `"no CI"` outside `SKILL.md` files — zero hits) — `claim/SKILL.md:28-29`'s
  own illustrative quote (*"This is a solo repo with no CI — direct-to-
  `main`, not feature-branch PRs."*) is the closest precedent and is reused
  near-verbatim as the new canonical block, since it already satisfies the
  detection heuristic by construction.
- Existing scripts that call the GitHub API through the repo's `gh`
  wrapper follow one seam consistently — an overridable `GH_SH` variable
  defaulted to the sibling `_gh/gh.sh`, resolved relative to the script's
  own directory (`address-pr/scripts/pre-merge-check.sh:24`,
  `quality-probe/scripts/probe.sh:45`) — this task reuses that seam so
  tests can stub `GH_SH` instead of hitting real GitHub.

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
  4. Rewrite the section: replace everything from the `## Branch and Merge
     Policy` heading line up to (not including) the next `^## ` heading (or
     EOF) with the canonical block for the target mode (team = the exact
     `dev/guidelines.md:11-17` wording; solo = the new canonical block,
     Context above). Python-based in-place edit (same idiom as
     `_ipm/stamp-scheduled.sh`'s frontmatter rewrite), so the replacement is
     line-precise rather than a fragile shell regex.
  5. **`team`**: verify CI is plausibly configured first — `.github/workflows/*.yml`
     must exist in the repo root, else error (unless `--skip-ci-check`,
     for repos whose CI lives outside GitHub Actions). Then:
     `bash "$GH_SH" api -X PUT repos/<owner>/<repo>/branches/main/protection --input -`
     with a body requiring PR-based merges but no named status checks or
     mandatory human approval (`required_status_checks.contexts: []`,
     `required_pull_request_reviews.required_approving_review_count: 0`,
     `enforce_admins: false`, `restrictions: null`) — deliberately loose:
     the goal is "no direct push", not gating on specific check names or
     blocking this suite's own auto-merge tier on a human reviewer.
  6. **`solo`**: `bash "$GH_SH" api -X DELETE repos/<owner>/<repo>/branches/main/protection`
     — tolerate a 404 (no protection existed) as success; anything else
     non-2xx is a real failure, reported and non-zero exit.
  7. `--yes` skips a one-line interactive confirmation before the API
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
  - *Require a minimum approving-review count for team mode* — rejected:
    this suite's whole auto-merge tier (`/address-pr` §3.3,
    `dev/guidelines.md`'s merge method) merges automatically once CI is
    green with no human reviewer in the loop; a required human approval
    would break that tier for every repo that opts into team mode via this
    command, contradicting what "team mode" means *in this specific
    toolset* (CI-gated, not human-review-gated).
  - *Auto-populate `required_status_checks.contexts` from the repo's
    actual workflow job names* — rejected for this pass: job names aren't
    stable across a repo's CI evolution, and a wrong/stale context list
    would silently block merges once a job is renamed; leaving `contexts:
    []` still requires the PR-based-merge property team mode cares about
    without a second thing to keep in sync. Flagged as a natural follow-up
    if a repo wants named-check enforcement.

## Test plan

- [ ] `tests/mode.bats` (new) — `GH_SH` stubbed to a fake script recording
  its invocation args/stdin to a file instead of calling real GitHub:
  - [ ] `solo` on a fresh team-mode fixture doc rewrites the Policy section
    to the solo wording (heuristic now matches "no ci" + "direct.to.main")
  - [ ] `team` on a solo-mode fixture rewrites to the exact
    `dev/guidelines.md:11-17` wording
  - [ ] `team` calls `$GH_SH api -X PUT .../branches/main/protection` with
    the expected JSON body (asserted via the recorded stdin)
  - [ ] `solo` calls `$GH_SH api -X DELETE .../branches/main/protection`
  - [ ] `team` errors (non-zero, no API call recorded) when no
    `.github/workflows/*.yml` exists and `--skip-ci-check` is absent
  - [ ] `team` proceeds (API call recorded) when `--skip-ci-check` is
    passed despite no workflows
  - [ ] requesting the mode already in effect is a no-op: exit 0, doc
    unchanged, no `$GH_SH` invocation recorded
  - [ ] prefers `dev/guidelines.md` over `CLAUDE.md` when both exist and
    only one has the Policy heading
  - [ ] missing Policy heading in either file → non-zero exit, no API call
- [ ] `bats tests/mode.bats` green locally
- [ ] Full repo suite (`tests/*.bats _docs/*.bats`) still green — no
  regressions in unrelated scripts
- [ ] Manual, post-merge (cannot verify pre-merge without mutating a real
  repo's live branch protection): run `/repo-conventions mode team` /
  `mode solo` once against a disposable throwaway GitHub repo and confirm
  via `gh api repos/<owner>/<repo>/branches/main/protection` that the
  actual protection state matches what was requested

## Done criteria

- [ ] `mode.sh` implemented and wired into `repo-conventions/SKILL.md`'s
  `## Argument` + a new workflow section — `repo-conventions/scripts/mode.sh`,
  `repo-conventions/SKILL.md`
- [ ] `/repo-conventions mode team` on a solo repo rewrites the Policy
  section to team wording and issues the `PUT .../protection` call —
  `tests/mode.bats` team-mode cases
- [ ] `/repo-conventions mode solo` on a team repo reverses both — `tests/mode.bats`
  solo-mode cases
- [ ] `/claim` and `/drive`'s existing solo-repo detection heuristic
  continues to match the rewritten doc text unchanged — `tests/mode.bats`'s
  heuristic-match assertions (no changes needed to `claim/SKILL.md` /
  `drive/SKILL.md` themselves)
- [ ] Team mode refuses to enable protection with no CI configured, absent
  an explicit override — `tests/mode.bats`'s `--skip-ci-check` cases

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/mode.sh` | new | the mode-switch script (doc rewrite + branch-protection API call) |
| `repo-conventions/SKILL.md` | `## Argument`, `## Workflow` | wire `mode {solo|team}` as a new argument/workflow section |
| `claim/SKILL.md` | `27-33` | the existing solo-mode detection heuristic this script's output must keep matching |
| `drive/SKILL.md` | `114` | the parallel solo-mode description, same heuristic |
| `dev/guidelines.md` | `11-17` | canonical team wording, reused verbatim |
| `address-pr/scripts/pre-merge-check.sh` | `24` | `GH_SH` override seam precedent this script follows |
| `tests/mode.bats` | new | test coverage (stubbed `GH_SH`, no real GitHub calls) |
