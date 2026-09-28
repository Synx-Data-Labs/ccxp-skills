---
status: Done
estimation: 1h
source: Retro 2026-09-18 (build-pipeline-repo) — Phase 4c skill quality review
related: none yet — no existing task covers this
claimed_by:
claimed_role:
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
- **Solution**: rewrite all 26 sibling-script invocation examples from
  cwd-relative `../X/Y.sh` to an absolute-path placeholder
  (`<skills-root>/X/Y.sh`), resolved once per session from the
  already-available "Base directory for this skill" fact — and leave
  cwd untouched (still the *working/target* repo) for the many other
  commands in the same file (`dev/TODO/*.md`, `dev/JOURNAL/...`,
  `git log`, `$(pwd)/dev`) that need exactly that. A single persistent
  `cd` into the skills checkout was the first draft of this design and
  was rejected after review — see Alternatives rejected below — for
  colliding with those working-repo-relative commands.

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

- **Two constraints that must BOTH hold — the design's first draft
  satisfied only one of them (caught in review, see Alternatives
  rejected)**:
  1. The 26 sibling-script calls (`../_gh/gh.sh` etc.) need cwd — or an
     absolute path standing in for it — to resolve into the
     **ccxp-skills checkout**, wherever it's installed on this box.
  2. The rest of `ccxp/SKILL.md` — `dev/TODO/*.md` (e.g. `ccxp/SKILL.md:585`),
     `dev/JOURNAL/YYYY-MM-DD-...` (`:159`, `:294`), `git log` (`:118`),
     `$(pwd)/dev` (`:379`) — needs cwd to stay the **working/target
     repo**, completely independent of where ccxp-skills lives. A
     single persistent `cd` into the skills checkout satisfies (1) but
     breaks (2) outright; there is no cwd value that satisfies both at
     once, so the fix cannot rely on cwd for the sibling-script calls at
     all.
- **Mechanism check (this is an agent-instruction, not a self-contained
  bash script)**: "Base directory for this skill" is text the harness
  reports into **the agent's own context** at skill-load time — not an
  environment variable, not a file, nothing a `bash -c '...'` subprocess
  can introspect on its own, and (per this harness's own documented
  behavior) exported shell state does not even persist between separate
  Bash-tool calls in the same session, only cwd does. So there is no
  shell-level `$SKILLS_ROOT` to lean on either way — the fix has to be:
  the agent reads the reported Base-directory value once, and **writes
  that literal absolute path into each command that needs it**, every
  time it composes one. This matches the identical, already-established
  pattern at `repo-conventions/templates/task.md` (prose telling the
  agent what fact to substitute, not a shell snippet that resolves
  itself).
- **Chosen direction: absolute-path placeholder on all 26 sibling-script
  examples, cwd left untouched**:
  1. Add one new paragraph at the very top of `## Workflow`, before
     `### Phase 0: Sync`: "Every `<skills-root>/X/Y.sh` reference below
     means: take the 'Base directory for this skill' value reported
     when this skill loaded (e.g. `/home/ci/ccxp-skills/ccxp`), drop the
     trailing `/ccxp`, and substitute that literal absolute path — never
     run these cwd-relative, and never `cd` into it; cwd must stay the
     working/target repo throughout, for the `dev/TODO/`,
     `dev/JOURNAL/`, and `git log` commands elsewhere in this document."
  2. Rewrite each of the 26 occurrences from `../X/Y.sh` to
     `<skills-root>/X/Y.sh` (mechanical, same substitution each time —
     confirm the count is still 26 post-rewrite, i.e. a 1:1 replacement,
     nothing added or dropped).
  3. Preflight-verify once, early, with a loud and specific failure —
     not a bare "No such file or directory" from whichever call happens
     to run first: before Phase 0's first sibling-script call, check
     that the substituted path is real, e.g.
     `[ -x "<skills-root>/_gh/gh.sh" ] || { echo "ccxp: <skills-root> ($(the literal path)) doesn't look like a ccxp-skills checkout — check the Base directory reported above" >&2; exit 1; }`
     — spelled out as agent guidance (substitute the literal path both
     places), not a code block with an unresolvable variable.
  4. Everything else in the file — every `dev/TODO/*.md`,
     `dev/JOURNAL/...`, `git log`, `$(pwd)/dev` reference — is left
     **completely unchanged**; cwd for those was never the problem.
- **Alternatives rejected**:
  - *Single persistent `cd` into the skills checkout at the top of the
    session (the original chosen direction, before review)* — rejected:
    review caught that it satisfies the sibling-script calls only by
    breaking every one of the file's OWN working-repo-relative commands
    (`dev/TODO/*.md`, `dev/JOURNAL/...`, `git log`, `$(pwd)/dev` — see
    the two-constraints bullet above). A `pushd`/`popd` or per-call
    subshell `cd` (e.g. `(cd <skills-root> && bash X/Y.sh ...)`) was
    considered as a way to keep a `cd`-based mechanism without the
    permanent-relocation problem, but it's no simpler than the chosen
    absolute-path rewrite and still needs the exact same literal-path
    substitution discipline — no real advantage over just writing the
    absolute path directly.
  - *Document a required on-disk layout/symlink convention instead
    (candidate 3, literally)* — rejected as the primary fix: it would
    require every box's cron wrapper to be reconfigured to match a
    documented contract, whereas deriving the absolute path from the
    already-reported Base directory works correctly on **any** box
    without per-box setup, by construction.
  - *Env var (`CCXP_SKILLS_ROOT`) as the primary mechanism* — rejected as
    primary (an env var can be unset/stale, and needs a fallback anyway;
    also does not persist between separate Bash-tool calls in this
    harness regardless); kept as a documented **override** the agent may
    consult first, since the Base-directory derivation already covers
    the normal case token-free.
- **Unverified assumption, flagged not silently assumed** (review
  finding #3): this design confirms "Base directory for this skill" is
  reported in *this* interactive session's transcript, but does not
  confirm the harness emits the identical fact under the actual cron
  invocation shape (`claude --dangerously-skip-permissions -p /ccxp`,
  per `dev/daily-ccxp.sh`) that motivated this task. Left as an explicit
  post-merge verification item (see Test plan / Done criteria) rather
  than assumed to just work.
- **The stale memory file** (`reference_skills_dir_actual_git_repo_path.md`)
  lives in a *different* box's memory pool (the `build-pipeline-repo`
  cron clone), not accessible from this clone/session — flagged as a
  Done criterion for whoever runs on that box next, not something this
  session can delete directly.

## Test plan

- [x] Docs-class change (`*.md` only) — no BATS. Verification is markdown
  parse + link check + frontmatter validity, per the Phase 3.0 classifier.
- [x] `bash design-score/scripts/score.sh` on this task file passes the
  threshold before implementation (72/100)
- [x] `npx markdownlint-cli2` on the edited `ccxp/SKILL.md` — 0 errors
- [x] `grep -c '\.\./_gh/\|\.\./_session/\|\.\./_ipm/\|\.\./_docs/\|\.\./_taskid/\|\.\./ccxp/scripts/' ccxp/SKILL.md`
  is 0 after the rewrite — but this exact grep pattern missed a 27th
  sibling-script reference (`../slack/scripts/slack-send.sh`, not in
  any of the 6 prefixes it checked); caught by the implementation PR's
  independent review, not by this check. Fixed alongside; broader
  `grep -n '\.\./'` re-run afterward found nothing further to convert
  (the 2 remaining hits, `../todo/SKILL.md` and
  `../repo-conventions/scripts/lint_tasks.py`, are prose
  cross-references / another script's own internal default, never
  executed as commands in this file — correctly left as-is).
  `grep -c '<skills-root>/'` now reads 29 = 27 converted + 2 in the
  preamble itself.
- [x] Manual read-through: every `dev/TODO/*.md`, `dev/JOURNAL/...`,
  `git log`, `$(pwd)/dev` reference elsewhere in the file is confirmed
  **unedited** — diffed each touched line individually (e.g.
  `ccxp/SKILL.md:396`'s `$(pwd)/dev` argument survives byte-for-byte;
  only the preceding `../_session/attribution.sh` substring changed)
- [x] `bash _docs/doc-impact.sh origin/main` — flagged 8 skills
  referencing `queue.md` (routine noise from removing this task's own
  closed-task line from `queue.md`, not a schema/convention change);
  reviewed, no doc change needed
- [ ] (external, post-merge, left unchecked until performed) confirm
  "Base directory for this skill" is reported identically under the
  actual cron invocation shape (`claude --dangerously-skip-permissions
  -p /ccxp`, per `dev/daily-ccxp.sh`), not just this interactive
  session — the one assumption this design cannot verify from here

## Done criteria

- [x] New top-of-`## Workflow` paragraph explaining the
  `<skills-root>/X/Y.sh` placeholder convention and the loud preflight
  check — `ccxp/SKILL.md:68-83`
- [x] All 26 sibling-script examples rewritten from `../X/Y.sh` to
  `<skills-root>/X/Y.sh` — `grep -c` count in Test plan
- [x] Every working-repo-relative command elsewhere in the file
  (`dev/TODO/*.md`, `dev/JOURNAL/...`, `git log`, `$(pwd)/dev`) verified
  unchanged — manual read-through, Test plan item
- [ ] (left for a human on the `build-pipeline-repo` cron box — this
  session has no access to that box's memory pool) delete the
  now-redundant `reference_skills_dir_actual_git_repo_path.md` memory,
  once that box confirms this fix covers what it was compensating for

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `ccxp/SKILL.md` | `68-84` (new preamble), 27 rewritten sibling-script examples, all other lines unchanged | the fix target |
| `repo-conventions/templates/task.md` | n/a (prose precedent) | the existing "Base directory for this skill" convention this task extends to `ccxp/SKILL.md` |
| `dev/daily-ccxp.sh` | n/a | the actual cron invocation shape the Test plan's unverified item needs to be checked against |

## Closed (2026-09-23)

- Shipped in **PR #88** (design) and **PR #89** (implementation, this
  PR). Added a new preamble paragraph at `ccxp/SKILL.md:68-84` defining
  the `<skills-root>/X/Y.sh` placeholder convention plus a loud
  preflight check, and mechanically rewrote sibling-script invocation
  examples from `../X/Y.sh` to `<skills-root>/X/Y.sh`
  (`grep -c '<skills-root>/' ccxp/SKILL.md` → 29 = 27 rewritten + 2 in
  the preamble itself).
- **PR #89 review round (1 real finding, fixed)**: the implementation's
  own verification grep (the same 6-prefix pattern the design specified)
  missed a 27th sibling-script reference —
  `../slack/scripts/slack-send.sh` (`ccxp/SKILL.md:460`), a call to a
  different top-level skill directory (`slack/`) the original grep
  pattern never listed. Caught by independent review, not by the check
  itself — a real gap in the design's own verification method, not just
  the implementation. Fixed inline; a broader `grep -n '\.\./'` re-run
  afterward confirmed nothing else was missed (2 remaining hits are
  prose cross-references / another script's own default, never executed
  as commands here — correctly left alone). Also softened one overclaim
  the same review caught: the preamble said cwd stays the working repo
  "throughout this entire session" — not quite true, since 2a.5b's
  ephemeral roadmap clone (`ccxp/SKILL.md:850-851`) deliberately `cd`s
  into its own throwaway directory for that one phase; added an explicit
  carve-out rather than leave the overclaim standing.
- Every working-repo-relative command elsewhere in the file
  (`dev/TODO/*.md`, `dev/JOURNAL/...`, `git log`, `$(pwd)/dev`) verified
  byte-for-byte unchanged by diffing each touched line individually —
  the design's own review-caught flaw (a naive permanent `cd` would
  have broken these) does not apply to the shipped fix.
- **The design itself went through one substantive correction before
  implementation** (documented in the task's `## Solution` /
  Alternatives rejected): the first-draft "cd once into the skills
  checkout" direction was replaced with the absolute-path-placeholder
  rewrite after independent review caught that a permanent `cd` would
  break the file's own majority use of working-repo-relative commands —
  see the design PR (#88) review thread for the full finding.
- Both non-external Done criteria met. The one external Done criterion
  (verifying "Base directory for this skill" is reported identically
  under the real cron invocation shape, `claude
  --dangerously-skip-permissions -p /ccxp` per `dev/daily-ccxp.sh`) is
  intentionally left unchecked — this session cannot invoke that exact
  cron shape from here to confirm it; flagged for whoever next runs
  `/ccxp` on the `build-pipeline-repo` cron box to confirm.
- **Not done here, left for that same box**: deleting the now-redundant
  `reference_skills_dir_actual_git_repo_path.md` memory — it lives in a
  different box's memory pool, inaccessible from this clone.
- No new follow-up tasks filed — scope stayed within the design's own
  corrected bounds.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class change
  (`*.md` only), no BATS coverage applies per the Phase 3.0 classifier
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (73/100 pre-review-fix, 72/100 post-fix — the
  correction added prose that slightly shifted C5's mapping ratio, still
  well above the 70 threshold both times), markdownlint clean on both
  the task file and `ccxp/SKILL.md`, `doc-impact.sh` clean, a line-by-
  line diff review confirming the rewrite touched exactly the intended
  lines and nothing else — this self-verification still missed the
  `../slack/...` gap the independent reviewer caught, a useful reminder
  that "I checked" and "an independent pass checked" aren't
  interchangeable
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; the design correction was a direct response to a specific,
  well-localized review finding, not an open-ended debugging session
- Receiving code review (`superpowers:receiving-code-review`): yes —
  `/address-pr` §2.d on both the design PR (#88) and the implementation
  PR (#89). Design PR: 3 real findings (a permanent `cd` would break
  the file's own working-repo-relative commands elsewhere; the "Base
  directory for this skill" fact isn't shell-mechanically usable
  without the agent substituting it manually; the design's
  cron-invocation assumption was unverified), 2 fixed via a substantive
  redesign, 1 flagged honestly as an unverified, post-merge item.
  Implementation PR: 2 real findings (a missed 27th sibling-script
  reference outside the verification grep's 6 prefixes; an overclaim
  about cwd staying fixed for the "entire session" when 2a.5b
  deliberately `cd`s elsewhere), both fixed. 0 pushback across both
  rounds — every finding was correct.
