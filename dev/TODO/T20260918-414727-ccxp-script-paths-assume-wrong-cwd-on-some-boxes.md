---
status: Design
estimation: 1h
source: Retro 2026-09-18 (build-pipeline-repo) — Phase 4c skill quality review
related: none yet — no existing task covers this
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-414727: `ccxp/SKILL.md`'s relative script paths (`../ccxp/scripts/...`, `../_gh/gh.sh`, etc.) don't resolve from a `/ccxp` session's actual cwd on at least one box

## TLDR

- **Type**: bug
- **Problem**: `ccxp/SKILL.md`'s 26 inline script-invocation examples all
  write `../X/Y.sh`, assuming cwd sits inside a sibling directory of
  `ccxp/` within the ccxp-skills checkout — true for this repo's own
  interactive sessions, false for a headless cron session whose cwd is
  the *target* repo instead (observed on the `build-pipeline-repo` cron
  box).
- **Solution**: add one preflight step at the very top of Phase 0 that
  derives the ccxp-skills checkout root from the already-available "Base
  directory for this skill" fact and `cd`s into it before any script
  call — zero changes needed to the other 26 existing `../X/Y.sh`
  examples, since cwd is now guaranteed correct for the whole session.

## Problem

- `ccxp/SKILL.md` (and every sibling skill it invokes inline — `_gh/gh.sh`,
  `_session/*.sh`, `_ipm/*.sh`, `_docs/lint-docs.sh`, `_taskid/*.sh`, etc.)
  writes every shell command with a path like `../ccxp/scripts/foo.sh` or
  `bash ../_gh/gh.sh ...` — a relative path that only resolves correctly if
  the session's cwd is *inside a sibling directory of `ccxp` within the
  ccxp-skills checkout* (e.g. `ccxp-skills/todo/` → `../ccxp/scripts/...`
  finds `ccxp-skills/ccxp/scripts/...`).
- On the `build-pipeline-repo` cron box (session
  `-home-ci-crontab-build-pipeline-repo`), a `/ccxp` session's actual
  Bash-tool cwd is the **target repo's root**
  (`/home/ci/crontab/build-pipeline-repo`), not anywhere inside the
  `ccxp-skills` checkout. Every `../ccxp/scripts/...` / `../_gh/gh.sh` /
  `../_session/...` reference in the doc resolves to a nonexistent path
  from there (e.g. `../ccxp` → `/home/ci/crontab/ccxp`, which doesn't
  exist — the real location is `/home/ci/ccxp-skills/ccxp`).
- **This was already known and worked around, but only in per-session
  memory, never fixed at the source**: a migrated memory file
  (`reference_skills_dir_actual_git_repo_path.md`, originally written in
  the cron clone's now-stale `-home-ci-focus-build-pipeline-repo`
  memory pool, recovered and re-homed by this same retro) already
  documents "pass `--skills-dir /home/ci/ccxp-skills`" as the
  workaround for Phase 0's sync script specifically — but the underlying
  relative-path assumption is baked into essentially every script
  invocation across the whole `ccxp/SKILL.md` workflow, not just that one
  call, and a memory is a per-clone workaround, not a fix other boxes (or
  a freshly-relocated clone with an empty memory pool, exactly what
  happened today) can benefit from.
- **Cost observed today**: every single script call in a full `/ccxp` run
  (standup, nightly RCA, IPM-adjacent checks, retro) needed the relative
  path manually substituted for an absolute one
  (`/home/ci/ccxp-skills/<skill>/...`) discovered by trial and error at
  session start, rather than working as documented.

## Context

- **A fact already available for free at every skill load, unrelated to
  cwd**: when a skill is invoked (via the `Skill` tool, or a slash
  command), the harness reports "Base directory for this skill:
  `<abs-path>/<skillname>`" — this appears in this very session's own
  transcript for every skill invocation this whole conversation. It is
  an **absolute path**, resolved by the harness from wherever the
  ccxp-skills checkout/plugin actually lives on THIS box — completely
  independent of the Bash tool's cwd. For `/ccxp`, that value is always
  `<ccxp-skills-root>/ccxp`.
- **This repo already has precedent for leaning on that fact instead of
  cwd**: `repo-conventions/templates/task.md`'s own scaffold instructs
  "Generate {ID} with `bash _taskid/new.sh --check ./dev`, resolved
  relative to wherever the ccxp-skills plugin is installed (a loaded
  skill's own directory, printed as 'Base directory for this skill' —
  not a hardcoded path)." This task applies the same fact to `ccxp/SKILL.md`
  itself, which currently does not.
- **Scope of the 26 existing relative-path examples**: `grep -c
  '\.\./_gh/\|\.\./_session/\|\.\./_ipm/\|\.\./_docs/\|\.\./_taskid/\|\.\./ccxp/scripts/'
  ccxp/SKILL.md` → 26 occurrences across the file (Phase 0 through the
  roadmap-update step near the end). Each already assumes cwd is *some*
  sibling directory of `ccxp/`, `_gh/`, etc. — they don't need to change
  content at all if that assumption is made TRUE once, up front, rather
  than individually rewritten 26 times.

## Solution

- **Chosen direction: preflight `cd`, not a 26-line rewrite** (a
  synthesis of candidate 1 "fail loudly" + candidate 2 "self-locating" +
  candidate 3's implicit assumption that a *consistent* cwd contract is
  fine, made explicit and derived from a fact the session already has
  rather than left implicit):
  1. Insert one new instruction as the very first thing under
     `## Workflow`, before `### Phase 0: Sync`'s first script call:
     derive `SKILLS_ROOT` as the parent of the "Base directory for this
     skill" value reported when `/ccxp` was loaded (i.e. this exact
     skill's own directory, one level up), then `cd` there before
     anything else runs.
  2. Preflight-verify the derivation with a loud, specific failure — not
     a bare "No such file or directory" from whatever the *first* `../`
     call happens to be: check `[ -x "$SKILLS_ROOT/_gh/gh.sh" ]` and
     error out with the exact `SKILLS_ROOT` value tried and a pointer
     back to the reported Base directory if it doesn't hold.
  3. **Every other `../X/Y.sh` example in the file stays byte-for-byte
     unchanged.** Once cwd is `$SKILLS_ROOT/ccxp` (or any of its direct
     children) for the rest of the session, `../_gh/gh.sh` etc. all
     resolve exactly as written today — this was true for every
     interactive session all along; the fix only makes it true for a
     cron session whose cwd started somewhere else entirely.
- **Alternatives rejected**:
  - *Rewrite all 26 `../X/Y.sh` examples to `$SKILLS_ROOT/X/Y.sh`* —
    rejected: a much larger diff (26 line edits vs. ~10 new lines) for
    the same outcome, and every *future* script-invocation example added
    to this 992-line file would need the same `$SKILLS_ROOT/`-prefix
    discipline remembered and applied by hand — the `cd`-once approach
    makes future additions automatically correct with zero extra
    ceremony.
  - *Document a required on-disk layout/symlink convention instead
    (candidate 3, literally)* — rejected as the primary fix: it would
    require every box's cron wrapper to be reconfigured to match a
    documented contract, whereas deriving `SKILLS_ROOT` from the
    already-reported Base directory works correctly on **any** box
    without per-box setup, by construction.
  - *Env var (`CCXP_SKILLS_ROOT`) as the primary mechanism* — rejected as
    primary (an env var can be unset/stale, and needs a fallback anyway);
    kept as a documented **override** only, since the Base-directory
    derivation already covers the normal case token-free.
- **The stale memory file** (`reference_skills_dir_actual_git_repo_path.md`)
  lives in a *different* box's memory pool (the `build-pipeline-repo`
  cron clone), not accessible from this clone/session — flagged as a
  Done criterion for whoever runs on that box next, not something this
  session can delete directly.

## Test plan

- [ ] Docs-class change (`*.md` only) — no BATS. Verification is markdown
  parse + link check + frontmatter validity, per the Phase 3.0 classifier.
- [ ] `bash design-score/scripts/score.sh` on this task file passes the
  threshold before implementation
- [ ] `npx markdownlint-cli2` on the edited `ccxp/SKILL.md` — 0 errors
- [ ] Manual read-through: every one of the 26 existing `../X/Y.sh`
  examples is confirmed to resolve correctly once `cd`'d into
  `$SKILLS_ROOT/ccxp` (spot-checked against this actual checkout's
  layout, not just asserted)
- [ ] `bash _docs/doc-impact.sh origin/main` clean

## Done criteria

- [ ] New preflight `cd` + loud-failure check added at the top of `##
  Workflow`, before Phase 0's first script call — `ccxp/SKILL.md:66`
- [ ] All 26 existing relative-path examples (`ccxp/SKILL.md:73`
  onward) verified unchanged and still correct under the new cwd
  contract — manual read-through, `test plan` item
- [ ] (left for a human on the `build-pipeline-repo` cron box — this
  session has no access to that box's memory pool) delete the
  now-redundant `reference_skills_dir_actual_git_repo_path.md` memory,
  once that box confirms this fix covers what it was compensating for

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `ccxp/SKILL.md` | `66-68` (new preamble), 26 scattered examples unchanged | the fix target |
| `repo-conventions/templates/task.md` | n/a (prose precedent) | the existing "Base directory for this skill" convention this task extends to `ccxp/SKILL.md` |
