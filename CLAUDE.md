# ccxp-skills

Generic, reusable Claude Code skills for the ccxp-family workflow suite
(task lifecycle, PR automation, CI/RCA, retros) plus general-purpose
dev-tool skills (see `README.md`). Split from a private company repo so
any team can adopt it with no company-specific dependency. Also tracks its
own development as tasks: bugs in shared scripts, new skills,
skill-authoring cleanup.

---

## Guidelines

**You MUST read and follow [dev/guidelines.md](dev/guidelines.md) before making any changes.**

**Conventions**: see `/repo-conventions` skill — it defines CLAUDE.md/guidelines.md structure and the dev/ TODO lifecycle. Task/design conventions specifically live in [lifecycle.md](lifecycle.md) (this repo IS the canonical source every consumer repo points back to).

---

## Task Tracking

- **Open tasks**: `dev/TODO/*.md` — one file per task
- **Parked tasks**: `dev/PARKING/*.md` — valid but not actionable now
- **Completed tasks / journal**: `dev/JOURNAL/*.md` — permanent record (the folder IS the index; do NOT mirror it here)
- See [lifecycle.md](lifecycle.md) for task ID format, status flow, and procedures
- **Work about this repo itself** (a bug in `_gh/`, `_session/`, `_taskid/`, `_ipm/`; a new skill; skill-authoring cleanup) belongs here — file directly in `dev/TODO/`
- **Do NOT update CLAUDE.md when journaling** — only when the project's overall structure changes

---

## Context Budget

Auto-loaded files consume the context window. Keep them small.

| File | Max Lines | Max Size | Action if exceeded |
|------|-----------|----------|--------------------|
| `~/CLAUDE.md` | 0 | 0 KB | Should not exist — removed by design |
| Project `CLAUDE.md` | 50 | 3 KB | This file should stay small — details live in TODO/JOURNAL files |
| `dev/guidelines.md` | 200 | 8 KB | Split into separate files |
| Memory files (total) | 100 | 5 KB | Archive stale memories |

**At the start of each session**, check if any file exceeds its cap and warn the user before proceeding.
