---
name: repo
description: Use when the user explicitly asks to list, scan for, find or hop to another repo (switch the session to a sibling repo)
argument-hint: "switch <name> | scan [path] | list"
---

Know which repos exist next to this one. Registry and cache live in the user's config dir; the work is done by bundled scripts.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

All deterministic parts are in `<skills-root>/repo/scripts/repo.sh` (over the `_repos/` lib, tested by `tests/repos.bats`). Keep cwd on the working repo; never `cd` into another repo.

## Argument

- `switch <name>`: resolve a repo by name, `owner/name` or alias and print the `/cd` line for the user to type. It cannot switch for them.
- `scan [path]`: find repos and write the registry. No path: the siblings of the current repo plus every remembered root. Flags: `--depth N`, `--all` (display only), `--roots a:b` (one call).
- `list`: registered repos with branch, dirty state, open-task count and top queue line; the current repo is marked `*`. Bare `/repo` does this.
- Anything else: print this list and stop.

## Workflow: `switch`

1. Run `bash <skills-root>/repo/scripts/repo.sh switch <name>` (quote a name with spaces). Matching is case-insensitive over name, `owner/name` and aliases; the first tier with a hit wins (exact, unique prefix, unique substring, subsequence) and is never widened.
2. Exit 0: show the output as is. Its first line is the command to type (`/cd <path>`, or `cd <path> && claude` when Claude Code is below 2.1.246 or the version is unknown). Say plainly that you cannot run it: `/cd` is not model-invocable, so never claim the session has switched, and never run `cd` or `git checkout` yourself.
3. After a `/cd`, remind the user that earlier conversation assumptions may be about the other repo; the new repo's `CLAUDE.md` and skills load after its trust prompt.
4. Exit 3 (ambiguous): the output lists candidates as `path`, `name`, `slug`, `branch tasks`. Ask with `AskUserQuestion` (at most 4 candidates plus Other), then re-run `switch` with the chosen absolute path.
5. Exit 4 (no match): say so and suggest `/repo scan`. Exit 5 (path not in the registry): suggest `/repo scan`. Exit 6: the registry file is malformed; show the message, do not rewrite the file. Never guess a repo.
6. If the output says "Already in <path>", the user is already there; stop.

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

- `switch` only prints a line for the user. The user types `/cd` themselves; the conversation stays and only the working repo changes.
- Read-only toward every repo: the scripts only read, and you must not run `cd`, `git checkout`, `git fetch` or any claim in another repo.
- Mutating work in a repo other than the one this session started in is never done in-session. Use a fresh clone or a detached job (`/drive` Phase 1.5).
- Every repo is assumed to belong to the same org and GitHub account as the current one; nothing here probes or switches accounts.
- The HUD shows the current repo only; `/repo` data is not aggregated into it.
