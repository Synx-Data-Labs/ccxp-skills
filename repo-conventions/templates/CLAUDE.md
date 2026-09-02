# {{ repo-name }}

{{ One-paragraph purpose of this repo. }}

---

## Guidelines

**You MUST read and follow [dev/guidelines.md](dev/guidelines.md) before making any changes.**

**Conventions**: see `/repo-conventions` skill — it defines CLAUDE.md/guidelines.md structure and the dev/ TODO lifecycle.

---

## Task Tracking

- **Open tasks**: `dev/TODO/*.md` — one file per task
- **Parked tasks**: `dev/PARKING/*.md` — valid but not actionable now
- **Completed tasks / journal**: `dev/JOURNAL/*.md` — permanent record (the folder IS the index; do NOT mirror it here)
- See [dev/guidelines.md](dev/guidelines.md) **TODO Lifecycle** for task ID format, status flow, and procedures
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
