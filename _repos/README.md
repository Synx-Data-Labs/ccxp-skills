# `_repos/` — repo registry lib

Multi-repo awareness for the ccxp suite: find the repos on this machine, list them, and resolve a name to a path. Backs the `/repo` skill.

Commands are shown relative to the plugin root; skills call them as `<skills-root>/_repos/repos.sh`.

## Surface

- `bash _repos/repos.sh scan [path] [--depth N] [--all] [--roots a:b]`
  - Finds repos and writes the registry and cache; prints a table and "N added, M removed, K unchanged".
  - A repo is a folder with a `.git` (dir or file) and a `dev/TODO/` directory.
  - No path: the siblings of the current repo's main worktree (depth 1) plus every remembered root.
  - Depth: default cap 2 (children plus the `owner/repo` level, only through plain non-git folders); `--depth 1` is children only; `--depth N` is a hard cap.
  - `--all` lists any git repo and is display-only (nothing is written).
  - `--roots a:b` or `CCXP_REPO_ROOTS=a:b` override the roots for one call and are not remembered.
- `bash _repos/repos.sh list [--json] [--fresh]`
  - Reads the registry; adds live fields (branch, dirty, open-task count, top queue line); marks the current repo `*`.
  - Linked worktrees get their own indented rows; stale paths are omitted with a hint (only `scan` prunes).
  - Live fields come from the cache while it is under 10 minutes old and unchanged; `--fresh` recomputes.
- `bash _repos/repos.sh paths`
  - Registered repo roots plus a live depth-1 sibling scan of the current repo; unique, no writes. Used by `_taskid/in-this-repo.sh`.

- `bash _repos/repos.sh resolve [query] [--any]`
  - Prints the absolute path of one repo; sourceable as `repo-resolve [--repo X] [--any]` from `_repos/resolve.sh`.
  - Order: `--repo` > `$CCXP_REPO` > git toplevel of `$PWD` > error. A value starting with `/`, `./`, `../` or `~` is a path; anything else is a name.
  - Names match `name`, `owner/name` and `aliases` case-insensitively; the first tier with a hit wins and is never widened (exact, prefix, substring, subsequence).
  - Paths must be a registered repo (or one of its worktrees or subfolders); `--any` accepts any git work tree. The `$PWD` fallback needs `dev/TODO/` unless `--any`.
  - Exit: 0 one repo | 2 usage or not in a git repo | 3 ambiguous (candidate lines on stdout) | 4 no match | 5 refused | 6 malformed registry.
  - Never mutates and never `cd`s.
- `bash _repos/repos.sh switch <query>`
  - Resolves like above and prints the line for the user to type: `/cd <path>` when Claude Code is 2.1.246 or newer (`claude --version`), otherwise `cd <path> && claude`; copies it with `pbcopy` when present.
  - It cannot switch for the user (`/cd` is not model-invocable) and never changes directory itself.

## Files

- Registry `ccxp-repos.json` under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: `{roots, exclude, repos:[{path, name, slug, aliases}]}`.
  - Hand-edit `aliases` and `exclude` (basename globs); a re-scan keeps them.
  - A malformed file aborts the command with exit 6 and is never overwritten.
- Cache `state/ccxp-repos.json` in the same config dir: live fields, written by `scan` and `list`.
- Both files hold user-specific paths and are never shipped.

## Guarantees

- Scanned repos are only read (`git -C`, `--no-optional-locks`, `core.fsmonitor=false`, `GIT_NO_LAZY_FETCH=1`): no index refresh, no fsmonitor daemon, no lazy fetch; no claims, no network.
- Linked worktrees collapse under their main repo; submodules and symlinks are skipped; scans never descend into a repo.
- All stored and compared paths are physical (`pwd -P`).
- Needs `jq`; works on bash 3.2 (macOS) and Linux.
