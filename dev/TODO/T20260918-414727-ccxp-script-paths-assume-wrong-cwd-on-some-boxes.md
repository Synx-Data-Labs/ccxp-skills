---
status: Open
estimation: 1h
source: Retro 2026-09-18 (synxdb-build-pipeline) — Phase 4c skill quality review
related: none yet — no existing task covers this
---

# T20260918-414727: `ccxp/SKILL.md`'s relative script paths (`../ccxp/scripts/...`, `../_gh/gh.sh`, etc.) don't resolve from a `/ccxp` session's actual cwd on at least one box

## Problem

- `ccxp/SKILL.md` (and every sibling skill it invokes inline — `_gh/gh.sh`,
  `_session/*.sh`, `_ipm/*.sh`, `_docs/lint-docs.sh`, `_taskid/*.sh`, etc.)
  writes every shell command with a path like `../ccxp/scripts/foo.sh` or
  `bash ../_gh/gh.sh ...` — a relative path that only resolves correctly if
  the session's cwd is *inside a sibling directory of `ccxp` within the
  ccxp-skills checkout* (e.g. `ccxp-skills/todo/` → `../ccxp/scripts/...`
  finds `ccxp-skills/ccxp/scripts/...`).
- On the `synxdb-build-pipeline` cron box (session
  `-home-rocky-crontab-synxdb-build-pipeline`), a `/ccxp` session's actual
  Bash-tool cwd is the **target repo's root**
  (`/home/rocky/crontab/synxdb-build-pipeline`), not anywhere inside the
  `ccxp-skills` checkout. Every `../ccxp/scripts/...` / `../_gh/gh.sh` /
  `../_session/...` reference in the doc resolves to a nonexistent path
  from there (e.g. `../ccxp` → `/home/rocky/crontab/ccxp`, which doesn't
  exist — the real location is `/home/rocky/ccxp-skills/ccxp`).
- **This was already known and worked around, but only in per-session
  memory, never fixed at the source**: a migrated memory file
  (`reference_skills_dir_actual_git_repo_path.md`, originally written in
  the cron clone's now-stale `-home-rocky-focus-synxdb-build-pipeline`
  memory pool, recovered and re-homed by this same retro) already
  documents "pass `--skills-dir /home/rocky/ccxp-skills`" as the
  workaround for Phase 0's sync script specifically — but the underlying
  relative-path assumption is baked into essentially every script
  invocation across the whole `ccxp/SKILL.md` workflow, not just that one
  call, and a memory is a per-clone workaround, not a fix other boxes (or
  a freshly-relocated clone with an empty memory pool, exactly what
  happened today) can benefit from.
- **Cost observed today**: every single script call in a full `/ccxp` run
  (standup, nightly RCA, IPM-adjacent checks, retro) needed the relative
  path manually substituted for an absolute one
  (`/home/rocky/ccxp-skills/<skill>/...`) discovered by trial and error at
  session start, rather than working as documented.

## What "done" looks like

- Determine the actual intended convention: is `../ccxp/scripts/...` meant
  to resolve via a documented symlink or directory-layout convention that
  should exist on every box (and is simply missing/misconfigured on this
  one — in which case the fix is a setup/bootstrap doc, not a script-path
  rewrite)? Or is the doc's relative-path assumption itself wrong for how
  `/ccxp` sessions actually get their cwd set in practice?
- This needs a real design decision before editing anything — hence filed
  as a task, not drafted as a bounded PR (Phase 4c's "when unsure,
  downgrade" guidance). Candidate directions, not yet chosen between:
  1. Document (in `ccxp/SKILL.md`'s Prerequisites, or the README) the
     expected on-disk layout / cwd contract a `/ccxp` session must run
     under, and add a preflight check that fails loudly (not a silent
     "No such file or directory") if it doesn't hold.
  2. Make the scripts self-locating (resolve their own path via
     `$(dirname "${BASH_SOURCE[0]}")`-style logic, or accept an env var
     like `CCXP_SKILLS_ROOT` with a documented resolution order) instead
     of relying on the *caller's* cwd being a sibling directory.
  3. If this box's layout really is the anomaly (every other box's `/ccxp`
     session cwd genuinely does sit inside the ccxp-skills checkout),
     document that setup requirement explicitly so it can be verified/
     fixed on this box instead of worked around per-session.
- Whichever direction is chosen, once fixed: delete the now-redundant
  `reference_skills_dir_actual_git_repo_path.md` memory (Phase 1b's own
  "a hook/script fully replacing a memory's job means the memory itself
  is now redundant" rule) — but only after confirming the fix actually
  covers what that memory was compensating for.
