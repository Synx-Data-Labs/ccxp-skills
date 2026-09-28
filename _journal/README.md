# `_journal/` — JOURNAL compaction

Monthly compaction of `dev/JOURNAL/` — collapses last month's individual task-closure files into a single digest, moving originals to `archive/YYYY-MM/` (history preserved via `git mv`).

## Scripts

| Script | Purpose |
|--------|---------|
| `compact.sh <month> --repo-root <dir> [--dry-run]` | Archive all `dev/JOURNAL/*.md` files whose effective month (filename-date, or last-commit-date fallback) equals `<month>` into `archive/<month>/`, and (re)write `dev/JOURNAL/<month>-digest.md` summarizing task closures and other archived files. Idempotent — a second run on an already-compacted month is a no-op. |
