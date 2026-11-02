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

## TLDR

- **Type**: feature
- **Problem**: no skill knows other repos exist; the owner wants `/repo scan|list|switch`.
- **Solution**: new `_repos/` lib (`repos.sh scan|list|resolve`, sourceable `resolve.sh`) plus a thin `repo/SKILL.md`; PR 1 = scan + list + registry + guidelines/README/`in-this-repo.sh`, PR 2 = resolve + switch.
- **Decisions on the five reviewer ambiguities**: see `## Decisions` (all conservative, recorded for review).

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

## Context

- Today everything is "the repo containing cwd"; the only cross-repo lookup is the sibling glob `_taskid/in-this-repo.sh:60-78` (`$parent/*/dev/TODO/*id*.md`, one root only).
- Bash libs live in `_<prefix>/` with a README (`skill-conventions` section 4), are sourceable and function-wrapped (`dev/guidelines.md` Script Standards), and get BATS tests (section 5); `jq` is already a hard dependency of other scripts.
- The registry is a user file under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, same convention as `ccxp-hud.json`; the cache sits in the `state/` dir `claimant-id.sh` already uses. Shipped files carry no user paths (`lint_identifiers.py`).
- `/cd` is not model-invocable, so `/repo switch` can only print the line (verified in the design doc, section 4; not re-verified here).

## Solution

- **Lib `_repos/`** (`README.md`, `repos.sh`, `resolve.sh`), registry `ccxp-repos.json`, cache `state/ccxp-repos.json`, shape as in the task spec above.
  - `repos.sh scan [path] [--depth N] [--all] [--roots a:b]`: for each root, walk children; a child is a repo when it has a `.git` (dir or file) AND a `dev/TODO/` dir (`--all`: `.git` alone).
    - Descent: never into a `.git` folder or symlink or dot folder or `node_modules`; into a plain (non-git) folder only while depth allows. Default cap 2 (= depth 1 plus the `owner/repo` container level); `--depth 1` is strict children only; an explicit `--depth N` is a hard cap.
    - Linked worktree (`.git` file, `gitdir:` has `/worktrees/`): resolved to its main repo via `git rev-parse --git-common-dir`, attached to that record's `worktrees[]` and printed as `repo (wt X)`; main is added when it qualifies. Submodule (`/modules/`): skipped.
    - Registry write keeps `aliases` of unchanged paths; repos under a scanned root are replaced, others kept unless their path vanished; roots remembered only for path/zero-arg scans, not for `--roots` or `CCXP_REPO_ROOTS` (one-call overrides).
    - Prints a table and "N added, M removed, K unchanged"; the only writes are the two user files (atomic temp + `mv`). Local only, no network, no claim, scanned repos are read with `git -C` only.
  - `repos.sh list [--json] [--fresh]`: registry repos whose path still exists, with live fields (branch, dirty via `status --porcelain -uno`, open tasks = `dev/TODO/*.md` minus `queue.md`, top line of `queue.md`); current repo marked `*` (match on repo path or any worktree path); cache reused when younger than 10 min and registry plus every scanned dir mtime unchanged, else recomputed and rewritten. Bare `/repo` = list plus a line for the current repo when it is not registered.
  - `repos.sh paths`: registered repo paths plus a live sibling scan (no writes); `in-this-repo--sibling-path` iterates the union of that and its old glob, so zero-config and a second root both work.
  - PR 2: `repos.sh resolve <query> [--any]` and `resolve.sh` `repo-resolve [--repo X] [--any]` (order: `--repo` > `$CCXP_REPO` > toplevel of `$PWD` > error); tiers exact, prefix, substring, subsequence over `name`, `owner/name`, `aliases` (case-insensitive, deduped by path); exit 0 one hit (path on stdout), 3 ambiguous (candidates on stdout, tab separated), 4 none, 5 refused, 2 usage. `repos.sh switch <query>` prints the `/cd` line (pbcopy when present) or the `cd <path> && claude` fallback.
- **Skill `repo/SKILL.md`** holds only judgment: which verb, the picker on ambiguity (`AskUserQuestion`), the reminder after `/cd`, never claiming a switch, never `cd`/`git checkout`. PR 1 ships `scan` and `list` (the `switch` verb is added in PR 2 so the argument-hint never promises an unbuilt verb).
- **Docs**: "Multi-repo" section in `dev/guidelines.md` and `repo-conventions/templates/guidelines.md`; README skill row + count 51 to 52 (PR 1); `tests.yml` path filters gain `_repos/**`.
- **Alternatives rejected**:
  - Python for the scanner: the suite's libs are bash, and CI/Mac both have bash+jq; rejected for consistency, not capability.
  - Scan-on-every-list: slow with ~80 git repos; the registry plus cache keeps `list` O(registered).
  - Pruning the registry in `list`: a read verb that silently deletes data; rejected.
  - Aggregating tasks into the HUD, deriving per-repo gh accounts, running `/cd` from a mod: out of scope by the owner's picks.

## Decisions

- **`--any`**: only on `resolve`/`repo-resolve`/`repos.sh switch`'s underlying call. It lets a caller (dispatcher, scripts) resolve a path that is a git work tree but not registered or lacks `dev/TODO/`. Without it such a path is refused (exit 5). `/repo switch` never passes it, so an unscanned clone yields "run /repo scan". `scan --all` is the separate flag for listing any git repo.
- **`list` pruning**: `list` never edits the registry; stale paths are omitted from output with a "N stale, run /repo scan" hint. Only `scan` prunes (counted in "M removed").
- **Non-unique prefix**: the first tier with any hit wins and is reported as ambiguous if it has several (picker over that tier's candidates); it never falls through to a wider tier, which would silently widen the guess. Same for a non-unique exact name (two orgs, same folder name).
- **T20261010-274793 overlap**: this task adds only a short "Multi-repo" section (registry, `/repo`, the fresh-clone/detached-job rule stated as a pointer to `drive/SKILL.md` Phase 1.5). It does not restate the cross-repo rule or pick that task's home; whichever lands second adjusts the link. Recorded under Closed.
- **Version gate (Claude 2.1.246)**: `repos.sh switch` reads `claude --version` (override `CCXP_CLAUDE_VERSION` for tests), compares with `sort -V`; at or above 2.1.246 print the `/cd` line, below or undeterminable print `cd <path> && claude`, which works everywhere. Known limit: the installed binary can be newer than the running session; the hint says to use the `cd` line if `/cd` is refused.

## Test plan

- [ ] Unit: `tests/repos.bats` (hermetic temp roots, real linked worktree, a real submodule, `CLAUDE_CONFIG_DIR` pointed at a temp dir) covering marker, depth 1 vs 2, `--all`, aliases round-trip, stale prune, cache reuse/invalidation, no writes into scanned repos.
- [ ] Unit: `tests/repo_resolve.bats` (PR 2): tiers, ambiguity exit, `--repo`/`$CCXP_REPO` order, `--any`, version gate.
- [ ] `tests/taskid_in_this_repo.bats` gains a second-root case; existing cases stay green.
- [ ] Gates: `bats tests/`, `lint_tasks.py`, `lint-docs.sh`, `readme_skill_count.bats`, `skill_score.py --check`, coverage check, `lint_identifiers.py`; some bats fail locally on macOS (BSD `paste` etc.) and are trusted to Linux CI.
- [ ] Post-merge, not verifiable now: the skill reaches users only via a release plus `/ccxp-skills:update`; evals (`skill_eval.py repo --record`) need a live `claude -p` and are run by the maintainer.

## Done criteria

- [ ] Scan rule is `dev/TODO/` only: `tests/repos.bats` "guidelines-only folder is not listed".
- [ ] Depth and owner/repo descent, worktree collapse, submodule skip: `tests/repos.bats` depth and worktree cases.
- [ ] Registry round-trip keeps aliases; cache reuse/invalidation; stale prune: `tests/repos.bats`.
- [ ] `/repo scan` and `/repo list` skill merged (PR 1): `repo/SKILL.md`, `repo/evals/evals.json` (3+ cases incl. `tool_not_called` / `command_not_ran` for `cd` and `git checkout`).
- [ ] Skill score at least 70 and ratchet updated: `dev/quality/skill-scores.json` entry `repo`.
- [ ] Guidelines "Multi-repo" sections, README row and count: `dev/guidelines.md`, `repo-conventions/templates/guidelines.md`, `README.md`, `tests/readme_skill_count.bats`.
- [ ] `in-this-repo.sh` finds repos under a second root: `tests/taskid_in_this_repo.bats` new case.
- [ ] `/repo switch` (PR 2): `tests/repo_resolve.bats`, SKILL.md switch workflow.
- [ ] Version bump and `claude plugin validate .` left to the maintainer's bump PR (external, unchecked on purpose).

## Root cause

- Not a defect: the suite grew single-repo (verified, `_taskid/in-this-repo.sh:60-78` is the only multi-repo read, introduced for T20260626-298293 to diagnose wrong-clone picks; deliberate, scoped to diagnostics).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_taskid/in-this-repo.sh` | 60-78 | sibling glob to reuse `repos.sh paths` |
| `tests/test_helper.bash` | 28-37 | `git_identity` for hermetic fixtures |
| `tests/readme_skill_count.bats` | 6-11 | count must match `*/SKILL.md` |
| `README.md` | 13, 118-130 | count and skill table |
| `.github/workflows/tests.yml` | 5-30 | path filters need `_repos/**` |
| `dev/quality/skill-scores.json`, `dev/quality/skill-coverage-baseline.txt` | whole | ratchet; no new baseline entries allowed |
