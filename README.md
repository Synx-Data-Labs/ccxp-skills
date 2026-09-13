# ccxp-skills

Shared Claude Code skills for the ccxp-family workflow suite (task
lifecycle, PR automation, CI/RCA, retros) plus general-purpose dev-tool
skills — maintained in one place and used across every repo on a given
machine. Split out of a private company repo so any team can adopt it with
no company-specific dependency: every skill here is either fully generic
or config-driven via environment variables with no baked-in default.

## Install

### As a plugin (recommended)

This repo is a Claude Code plugin *and* its own single-plugin marketplace,
so `/plugin` can install all 41 skills in one step:

```
/plugin marketplace add Synx-Data-Labs/ccxp-skills
/plugin install ccxp-skills@ccxp-skills
```

Update later with `/plugin update ccxp-skills`, and remove with
`/plugin uninstall ccxp-skills`. `/plugin` manages the clone for you —
there is nothing to symlink and no `install.sh` to run.

The skills live at the repo root rather than under `skills/`, which the
manifest declares via `"skills": "."`. That keeps each skill a sibling of
the shared libs (`_gh/`, `_session/`, `_taskid/`, `_ipm/`, `_docs/`,
`_journal/`), so the `../_gh/gh.sh`-style references inside the skills
resolve unchanged whether the repo is installed as a plugin or symlinked
by hand.

### By symlink (alternative)

Use this instead of the plugin when you want the skills to coexist with
another, independently-git-tracked skills repo under the same
`~/.claude/skills/`, or when you want to edit them in place in a clone you
control.

Claude Code's skill loader is exactly one level deep —
`~/.claude/skills/<name>/SKILL.md` — it does **not** recurse into a
repo-root clone placed under `~/.claude/skills/`. So clone this repo
somewhere else, then symlink each skill/shared-lib into
`~/.claude/skills/` with the included installer. This is what lets it
coexist as a sibling skill set alongside another, independently-git-tracked
skills repo (e.g. a private, company-specific one) on the same machine —
Claude Code follows symlinks and reads `SKILL.md` from the target:

```bash
git clone git@github.com:Synx-Data-Labs/ccxp-skills.git ~/workspace/ccxp-skills
bash ~/workspace/ccxp-skills/scripts/install.sh
```

`install.sh` symlinks every top-level skill (a directory with a
`SKILL.md`) and every shared lib (a leading-underscore directory) into
`~/.claude/skills/`. It's idempotent (safe to re-run) and never touches
an existing name it didn't create itself — see `--target DIR` to install
elsewhere, `--dry-run` to preview, and `--uninstall` to remove only the
symlinks it owns.

Update later with:

```bash
cd ~/workspace/ccxp-skills && git pull
```

No re-install needed — the symlinks point at the same clone, so `git
pull` alone picks up new/changed skills. Re-run `install.sh` only when a
*new* skill directory is added upstream (it needs its own new symlink).

## Prerequisites

A one-time, machine-global setup that every consumer repo on the machine
shares:

- **Skills installed** — this repo cloned (see [Install](#install)).
- **`~/.claude/.env`** — shared config, loaded by skill scripts before any
  repo-local `.env`. `chmod 600` it and keep it out of every repo (it's
  machine-global). Every variable below is **optional** with a documented
  graceful-degrade — nothing here is required just to use the suite:
  - `SLACK_WEBHOOK_URL` / `SLACK_WEBHOOK_URL_<NAME>` — incoming webhooks for
    the `slack` skill's channels; `<NAME>` maps to `--channel <name>`
    (uppercased). See `slack/SKILL.md`.
  - `SLACK_STANDUP_CHANNEL` — channel `slack-check-reply` polls for standup
    replies. Unset degrades to a one-line skip note.
  - `PROJECT_OWNER` / `PROJECT_NUMBER` — the org login + Project V2 number
    that `_session/_lib.sh` mirrors task status onto. Unset means the
    Project-board mirror is a silent no-op — the task file's own `status:`
    frontmatter stays the source of truth regardless.
  - `SESSION_TOKEN` / `PROJECT_PAT` / `GH_TOKEN` — one of these must carry a
    token with org-level `Projects: Read and write` for the Project-board
    mirror above to work.
  - `ATTRIBUTION_CCXP_PATHS` — colon-separated clone path(s) treated as
    autonomous/ccxp (vs. interactive) for the daily standup's attribution
    table. Unset means every location classifies as interactive — cosmetic
    only, never a functional failure.
  - `RETRO_SLACK_CHANNEL` — channel `retro` Phase 6 posts its weekly summary
    to. Unset means the skill asks which channel to use interactively, or
    skips Phase 6 in an unattended run.
  - `METRICS_OWNER` / `METRICS_REPOS` — the org + space-separated repo list
    `retro` Phase 4d reads `dev/quality/metrics.jsonl` scoreboards from.
    Unset/empty means Phase 4d reports "no scoreboard reachable" and skips.
  - `ROADMAP_TARGET_REPO` — `<owner>/<repo>` of a separate hub repo whose
    `dev/ROADMAP.md` gets the week's IPM commit propagated into it.
    Required only if `ccxp` Phase 2a.5b actually runs; `update-roadmap.sh`
    exits with a clear error (no clone/PR attempted) if unset when needed.
  - `KNOWN_SIBLING_REPOS` — comma-separated sibling repo names
    `repo-conventions/scripts/lint_refs.py` treats as "foreign" for bare
    reference qualification. Unset/empty is a no-op.
- **`gh` CLI authenticated** — `gh auth login`. Skills invoke `gh` via
  `_gh/gh.sh`, which auto-selects the account with access to the current
  repo (so multi-account machines work).
- **Python 3 + PyYAML** — `pip install pyyaml`. Used by `repo-conventions`'
  task-frontmatter lint and the `sync-tasks` / `lint-tasks` actions.

Per-repo CI secret (set in each repo's GitHub settings, not locally):

- A PAT with repo access + org `Projects: Read and Write`, for the
  `sync-tasks` action's `project-pat` input (name it whatever your org's
  secret-naming convention prefers — see `actions/sync-tasks/README.md`).

## Skills included

### Task lifecycle & PR automation (ccxp-family core)

| Skill | Purpose |
|-------|---------|
| `ccxp` | Day-or-week orchestrator — daily standup, Monday IPM, focused work, Friday retro |
| `drive` | Pick ONE task, drive it to done — recurse into blockers, never switch laterally |
| `todo` | List open tasks, pick the next actionable, reorder/clean up the backlog |
| `claim` | Claim/check/release a task outside the full `/drive` loop |
| `stage` | Ensure a task is present in `dev/TODO/queue.md` |
| `top` / `bottom` | Move a task (or several) to the front/back of the priority queue |
| `new-task` | File a new task to the `dev/TODO` backlog |
| `gcpr` (alias `land`) | Commit & push uncommitted changes, open a PR, hand off to `address-pr` |
| `address-pr` | Address PR review comments, verify CI + hard gate, merge or notify |
| `cleanup-branch` | Post-merge branch cleanup — a specific branch, a PR-merge sweep, or a bulk prune |
| `retro` | Weekly retrospective — metrics, analysis, action items |
| `rca` | Diagnose/classify/track root cause for a failed GitHub Actions run |
| `labrun-rca` | RCA a failed run announced via Slack permalink, reply in the thread |
| `design-score` | Deterministic 0–100 structural score gating a design doc's Phase 2 → Phase 3 |
| `quality-probe` | Measure code quality on a task's touched files, record to `dev/quality/metrics.jsonl` |
| `journal-compact` | Compact a month of `dev/JOURNAL/` into a digest |
| `repo-conventions` | CLAUDE.md/guidelines.md structure, `dev/` TODO lifecycle, conventions lint |
| `skill-conventions` | Conventions for authoring a SKILL.md in this suite |

### Notification & integration

| Skill | Purpose |
|-------|---------|
| `slack` | Send a Slack notification to a configured channel |
| `slack-check-reply` | Check replies on escalation/standup Slack threads |
| `email-triage` | Triage the Gmail inbox — summarize, surface the top action item |
| `1password-env-setup` | Bootstrap a repo's `.env` via `op inject`, plus a skip-if-populated `.envrc` |

### General-purpose utility

| Skill | Purpose |
|-------|---------|
| `verify-site` | Local preview + automated test-plan checks for a site PR |
| `help-net` | Triage traveler network issues on macOS (GFW, throttle, MTU, DNS, VPN) |
| `statusline-setup` | Deploy/edit/test the Claude Code statusline script |
| `md-to-pdf` | Convert markdown to PDF with scaled images, CJK support |
| `proof-read` | Sentence-level consistency check for markdown (term drift, undefined jargon, CN↔EN) |
| `translate-patent` | Translate a patent DOCX from Chinese to English |

### Cloudflare developer platform

| Skill | Purpose |
|-------|---------|
| `cloudflare` | Workers, Pages, storage, AI, networking, security, IaC — general Cloudflare development |
| `cloudflare-email-service` | Transactional email sending + routing on Cloudflare |
| `cloudflare-one` | Zero Trust / SASE — Access, Gateway, WARP, Tunnel, DLP, CASB |
| `cloudflare-one-migrations` | Migration assessments from other VPN/SASE stacks to Cloudflare One |
| `agents-sdk` | Build stateful AI agents on Workers (Agents SDK) |
| `durable-objects` | Stateful coordination, RPC, SQLite storage, alarms on Durable Objects |
| `sandbox-sdk` | Sandboxed code execution (interpreters, CI/CD, untrusted code) |
| `turnstile-spin` | End-to-end Turnstile (CAPTCHA) setup in a project |
| `workers-best-practices` | Review/author Workers code against production best practices |
| `wrangler` | Cloudflare Workers CLI reference for deploy/dev/manage across all bindings |
| `web-perf` | Core Web Vitals / performance audit via Chrome DevTools MCP |

## Reference docs

Canonical cross-repo docs at this repo's root (peers, not skills) —
reference these from each consumer repo's `dev/guidelines.md` rather than
copying them per-repo:

- [`lifecycle.md`](lifecycle.md) — task lifecycle: status flow, ID format,
  blocking, creating/working/completing procedures.
- [`gotchas.md`](gotchas.md) — hard-won operational gotchas.
- [`glossary.md`](glossary.md) — canonical definitions of coined terms &
  acronyms (looked up by `/proof-read`'s undefined-jargon check).
- [`engineering-standards.md`](engineering-standards.md) — the code/design
  quality bar (TDD, test-driven refactoring, shared-lib design, quality
  metrics); gated by `design-score`, measured by `quality-probe`.
- [`secrets-management.md`](secrets-management.md) — the generic half of a
  secrets-management policy (automation tiers, adding a new secret). Author
  your own account-structure and vault-map sections to match your org —
  this doc deliberately omits that org-specific half.

## Developing

Edits to `<skill>/SKILL.md` take effect immediately in every consumer
repo — it's a real checkout, not a read-only cache. When ready, commit +
push here; other machines pick up changes with `git pull`.

## Adding a new skill

1. Create `<name>/SKILL.md` at the repo root with proper frontmatter
   (`name`, `description`, `argument-hint`)
2. Commit + push
3. Other machines: `git pull`

## Skill scripts

If a skill needs helper scripts (bash, python, etc.), put them under
`<skill>/scripts/` and reference them by absolute path from `SKILL.md`:

```bash
bash ~/.claude/skills/<name>/scripts/<script>.sh <args>
```

This keeps scripts colocated with the skill (no consumer-repo dependency)
and works the same in every repo on the machine. Scripts must:

- Discover the consumer repo from cwd via
  `bash ~/.claude/skills/_gh/gh.sh repo view --json nameWithOwner --jq .nameWithOwner`
  — never hardcode `owner/repo`.
- Accept a `REPO` env var override for explicit targeting.
- Read shared config (e.g. `SLACK_WEBHOOK_URL`) from `~/.claude/.env`
  first, then `$(pwd)/.env`.

## Shared helpers (`_<name>/`)

Helpers shared across skills live in leading-underscore directories at the
repo root (Claude Code only loads dirs containing `SKILL.md`, so these
stay invisible as skills). Current set:

- `_taskid/` — mint/resolve task IDs, blob-link URLs, orphaned-ref checks.
- `_gh/gh.sh` — `gh` wrapper that picks the authenticated account with
  access to the current repo. **Use this everywhere instead of bare
  `gh`.** On machines with multiple gh accounts, bare `gh` always uses the
  *active* account, which may not have access to the repo. The wrapper
  probes `gh auth status` accounts and runs `gh` under the one that can
  read `origin`, scoped per-process via `GH_TOKEN` (no global mutation, no
  `gh auth switch`).
- `_session/` — on-main task claim lock, Project V2 board mirror,
  PR-ownership resolution, reclaim sweep for dead claims. See
  `_session/README.md`.
- `_ipm/` — current-iteration lookup and `scheduled:` stamping.
- `_journal/` — journal-move helpers for closing a task.
- `_docs/` — the shared markdown-lint wrapper (`lint-docs.sh`) and
  doc-impact/freshness checks.

## Notes

- Skills live at the repo root; `README.md` and `.git/` are ignored by
  Claude Code (only directories containing `SKILL.md` are loaded).
- There is intentionally no per-repo customization mechanism — this pool
  is a union and every machine gets all of it. Revisit if the pool grows
  past ~50 skills or you need per-project pinning.
