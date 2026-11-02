---
status: In Progress
estimation: 3
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
- **Decisions**: the five reviewer ambiguities plus the marker and quoting choices are in `## Decisions` (all conservative, recorded for review).

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

- **Lib `_repos/`** (`README.md` and `repos.sh` in PR 1; `resolve.sh` and the `source` line in `repos.sh` land in PR 2, where it becomes the single source of truth for matching), registry `ccxp-repos.json`, cache `state/ccxp-repos.json`, both under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` (tests point only `CLAUDE_CONFIG_DIR` at a temp dir).
  - Surface: `repos.sh scan|list|paths` (PR 1) and `resolve|switch` (PR 2); the spec's `scan|list|resolve` plus two helpers.
  - Paths: every stored or compared path is physical (`pwd -P`; git toplevels already are) and lists are deduped by path.
- **`scan [path] [--depth N] [--all] [--roots a:b]`**
  - A child folder is a repo when it has `.git` AND `dev/TODO/`; `--all` drops the marker and is display-only (prints the table, writes nothing, so the registry stays "ccxp repos").
  - Descent: never into a git folder, a symlink (counted in the output as "K symlink(s) skipped"), a dot folder or `node_modules`; plain folders only while depth allows. Default cap 2 (children plus the `owner/repo` level); `--depth 1` is children only; explicit `--depth N` is a hard cap. A root that is itself a repo counts as one repo; outside any git repo with no path and no remembered root it exits 2 with a hint (tested: "scan with nothing to scan exits 2").
  - Classification reads the `.git` entry: dir = main; file whose `gitdir:` matches `*/.git/worktrees/*` = linked worktree; `*/.git/modules/*` = submodule, always skipped (it can only be met when a submodule folder is itself given as the root, since scans never descend into repos); a root that is a main repo counts as one repo; anything else skipped. A worktree resolves to its main via `--git-common-dir` (its basename must equal `.git`; the main path is its dirname, so bare and `--separate-git-dir` layouts are skipped); main is added when it qualifies, even from outside the root.
  - Registry: `{roots, exclude, repos:[{path,name,slug,aliases}]}`; `exclude` is a list of basename globs; slug is `owner/repo` from `origin` (any URL form, ssh aliases included). Aliases are keyed by path (a moved clone loses them: documented). Repos under a scanned root are replaced, others kept while their folder exists; roots are remembered for path and zero-arg scans only, not for `--roots`/`CCXP_REPO_ROOTS`.
  - A malformed registry aborts (exit 6) and is never overwritten. Writes are atomic (temp + `mv`), last writer wins, no lock.
  - Depth values: a path scan stores its effective cap (default 2); the zero-arg sibling root is stored with depth 1; stored depths are reused as given on later zero-arg scans (tested).
  - Output: rows `+`/`-`/`=` with `repo (wt X)` rows for linked worktrees (from `git worktree list --porcelain`, missing folders dropped each run), then "N added, M removed, K unchanged".
- **`list [--json] [--fresh]`**
  - Never writes into any repo: it uses `git --no-optional-locks status --porcelain -uno`, so no `index.lock`; it may refresh the cache file.
  - Fields: branch, dirty, open tasks (`dev/TODO/T*.md` count), top queue line (first `- [T` item of `queue.md`, struck-through items skipped); worktrees listed as their own rows with their own branch and dirty state (claims are per path).
  - Cache is reused for 10 minutes while the registry and every scanned dir (roots and `owner/` containers) are unchanged; branch, dirty and task changes are NOT detected before the TTL, so a row can lag up to 10 minutes and `--fresh` forces a recompute. Changed scanned dirs print a "run /repo scan" hint.
  - The current repo (physical toplevel of `$PWD`) is marked `*` on the exact row; an unregistered current repo is shown on its own line. Stale paths are omitted with a hint and left in the registry.
- **`paths`**: registered repo roots that exist plus a live depth-1 sibling scan of the current repo; main repo paths only (never worktrees), deduped, no writes. `in-this-repo--sibling-path` skips both `$PWD` and the main-worktree toplevel of `$PWD` (a linked worktree must not report its own main as another clone), then iterates the deduped union of that and its old glob (zero-config keeps working, a second root is found) and falls back to the old glob alone when `jq` or `repos.sh` is unavailable.
- **PR 2 resolve**: `repo-resolve [--repo X] [--any]`, order `--repo` > `$CCXP_REPO` > toplevel of `$PWD` > error (exit 2 when `$PWD` is not in a git repo; tested).

  | Input | Meaning | Rule |
  |---|---|---|
  | `--repo`/`$CCXP_REPO` starting with `/`, `./`, `../` or `~` | path | must be a registered repo, or a linked worktree of one (checked with `git worktree list` of the registered mains), else exit 5 unless `--any` |
  | `--repo`/`$CCXP_REPO` otherwise (`name`, `owner/name`, alias) | name | tier matcher over the registry; never read as a folder, so `--repo todo` cannot hit a skill folder |
  | `$PWD` toplevel fallback | path | needs `dev/TODO/` (registration not required, so a dispatcher in an unscanned repo works), else exit 5 unless `--any` |

  - Tiers exact, prefix, substring, subsequence over `name`, `owner/name`, `aliases` (case-insensitive, deduped by path). Exit 0 one hit (path on stdout), 3 ambiguous (tab-separated candidates, sorted by name then path so the picker order is deterministic), 4 none, 5 refused, 6 malformed registry (also from `scan` and `list`), 2 usage.
  - `repos.sh switch <query>` prints the `/cd` line (`pbcopy` when present) or the fallback; the `/cd` line prints the path verbatim, in double quotes only when it contains whitespace (the quoting `/cd` accepts is assumed, not verified); the `cd` fallback line uses `printf %q` escaping and a path with whitespace always gets both lines; the version gate compares dot-separated integers in bash (no `sort -V`) against the first `N.N.N` in `claude --version`.
- **Skill `repo/SKILL.md`** holds only judgment: which verb, the picker on ambiguity (`AskUserQuestion`), the reminder after `/cd`, never claiming a switch, never `cd`/`git checkout`. PR 1 ships `scan` and `list` (the `switch` verb is added in PR 2 so the argument-hint never promises an unbuilt verb).
- **Docs**: "Multi-repo" section in `dev/guidelines.md` and `repo-conventions/templates/guidelines.md`; README skill row + count 51 to 52 (PR 1); `tests.yml` path filters gain `_repos/**`.
- **Alternatives rejected**:
  - Python for the scanner: the suite's libs are bash, and CI/Mac both have bash+jq; rejected for consistency, not capability.
  - Scan-on-every-list: slow with ~80 git repos; the registry plus cache keeps `list` O(registered).
  - Pruning the registry in `list`: a read verb that silently deletes data; rejected.
  - Aggregating tasks into the HUD, deriving per-repo gh accounts, running `/cd` from a mod: out of scope by the owner's picks.

## Decisions

- **Repo marker**: `.git` AND `dev/TODO/` (a plain folder with `dev/TODO/` but no git is not a repo for worktree/slug/branch purposes; the owner's rule names the marker, `.git` is only needed to classify worktrees and submodules).
- **`--any`**: only on `resolve`/`repo-resolve` (table in Solution). It lets a caller (dispatcher, scripts) resolve a path that is a git work tree but not registered or lacks `dev/TODO/`. Without it such a path is refused (exit 5). `/repo switch` never passes it, so an unscanned clone yields "run /repo scan". `scan --all` is the separate, display-only flag for listing any git repo (nothing persisted, so a later plain scan cannot silently prune it).
- **`list` pruning**: `list` never edits the registry (it may refresh the cache) and never writes into a repo; stale paths are omitted from output with a "N stale, run /repo scan" hint. Only `scan` prunes (counted in "M removed").
- **Non-unique prefix**: the first tier with any hit wins and is reported as ambiguous if it has several (picker over that tier's candidates); it never falls through to a wider tier, which would silently widen the guess. Same for a non-unique exact name (two orgs, same folder name).
- **T20261010-274793 overlap**: this task adds only a short "Multi-repo" section (registry, `/repo`, the fresh-clone/detached-job rule stated as a pointer to `drive/SKILL.md` Phase 1.5). It does not restate the cross-repo rule or pick that task's home; whichever lands second adjusts the link. Recorded in the Closed section at close.
- **Version gate (Claude 2.1.246)**: `repos.sh switch` reads `claude --version` (override `CCXP_CLAUDE_VERSION` for tests), compares dot-separated integers in bash; at or above 2.1.246 print the `/cd` line, below or undeterminable print `cd <path> && claude`, which works everywhere. Known limit: the installed binary can be newer than the running session; the hint says to use the `cd` line if `/cd` is refused.

## Test plan

- [ ] Unit: `tests/repos.bats` (hermetic temp roots, real linked worktree, a real submodule given as a root, `CLAUDE_CONFIG_DIR` pointed at a temp dir, macOS-run locally and on Linux CI; mtimes are set explicitly with `touch -t`, the form BSD and GNU share, and read through `repos-mtime`, `stat -c %Y` then `stat -f %m`) with titled cases: "guidelines-only folder is not listed", "depth 1 vs owner/repo depth 2", "never descends into a repo or symlink", "linked worktree collapses under main", "submodule root is skipped", "--all is display-only", "aliases survive rescan", "stale path pruned by scan, omitted by list", "malformed registry is not overwritten", "cache reused then invalidated (registry, dir mtime, --fresh)", "zero-arg scan stores the sibling root with depth 1", "path with spaces", "list does not change .git (snapshot)", "list shows fields and marks the current repo", "list --json", "queue top skips struck-through", "worktree has its own row", "--roots is not remembered", "exclude glob", "scan with nothing to scan exits 2", "paths lists registry plus siblings, no worktrees".
- [ ] Unit: `tests/repo_resolve.bats` (PR 2): "tier exact/prefix/substring/subsequence", "owner/name is a name, not a path", "bare name never read as a folder", "malformed registry exits 6", "worktree path accepted via git worktree list", "ambiguous prefix exits 3 with candidates", "--repo then CCXP_REPO then PWD order", "unregistered path refused, --any accepts", "version gate below/at/unknown".
- [ ] `tests/taskid_in_this_repo.bats` gains "finds a repo under a second root via the registry", "falls back to the peer-dir glob when repos.sh is broken" and "does not report its own main repo from a linked worktree"; existing cases stay green (their setup isolates `CLAUDE_CONFIG_DIR`).
- [ ] Gates: `bats tests/`, `lint_tasks.py`, `lint-docs.sh`, `readme_skill_count.bats`, `skill_score.py --check` and coverage check, `lint_identifiers.py`; new bats files must pass on macOS locally, older failures from BSD tools are trusted to Linux CI.
- [ ] Post-merge, not verifiable now: the skill reaches users only via a release plus `/ccxp-skills:update`; evals (`skill_eval.py repo --record`) need a live `claude -p` and are run by the maintainer.

## Done criteria

- [ ] Scan rule is `dev/TODO/` only: `tests/repos.bats` "guidelines-only folder is not listed".
- [ ] Depth and owner/repo descent, worktree collapse, submodule skip: `tests/repos.bats` "depth 1 vs owner/repo depth 2", "linked worktree collapses under main", "submodule root is skipped".
- [ ] Registry round-trip keeps aliases; cache reuse/invalidation; stale prune: `tests/repos.bats` "aliases survive rescan", "cache reused then invalidated", "stale path pruned by scan, omitted by list", "list does not change .git".
- [ ] Scan never descends into a repo or symlink, `--all` writes nothing, a malformed registry is not overwritten: `tests/repos.bats` "never descends into a repo or symlink", "--all is display-only", "malformed registry is not overwritten".
- [ ] `/repo list` fields, current marker, JSON, worktree rows: `tests/repos.bats` "list shows fields and marks the current repo", "list --json", "queue top skips struck-through", "worktree has its own row".
- [ ] `--roots` one-call override and `exclude` globs: `tests/repos.bats` "--roots is not remembered", "exclude glob".
- [ ] CI runs the new tests and the lib is documented: `.github/workflows/tests.yml` path filter `_repos/**`, `_repos/README.md`.
- [ ] `/repo scan` and `/repo list` skill merged (PR 1): `repo/SKILL.md`, `repo/evals/evals.json` (3+ cases incl. `tool_not_called` / `command_not_ran` for `cd` and `git checkout`; the spec's `command_succeeded` wording is read as the section-10 `command_not_ran` form).
- [ ] Skill score at least 70 and ratchet updated: `dev/quality/skill-scores.json` entry `repo`.
- [ ] Guidelines "Multi-repo" sections, README row and count: `dev/guidelines.md`, `repo-conventions/templates/guidelines.md`, `README.md`, `tests/readme_skill_count.bats`.
- [ ] `in-this-repo.sh` finds repos under a second root, ignores its own main from a linked worktree, survives a broken `repos.sh`: `tests/taskid_in_this_repo.bats` (the three titles above).
- [ ] `resolve` exit codes (0/3/4/5/6), `--any` and deterministic ambiguity order (PR 2): `tests/repo_resolve.bats` "ambiguous prefix exits 3 with candidates", "unregistered path refused, --any accepts", "malformed registry exits 6".
- [ ] `/repo switch` (PR 2) incl. the 2.1.246 gate: `tests/repo_resolve.bats` "version gate below/at/unknown", SKILL.md switch workflow.
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
