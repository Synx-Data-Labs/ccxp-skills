---
status: Open
scheduled: 2026-11-09
estimation: 3
source: follow-up from T20261031-139856 (the /repo skill shipped scan, list, switch; rewiring existing skills was left out of scope)
related: [T20261031-139856, T20261019-174788]
description: make read-only skills root-aware through repo-resolve instead of the script-location default
---

# T20261101-115518: Rewire todo and queue skills to repo-resolve

## Problem

- **Type**: chore
- `/repo` now ships a shared resolver (`_repos/resolve.sh`, `repo-resolve`), but the skills below still assume "the repo is the repo containing cwd" (or the script's own location).
  - `todo/scripts/_lib.sh` derives its root from the script location (`TODO_LIB_REPO_ROOT`), which also breaks for a plugin-cache install.
  - `/top`, `/bottom`, `/stage`, `/new-task` pick queue and task paths from cwd.
  - `/migrate-task` takes an `owner/repo` slug only; it could accept a registry name through `repo-resolve`.
  - `/todo list|next --repo X` (read-only verbs first).
- Out of scope here (owner's picks of 2026-10-31): mutating cross-repo workflows (`/drive`, `/claim`, `/address-pr`, `/gcpr` stay "cwd is the repo"), HUD aggregation, ccxp-agent repo-name resolution (that belongs to T20261019-174788).
- Done when: the read-only `/todo` verbs accept `--repo <name|path>` via `repo-resolve`, `_lib.sh` resolves its root through it with the current behaviour as the default, `/top /bottom /stage /new-task` resolve the root once and keep their default, `/migrate-task` accepts a registry name, each with BATS tests; `resolve.sh` is the only matcher.
