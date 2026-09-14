---
status: Done
estimation: 2h
source: this conversation, 2026-09-14
related: T20260914-871616
claimed_by:
claimed_role:
scheduled: 2026-09-14
---

# T20260914-384424: Update stale `~/.claude/skills/...` example paths across skill docs

## TLDR

- **Type**: chore
- **Problem**: 44 files still show example invocations like `bash ~/.claude/skills/_taskid/new.sh --check ./dev`, assuming the old symlink-install layout retired by T20260914-871616 (this repo now ships as a Claude Code plugin).
- **Solution**: rewrite each example per audience — skill-relative paths (`../_taskid/new.sh`) for Claude-facing docs, non-copyable "run from this script's directory" prose for human-shell-facing header comments — applied consistently across all 44 hits.

## Problem

- **Type**: chore
- Spotted while closing [[T20260914-871616]] (fixing the two *functionally*
  broken `~/.claude/skills/...` paths — the `_gh/auto-switch.sh` hook and
  `statusLine.command`): 44 other files still show example invocations
  like `bash ~/.claude/skills/_taskid/new.sh --check ./dev`, assuming the
  old symlink-install layout that T20260914-871616 retired.

  ```
  address-pr/scripts/pre-merge-check.sh   claim/SKILL.md
  address-pr/SKILL.md                     cleanup-branch/SKILL.md
  bottom/SKILL.md                         design-score/SKILL.md
  ccxp/scripts/reclaim-sweep-pr.sh        dev/guidelines.md
  ccxp/scripts/update-roadmap.sh          _docs/lint-docs.sh
  ccxp/SKILL.md                           drive/SKILL.md
  gcpr/SKILL.md                           repo-conventions/SKILL.md
  _gh/ci-triage.sh                        repo-conventions/templates/guidelines.md
  _gh/gh.sh                               repo-conventions/templates/task.md
  grill-me/SKILL.md                       retro/SKILL.md
  help-net/SKILL.md                       _session/task-state.sh
  _ipm/current.sh                         slack/scripts/slack-notify.sh
  _ipm/ipm-iteration-drain-check.sh       slack/scripts/slack-send.sh
  journal-compact/SKILL.md                slack/SKILL.md
  lifecycle.md                            stage/SKILL.md
  new-task/SKILL.md                       _taskid/check-orphaned-refs.sh
  proof-read/SKILL.md                     _taskid/in-this-repo.sh
  quality-probe/SKILL.md                  _taskid/new.sh
  rca/SKILL.md                            _taskid/README.md
  README.md                               _taskid/url.sh
  repo-conventions/scripts/lint.sh        todo/SKILL.md
                                           top/SKILL.md
                                           turnstile-spin/README.md
                                           verify-site/scripts/verify.sh
                                           verify-site/SKILL.md
  ```

  (full, current list: `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`)
- **Mostly cosmetic, but NOT uniformly so**: confirmed by inspecting
  `_gh/gh.sh`, `_taskid/new.sh`, `_taskid/in-this-repo.sh`,
  `_session/task-state.sh` — these four resolve their own siblings via
  `dirname "${BASH_SOURCE[0]}"`, not the stale example paths, so nothing
  in them breaks execution.
  **Correction found during implementation**: 5 other files were NOT
  checked before filing and turned out to be genuinely broken —
  `address-pr/scripts/pre-merge-check.sh`, `ccxp/scripts/reclaim-sweep-pr.sh`,
  `ccxp/scripts/update-roadmap.sh`, `verify-site/scripts/verify.sh`, and
  `_ipm/ipm-iteration-drain-check.sh` all literally `bash
  ~/.claude/skills/_gh/gh.sh ...` (or similar) as real executable code, not
  just a doc example — confirmed by running `pre-merge-check.sh` directly
  in this environment and hitting "could not determine repo" from the
  broken path. Fixed as part of this task (same fix shape: resolve the
  sibling via `dirname "${BASH_SOURCE[0]}"`, overridable via an env var for
  tests, per `_taskid/url.sh`'s `TASKID_GH` precedent).
- Done = every hit above shows a path (or invocation form) that resolves
  correctly for a plugin-only install, and a re-run of the grep above
  turns up nothing left to fix (or only intentional exceptions, noted
  inline).

## Plan

- Apply the two conventions from Notes, split by audience, mechanically
  across all 44 files:
  - **Claude-facing** (`*/SKILL.md`, doc prose meant to be read while a
    skill is loaded): rewrite to a path relative to "Base directory for
    this skill" — e.g. `bash ../_taskid/new.sh --check ./dev` — matching
    how the code itself already resolves siblings via
    `dirname "${BASH_SOURCE[0]}"` (`_taskid/in-this-repo.sh:41`,
    `_session/task-state.sh:37`).
  - **Human-shell-facing** (script header usage comments, e.g. some
    `_taskid/*.sh` files): rewrite to "run from this script's own
    directory" prose — no single copyable absolute path is correct across
    every install method (marketplace cache vs. dev checkout).
  - `dev/guidelines.md`, `lifecycle.md`, `README.md`: same Claude-facing
    treatment — these are read inside a loaded-skill or onboarding
    context, not typed cold at a shell.
- Work file-by-file from the Problem section's list, re-running
  `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`
  after each batch to track remaining count.
- **Alternatives rejected**:
  - *Leave the paths as-is, document the new install method elsewhere* —
    rejected: examples are what a reader copies verbatim; T20260914-871616
    shows a stale hardcoded path silently breaking a `SessionStart` hook
    even with correct docs living a few files away.
  - *Introduce a `${CLAUDE_PLUGIN_ROOT}`-style placeholder in doc prose* —
    rejected: that variable is only resolved inside `hooks.json`-style
    plugin manifests (used for `_gh/auto-switch.sh`'s hook wiring per
    T20260914-871616), not inside a skill's own Markdown prose or a
    plain shell script invoked ad hoc — it would just be a new,
    equally-unresolvable placeholder for these files.

## Test plan

- [x] `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`
      returns nothing unexpected (or only intentional exceptions, noted
      inline) — remaining 7 hits, all intentional:
      - `dev/TODO/queue.md` — this task's own title, not an invocation
      - `dev/TODO/T20260914-384424-*.md` (this file) and
        `dev/TODO/T20260914-871616-*.md` — historical/self-referential
        bug-report prose, excluded per `## Notes`
      - `address-pr/scripts/pre-merge-check.sh`,
        `ccxp/scripts/reclaim-sweep-pr.sh`,
        `ccxp/scripts/update-roadmap.sh`,
        `_ipm/ipm-iteration-drain-check.sh` — each hit is this task's own
        new explanatory comment ("not a hardcoded `~/.claude/skills/...`
        path") describing the retired pattern being fixed, not a live
        example
      - `turnstile-spin/README.md` — a CI-synced mirror of an external
        Cloudflare docs page describing a *different* skill's generic
        Claude Code global-skill install, unrelated to ccxp-skills'
        retired plugin-symlink layout; out of scope and would drift from
        its canonical source if hand-edited
- [x] `bash _docs/lint-docs.sh --fix` stays clean on every touched file
      (445 files linted, 0 errors)
- [x] `bash repo-conventions/scripts/lint.sh` stays clean (pre-existing,
      unrelated violation on `T20260914-234656` — confirmed present on
      `main` before this branch, not introduced here)

## Done criteria

- [x] Decide the replacement convention (see Notes/Plan) and apply it
      consistently across all 44 files listed in `## Problem` — plus 5
      more with a genuine functional bug found during implementation, see
      `## Problem`'s correction note.
- [x] `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`
      returns nothing unexpected — see `## Test plan`.
- [x] `bash _docs/lint-docs.sh --fix` and
      `bash repo-conventions/scripts/lint.sh` stay clean on every touched
      file — see `## Test plan`.
- [x] `bats tests/` passes (543/543, including a fix to
      `tests/update_roadmap.bats` needed after `update-roadmap.sh`'s
      hardcoded-path bug fix — see `## Problem`).

## Root cause

- Every hit predates T20260914-234656's switch to Claude Code **plugin**
  distribution (`.claude-plugin/plugin.json`, `"skills": "."`) — when
  these docs/comments were written, `~/.claude/skills/<name>` symlinks
  from `scripts/install.sh` were the only install method, so a literal
  `~/.claude/skills/...` example was correct at the time.
- T20260914-871616 (2026-09-14) fixed the two *functionally* broken
  instances (the `SessionStart` hook and `statusLine.command`, both real
  code paths that executed and failed) but explicitly scoped out the
  remaining ~44 *prose* examples as "worth its own task" — an intentional
  deferral, not an oversight, which is what this task now picks up.
- Some scripts' own sibling resolution (`_taskid/in-this-repo.sh:41`,
  `_session/task-state.sh:37`) already uses `dirname "${BASH_SOURCE[0]}"`,
  not the stale example paths — those are pure documentation fixes. Five
  others (`address-pr/scripts/pre-merge-check.sh`,
  `ccxp/scripts/reclaim-sweep-pr.sh`, `ccxp/scripts/update-roadmap.sh`,
  `verify-site/scripts/verify.sh`, `_ipm/ipm-iteration-drain-check.sh`) were
  NOT yet converted and actually executed the stale absolute path at
  runtime — a real functional bug the original Problem statement missed by
  not checking every file before filing. Fixed with the same
  `dirname "${BASH_SOURCE[0]}"` pattern, with an env-var override seam
  (`GH_SH` / `SKILLS_ROOT`) for test injection.

## Repo file references

| File | Purpose |
|---|---|
| `_taskid/in-this-repo.sh` | sibling-resolution pattern to match in rewritten examples (`dirname "${BASH_SOURCE[0]}"`, line 41) |
| `_session/task-state.sh` | same pattern, line 37 |
| 42 other `*/SKILL.md` / `*.sh` / `*.md` files | listed in full in `## Problem`; each gets one example-path rewrite per `## Plan`'s audience split |

## Notes

- Two candidate replacement conventions, pick one (or mix per context):
  - For a doc example meant to be read by **Claude while the skill is
    loaded**: use a path relative to "Base directory for this skill"
    (the harness prints this on skill load) — e.g.
    `bash ../_taskid/new.sh --check ./dev` instead of
    `bash ~/.claude/skills/_taskid/new.sh --check ./dev` — matching how
    the actual code already resolves siblings.
  - For a comment/example meant for a **human typing at a shell prompt**
    outside a Claude Code session (e.g. some `_taskid/*.sh` header
    comments): there's no single correct path under a plugin install —
    it's version-pinned cache path or a dev checkout path depending on
    how that human installed it. May be better rewritten to say "run
    from this script's own directory" or similar, rather than a copyable
    absolute example.
- Don't touch `dev/TODO/T20260914-871616-*.md` or
  `dev/JOURNAL/*` — those are historical/closed-task records, not living
  docs.

## Closed (2026-09-14)

- Shipped in [ccxp-skills#19](https://github.com/Synx-Data-Labs/ccxp-skills/pull/19).
  CI green (Markdown Lint), `bats tests/` 543/543, design-score gate 81/100.
- All 44 originally-scoped files updated, plus 5 more with a genuine
  functional bug found mid-implementation (see `## Problem`'s correction
  note and `## Root cause`) — `_gh/gh.sh` invoked via a hardcoded
  `~/.claude/skills/...` path at runtime, not just in a doc example.
- 7 intentional exceptions left unchanged, documented in `## Test plan`.
- README.md's "Skill scripts" section (the canonical documented
  convention) updated so future skills don't reintroduce the same
  stale-path pattern.
- quality-probe recorded: 47 files, shellcheck 0 errors/2 warnings (both
  pre-existing on `main`, unrelated to this change)/5 info, design_score
  81 — see `dev/quality/metrics.jsonl`.
- No follow-up tasks filed — the fix is complete and verified.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs/comment-only
  change plus a hardcoded-path bug fix with no new behavior to drive with
  a red test; verified instead via the existing `bats tests/` suite
  (543/543) and a direct functional smoke test of the fixed script.
- Verification (`superpowers:verification-before-completion`): yes — ran
  the full fresh verification pass (grep, bats, design-score, doc-lint,
  shellcheck, functional smoke test) before opening the PR.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; the functional-bug discovery came from directly running
  `pre-merge-check.sh` and reading its one clear error, not trial-and-error.
- Receiving code review (`superpowers:receiving-code-review`): pending —
  not yet reviewed as of this writing; will apply if findings come back
  from `/address-pr`.
