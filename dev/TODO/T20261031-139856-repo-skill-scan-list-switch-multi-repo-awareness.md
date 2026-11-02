---
status: Design
estimation: 1
source: owner request 2026-10-27 (multi-repo awareness); open design questions answered by the owner 2026-10-31
related: [T20261019-174788, T20261010-274793]
description: new /repo skill (scan, list, then switch) plus a repo registry, per design doc revision 3 and the owner's picks of 2026-10-31
claimed_by: cc1-ecc09c93:9a9b4bb90ea04632
claimed_role: interactive
scheduled: 2026-10-26
---

# T20261031-139856: /repo skill: scan, list and switch (multi-repo awareness, phases 3-4)

> `<skills-root>` = the plugin root (this repo's top level); substitute the literal path (`skill-conventions` §9).

## Problem

- **Type**: feature
- **Why**:
  - Every skill assumes "the repo is the repo containing cwd"; nothing knows other repos exist.
  - On 2026-10-27 the owner asked for a "/switch" that became `/repo switch|scan|list`.
  - Phase 1 (HUD repo field, ctx colors, READY/WORKING) and phase 2 (`/hud details`) already shipped; no `/repo` skill exists on `origin/main`.
- **Spec** (the design doc is not in this repo; the text below is the spec):
  - Design doc revision 3 plus the owner's picks of 2026-10-31 are authoritative; where a pick differs from the doc, the pick wins.
  - Related: T20261019-174788 (worktree dispatcher; consumes the registry later, phase 5) and T20261010-274793 (cross-repo rule in guidelines; add the "Multi-repo" cross-link).
  - Do not rediscover decisions already made below; surface only new conflicts.

### Owner's picks (2026-10-31, binding)

- **Scan rule**: a folder is a repo when it has a `dev/TODO/` directory (`dev/guidelines.md` alone no longer counts).
  - Depth rule unchanged: depth 1; descend to depth 2 only for `owner/repo` layouts when a folder has no marker; never deeper, never into a found repo.
  - `.git` (dir or file) is still read to classify linked worktrees and to skip submodules; `--all` lists any git repo.
- **gh account**: siblings are assumed to share the current repo's org/account, so use whatever the current repo already uses (its `GH_CONFIG_DIR`/direnv setup).
  - No per-repo account derivation and no `_gh/gh.sh` write-probe in `/repo`.
- **HUD scope**: current repo only (phases 1-2 behaviour); no aggregation of other repos' tasks through the registry, and no HUD change in this task.
- **Mutating work from a non-launch repo in-session**: never; always a fresh clone or a detached job (existing rule stays).
- **GH_CONFIG_DIR after `/cd`**: resolved by the account pick; no verification needed, not an open item.

### Commands and behaviour

- **`/repo scan [path]`** (phase 3a)
  - With a path: scan it. Without: the siblings of the current repo's main worktree (depth 1) plus every root remembered in the registry.
  - Flags: `--depth N`, `--all`; output is a short table plus "N added, M removed, K unchanged", then the registry and cache are written.
  - Linked worktrees (`.git` file whose `gitdir:` contains `/worktrees/`) collapse under their main repo as `repo (wt X)`; submodules (`/modules/`) and symlinks are skipped.
  - Never writes to any scanned repo, never takes a claim, no network.
- **`/repo list`** (phase 3b; bare `/repo` = list plus the current repo)
  - Pure read of registry/cache: name, branch, dirty, open-task count, top queue line; the current repo is marked; `--json` for scripts.
  - Stale paths are dropped with a hint to run `/repo scan`.
- **`/repo switch <name>`** (phase 4, only after 3a/3b are merged)
  - Resolve `<name>` through the shared matcher; print `/cd <abs path>` on its own line (copy with `pbcopy` when present) plus a dim hint "type it yourself; I cannot run it".
  - Matching is case-insensitive over `name`, `owner/name` and `aliases`; the first tier with a hit wins: exact, unique prefix, unique substring, fuzzy subsequence.
  - Ambiguity in a tier: a short picker (`AskUserQuestion`, top 4 plus "Other"); zero hits: say so and suggest `/repo scan`. Never guesses.
  - Below Claude Code 2.1.246 (or `/cd` unknown): print `cd <path> && claude` instead. After `/cd`, remind that earlier conversation assumptions may be about the other repo.
  - It never claims to have switched (`/cd` is not model-invocable) and never runs `cd`/`git checkout` itself.

### Registry and script surface

- **Registry**: `~/.claude/ccxp-repos.json` (honours `CLAUDE_CONFIG_DIR`), shape `{roots: [{path, depth}], exclude: [], repos: [{path, name, slug, aliases}]}`.
  - Hand-edited `aliases` survive a re-scan; `CCXP_REPO_ROOTS=a:b` and `--roots a:b` override for one call; a missing file is zero-config (a bare `/repo scan` bootstraps it).
  - Cache `~/.claude/state/ccxp-repos.json` with live fields; reused when younger than 10 minutes and root mtimes are unchanged.
  - User-specific paths live only in these user files, never in shipped defaults, docs or fixtures (`lint_identifiers.py`).
- **Scripts** in a new `<skills-root>/_repos/` lib with `README.md` (`skill-conventions` §4): `repos.sh scan|list|resolve` and the sourceable, function-wrapped `repo-resolve` (order: explicit `--repo` > `$CCXP_REPO` > toplevel of `$PWD` > error; never mutates, never `cd`).
  - Deterministic logic stays in the scripts; the `/repo` SKILL.md calls them via `<skills-root>/_repos/...` and holds only judgment.

### Out of scope

- HUD changes (repo/branch/account display already shipped; no registry data in the HUD).
- The pending-file bridge and `$.prompt.fill` / `$.command.run('cd')` spike (design doc phase 4b).
- `/repo dispatch`, ccxp-agent repo-name resolution (phase 5; belongs to T20261019-174788).
- Rewiring `todo/scripts/_lib.sh`, `/top /bottom /stage /new-task` roots, `/migrate-task` name resolution, `--repo` for `/todo`; file follow-ups instead.
- Any change to `_gh/gh.sh` account probing; any mutating cross-repo workflow.

### Done looks like

- `/repo scan` and `/repo list` merged first (PR 1), then `/repo switch` (PR 2); each PR small, through the normal branch/PR/CI gates.
- New skill `repo/SKILL.md`: description `Use when the user explicitly asks to list, scan for, find or hop to another repo...`, `argument-hint: "switch <name> | scan [path] | list"`, Argument/Workflow/Important Notes sections, at least 3 evals (`repo/evals/evals.json`, include `tool_not_called` / `command_succeeded` for "never runs `cd` or `git checkout`"), score at least 70 in `skill_score.py` with the ratchet updated.
- `dev/guidelines.md` and `repo-conventions/templates/guidelines.md` gain a short "Multi-repo" section cross-linking T20261010-274793; README skill table and skill count updated.
- `in-this-repo.sh`'s sibling glob reuses `repos.sh` so it also finds repos under a second root.
- Plugin version bump (MINOR, new skill) is a separate maintainer PR; `claude plugin validate .` shows zero warnings. No tags or releases from this task.

### Tests expected

- `tests/repos.bats`: hermetic temp roots (local `user.email`/`user.name` in fixtures) with real linked worktrees and a submodule; marker is `dev/TODO/` only (a folder with just `dev/guidelines.md` is not listed); depth 1 vs depth 2 for `owner/repo` layouts; `--all`; registry round-trip keeps `aliases`; stale path pruned; cache reuse and invalidation; no network, no writes into scanned repos.
- `tests/repo_resolve.bats`: each matcher tier (exact, prefix, substring, fuzzy), ambiguity exits non-zero with candidates, explicit `--repo` and `$CCXP_REPO` order, a path outside the registry is refused unless `--any`.
- Repo gates stay green: `lint_tasks.py`, `lint-docs.sh`, markdownlint, `readme_skill_count.bats`, skill-conventions lint, identifier lint.
