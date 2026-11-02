# `_repos/` — repo registry lib

Multi-repo awareness for the ccxp suite: find the repos on this machine, list them, and (phase 4) resolve a name to a path. Backs the `/repo` skill.

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
