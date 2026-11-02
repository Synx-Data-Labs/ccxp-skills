---
name: repo
description: Use when the user explicitly asks to list or scan for the repos on this machine, or to find another repo
argument-hint: "scan [path] | list"
---

Know which repos exist next to this one. Registry and cache live in the user's config dir; the work is done by bundled scripts.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

All deterministic parts are in `<skills-root>/repo/scripts/repo.sh` (over the `_repos/` lib, tested by `tests/repos.bats`). Keep cwd on the working repo; never `cd` into another repo.

## Argument

- `scan [path]`: find repos and write the registry. No path: the siblings of the current repo plus every remembered root. Flags: `--depth N`, `--all` (display only), `--roots a:b` (one call).
- `list`: registered repos with branch, dirty state, open-task count and top queue line; the current repo is marked `*`. Bare `/repo` does this.
- `switch <name>` (hop to another repo) is not available yet: say so, show the path from `list`, and let the user `cd` or `/cd` there themselves.
- Anything else: print this list and stop.

## Workflow: `scan`

1. Run `bash <skills-root>/repo/scripts/repo.sh scan [args]` (quote a path that contains spaces) and show the output as is.
2. Exit 2 means nothing to scan (not inside a git repo and no path): ask for a path, do not guess one.
3. Exit 6 means the registry file is malformed: show the message; do not delete or rewrite the file yourself.
4. If the user then wants a repo that is missing from the table, say what makes a folder count (a git repo with a `dev/TODO/` directory) and offer `scan --all` to see every git repo.

## Workflow: `list`

1. Run `bash <skills-root>/repo/scripts/repo.sh list [--json] [--fresh]` and show the output as is.
2. Counts come from a cache up to 10 minutes old; offer `--fresh` when the user doubts a number.
3. If it says the registry is empty or scanned folders changed, suggest `/repo scan`.

## Important Notes

- Read-only toward every repo: the scripts only read, and you must not run `cd`, `git checkout`, `git fetch` or any claim in another repo.
- Mutating work in a repo other than the one this session started in is never done in-session. Use a fresh clone or a detached job (`/drive` Phase 1.5).
- Every repo is assumed to belong to the same org and GitHub account as the current one; nothing here probes or switches accounts.
- The HUD shows the current repo only; `/repo` data is not aggregated into it.
