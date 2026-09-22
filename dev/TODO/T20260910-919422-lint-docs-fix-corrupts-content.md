---
status: Coding
estimation: 2h
source: conversation 2026-09-10 (cross-repo, from a downstream consumer-repo session)
description: lint-docs.sh --fix silently corrupts prose and always lints repo-wide despite the docs promising per-file scoping
claimed_by: cc1-9a4074da:94a83ff0e786a885
scheduled: 2026-09-14
claimed_role: interactive
---

# T20260910-919422: lint-docs.sh --fix corrupts prose (+ -> -) and always lints repo-wide despite path args

## TLDR

- **Type**: bug
- **Problem**: `_docs/lint-docs.sh --fix` silently corrupts unrelated pre-existing
  files (a `+` → `-` flip, dropped comma-spacing) because `markdownlint-cli2 --fix`
  always applies the full repo config-glob (`**/*.md`) on top of any path args —
  contradicting several callers' documented "scoped to one file" claims, and none
  of the call sites actually pass a specific path anyway.
- **Solution**: teach `_docs/lint-docs.sh` to pass `--no-globs` (a real,
  empirically-verified `markdownlint-cli2` flag) whenever the caller supplies
  explicit path(s), so CLI args become the sole file-selection mechanism; update
  the callers that know a specific single file (`new-task`, `drive` Phase 7 ×2,
  `gcpr`'s canonical recipe) to actually pass it.

## Problem

- **Type**: bug
- `lint-docs.sh --fix` (`_docs/lint-docs.sh`) is invoked across skills (`new-task`,
  `gcpr`, `/drive` Phase 7) as a "fix-then-continue, never blocks" step meant to
  be scoped to a single file — but two real defects surfaced running it from a
  consumer repo (a downstream skills consumer) on 2026-09-10.
- **Content corruption**: `--fix` (shelling out to `markdownlint-cli2 --fix`)
  rewrote a hard-wrapped prose line that happens to start with a bare `+` into
  `-`, silently changing meaning. CommonMark treats a line-leading `+`
  followed by a space as a lazy-continuation list marker, so this may be
  "correct" markdownlint
  behavior on ambiguous input — but it ran unreviewed against permanent
  JOURNAL records. Three confirmed instances in the consumer repo (reverted
  before that session committed), each a hard-wrapped prose line whose
  continuation happened to begin with a bare `+`:
  - `dev/JOURNAL/<entry-a>.md:66`: "<term> + <term>" → "<term> - <term>".
  - `dev/JOURNAL/<entry-b>.md:~511`: "<identifier> + <term>" → "<identifier> - <term>".
  - `dev/JOURNAL/<entry-c>.md:~584`: "<phrase> + measure" → "<phrase> - measure".
- **Scope mismatch vs. documented caller expectation**: `_docs/lint-docs.sh:25-26`
  explicitly documents that path args "cannot narrow below the config" — the
  full `dev/**/*.md` glob always runs. But `new-task/SKILL.md:89` tells callers
  this bundle step is "scoped to just the file you created, never repo-wide" —
  directly contradicted. The consumer-repo session hit exactly this: linting one
  new task file touched three unrelated pre-existing JOURNAL files.
- **Unexplained PNG rewrite**: the same invocation also rewrote
  a PNG under `dev/JOURNAL/<entry-c>-assets/`
  (480829 → 844873 bytes) — a markdown linter should never touch a binary
  asset. Coincided with the same `lint-docs.sh --fix` call but not yet
  confirmed to share the same code path; needs its own check.
- Impact: any repo using the shared doc-lint bundle risks silent, unreviewed
  corruption of permanent JOURNAL records every time `--fix` runs, since the
  bundle's whole design is fix-then-continue and never surfaces a diff for
  review.
- Workaround used in the consumer-repo session: `git checkout --` on the four
  unintended file changes before committing the actual task file being filed
  there.

## Confirmed recurrence (2026-09-22, lsc-pa repo)

Same failure mode hit again in a second, unrelated consumer repo (`75033us/lsc-pa`,
via `/gcpr`'s doc-lint guard step during an unrelated task-parking commit), with full
concrete (non-redacted) evidence this time:

- **Same `+` → `-` corruption, 5 confirmed instances, 3 files** (all wrapped-continuation
  prose lines beginning with a literal `+` meaning "and/plus", none of them list items):
  - `dev/JOURNAL/T20260714-963726-training-tutorial-md-content.md:33`: `+ PDF)` → `- PDF)`
  - `dev/JOURNAL/T20260905-058581-sunday-0906-service-pptx.md:104`: `+ \`.rels\`)` → `- \`.rels\`)`
  - `dev/JOURNAL/T20260916-807752-sunday-0920-lyrics-mix.md:133,221,234`: three instances,
    same pattern
- **New variant, not previously documented**: dropped the space after a comma in 2 more
  lines (not a `+`/`-` flip, but the same "fix" pass touching content it shouldn't):
  - `dev/JOURNAL/T20260409-655304-skill-reorg.md:14`: `*.lyrics.md,*.service.md` (space
    stripped from `*.lyrics.md, *.service.md`)
  - `dev/JOURNAL/T20260717-493786-highlight-reel-skill.md:108`: `_013.mp4,_014.mp4` (space
    stripped from `_013.mp4, _014.mp4`)
- **Scope-mismatch also reconfirmed**: this run was meant to accompany a single-file
  task-parking commit but touched ~45 unrelated pre-existing `dev/JOURNAL`/`dev/TODO`
  files repo-wide, matching this task's existing "always lints repo-wide" finding.
- **How it was caught this time**: an independent review agent (dispatched per
  `address-pr/SKILL.md` step d, given only the PR diff and no implementation context)
  flagged all 7 corrupted lines by cross-referencing against `origin/main`'s actual
  content — none of it was caught by the tool itself or by the author before review.
  All 7 reverted before merge (`75033us/lsc-pa#29`).
- This confirms the `+` → `-` bug is not a one-off from the 2026-09-10 session — it's
  a real, reproducible defect in `markdownlint-cli2 --fix`'s handling of a leading `+`
  that will keep silently corrupting permanent JOURNAL records in every consumer repo
  until fixed. The comma-spacing drop is a separate, so-far-unexplained observation
  from the same lint pass — not yet confirmed to share a root cause with the `+`/`-`
  flip (comma-spacing normalization isn't a documented markdownlint-cli2/MD004
  behavior); flag it as a second symptom to investigate during the design phase,
  not an established fact.

## Root cause

- `_docs/lint-docs.sh`'s header comment (lines 24-26, introduced in the squashed
  "Initial public release" commit `890c1ce`, 2026-09-13) already documents "path
  args only ADD globs; they cannot narrow below the config" as **deliberate**
  design for CI parity — this half is intentional, not a bug.
- The actual defect: `new-task/SKILL.md:89` (same `890c1ce` commit) claims the
  **opposite** — "scoped to just the file you created, never repo-wide" — which
  was never true. Git history is squashed at the public-release boundary, so
  deliberate-vs-oversight for the false claim specifically can't be traced
  further back, but an accurate technical comment and a contradicting skill-doc
  claim coexisting unreconciled since day one points to oversight — aspirational
  documentation that outran the actual implementation and was never corrected.
- Compounding gap: **every** call site (`ccxp`, `drive` ×2, `gcpr`, `new-task`,
  `retro`, `grill-me` — `git grep -n "lint-docs.sh --fix"`) invokes the bare
  default (`bash ../_docs/lint-docs.sh --fix`, no path argument at all) — so
  even a perfectly-scoping `lint-docs.sh` would change nothing until callers
  that know a specific single file actually pass it.
- **Fix mechanism verified empirically this design phase**, isolated repro under
  `/tmp/lint-scope-test` (a throwaway 2-file tree, one `.markdownlint-cli2.jsonc`
  copied from this repo's real one):
  - Baseline: `markdownlint-cli2 --fix dev/TODO/target.md` → `Finding: dev/TODO/target.md **/*.md` / `Linting: 2 file(s)` — the unrelated `dev/JOURNAL/unrelated.md` gets pulled in by the config's own `globs`.
  - Fix: adding `--no-globs` (documented in `markdownlint-cli2 --help`: "ignores the 'globs' property if present in the top-level options object") to the **same** invocation against the **same** real config → `Finding: dev/TODO/target.md` / `Linting: 1 file(s)` — only the given path, same rule settings (still reads `MD004: {style: dash}` etc. from the real config).
  - A naive alternative (synthesizing a temp config with the `globs` key stripped, no `--no-globs`) was tried first and does **not** work — `markdownlint-cli2` falls back to its own hardcoded `**/*.md` default when no config-level `globs` is present at all, reproducing the same bug. `--no-globs` is the actual mechanism, not "omit the globs key."
- The `+`/`-` corruption itself is a separate, still-live CommonMark ambiguity
  (a line-leading bare `+` is indistinguishable from a lazy-continuation list
  marker) that `--no-globs` scoping does **not** eliminate — it only contains
  the blast radius to the one file actually being touched in the same commit
  (which a normal `git diff` review now catches), instead of silently mutating
  up to 45 unrelated pre-existing JOURNAL files with nothing to review. Fully
  eliminating the `+`/`-` misfire (e.g. reconfiguring MD004) is out of scope
  here — see Done criteria for what this task closes vs. what's a follow-up.

## Solution

- **Core fix — `_docs/lint-docs.sh`**: track whether the caller supplied
  explicit path(s) (before the current default-path substitution) and, when
  they did, add `--no-globs` to the `markdownlint-cli2`/`npx` invocation in
  `_lint_docs_run_tool`. The no-args default-scope path (`dev/JOURNAL
  dev/TODO`, used by the wider pre-commit guards) is unchanged — it still
  wants full CI-parity coverage, not single-file scoping.
- **Alternatives rejected**:
  - *Synthesize a temp config with `globs` stripped* — tried first, doesn't
    work (see Root cause) — `markdownlint-cli2` has its own hardcoded
    `**/*.md` fallback that kicks in regardless.
  - *Reconfigure MD004 to stop treating a leading `+` as a list marker
    repo-wide* — rejected as the primary fix: MD004 correctly enforces list
    style per CommonMark; disabling/weakening it repo-wide risks masking real
    list-formatting issues elsewhere, for a problem that scoping already
    contains to a single, review-able file. Tracked as a separate, smaller
    follow-up rather than bundled here.
  - *Add a post-fix diff-review step instead of scoping* — would still let
    `--fix` mutate 45 unrelated files, just with a diff someone has to
    remember to check; scoping prevents the mutation from happening at all,
    which is strictly safer and doesn't depend on a human noticing.
- **Caller updates** (only sites that know a specific single file at the call
  site — leaving `ccxp`/`retro`/`grill-me`'s bare, potentially-multi-file
  invocations unchanged, out of scope for this task):
  - `new-task/SKILL.md` step 4: pass `dev/TODO/T<id>-<slug>.md` (already
    computed right above the call) instead of the bare invocation — this is
    the specific site whose own prose makes the (currently false) scoping
    claim, so fixing its call is what makes that claim true.
  - `gcpr/SKILL.md`'s canonical recipe (Step 1.5): pass the actual set of
    changed `.md` files from `git status --porcelain` instead of a bare call
    — this is the recipe `new-task` and others explicitly copy/reference, so
    fixing it at the source benefits every future caller, not just this one.
  - `drive/SKILL.md` Phase 7's two close-commit call sites (lines 555, 568):
    each already has a single known path (the task file being closed /
    journal-moved) right there in the same code block — pass it explicitly.
- **New test coverage**: `tests/lint-docs.bats` (doesn't exist yet — this
  script has none) covering: `--no-globs` is added when an explicit path is
  given, omitted for the bare default-scope call, and a scoped `--fix` run
  against a fixture tree with an unrelated dirty file leaves that file
  untouched.

## Test plan

- [ ] `tests/lint-docs.bats` (new file): explicit-path invocation adds
      `--no-globs`; default (no-args) invocation does not; a fixture repro
      (mirroring `/tmp/lint-scope-test`) confirms an unrelated file with a
      fixable violation is left untouched when scoped, touched when not.
- [ ] Manual repro (this design phase, already run): `--no-globs` +
      real `.markdownlint-cli2.jsonc` + explicit path → `Linting: 1 file(s)`,
      unrelated file untouched. (See Root cause for the exact commands.)
- [ ] `new-task/SKILL.md`'s updated call: file a throwaway test task via
      `/new-task`, confirm only that one file is touched by the lint step.
- [ ] `gcpr/SKILL.md`'s updated recipe: stage a commit touching 2 `.md`
      files + 1 unrelated pre-existing `.md` file with a fixable violation,
      run `/gcpr`, confirm the unrelated file is untouched.
- [ ] `bats tests/*.bats` full suite still green (regression check).

## Done criteria

- [ ] `_docs/lint-docs.sh` adds `--no-globs` when given explicit path(s), unchanged for the bare default call — `tests/lint-docs.bats`
- [ ] `new-task/SKILL.md` step 4 passes its specific task-file path instead of a bare call — `new-task/SKILL.md:88-96`
- [ ] `gcpr/SKILL.md`'s canonical recipe (Step 1.5) passes the actual changed `.md` files — `gcpr/SKILL.md:59-63`
- [ ] `drive/SKILL.md`'s two Phase 7 close-commit calls pass their known single path — `drive/SKILL.md:555,568`
- [ ] Full `bats tests/*.bats` suite still green after all of the above — regression check
- [ ] Follow-up tasks filed via `bash ../_taskid/new.sh` for the `+`/`-` MD004 misfire, the comma-spacing drop, and the unconfirmed PNG-mutation report — not fixed in this task; scoping contains blast radius but doesn't eliminate the underlying corruption risk to the one file actually being linted; filed T-ids recorded in Closed at merge

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_docs/lint-docs.sh` | 166-219 | `_lint_docs_run_tool`/`lint_docs_run` — add `--no-globs` when explicit paths given |
| `new-task/SKILL.md` | 88-96 | Falsely claims single-file scoping; fix the call to actually pass the path |
| `gcpr/SKILL.md` | 59-63 | "Canonical recipe" other skills copy — pass actual changed `.md` files |
| `drive/SKILL.md` | 555, 568 | Phase 7 close-commit calls — each knows a single closed-task-file path |
| `tests/lint-docs.bats` | new | No existing coverage for this script at all |
