# ccxp-skills

Shared Claude Code skills for the ccxp-family workflow suite (task
lifecycle, PR automation, CI/RCA, retros) plus general-purpose dev-tool
skills — maintained in one place and used across every repo on a given
machine. Split out of a private company repo so any team can adopt it with
no company-specific dependency: every skill here is either fully generic
or config-driven via environment variables with no baked-in default.

## Install

This repo is a Claude Code plugin *and* its own single-plugin marketplace,
so `/plugin` can install all 42 skills in one step:

```
/plugin marketplace add Synx-Data-Labs/ccxp-skills
/plugin install ccxp-skills@ccxp-skills
```

Update later with `/plugin update ccxp-skills`, and remove with
`/plugin uninstall ccxp-skills`. `/plugin` manages the clone for you.

The skills live at the repo root rather than under `skills/`, which the
manifest declares via `"skills": "."`. That keeps each skill a sibling of
the shared libs (`_gh/`, `_session/`, `_taskid/`, `_ipm/`, `_docs/`,
`_journal/`), so the `../_gh/gh.sh`-style references inside the skills
resolve correctly under a plugin install.

The `_gh/auto-switch.sh` `SessionStart` hook (see
[Shared helpers](#shared-helpers-_name) below) wires itself automatically
via `hooks/hooks.json` — nothing to do. `statusLine.command`
(`statusline-setup/SKILL.md`) is the one exception: Claude Code has no
per-plugin statusline mechanism, so it still needs a one-time, manual
`settings.json` entry pointing at wherever `/plugin install` put this
plugin — and if that install used a marketplace (not the `directory`
source this repo's own dev checkout uses), the cache path is
version-pinned (e.g. `.../ccxp-skills/1.0.1/...`) and needs re-pointing
after `/plugin update` bumps it.

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
| `autopilot` | Keep calling bare `/drive` back-to-back for a set duration (e.g. "for the next 6 hours") |
| `drive` | Pick ONE task, drive it to done — recurse into blockers, never switch laterally |
| `todo` | List open tasks, pick the next actionable, reorder/clean up the backlog |
| `claim` | Claim/check/release a task outside the full `/drive` loop |
| `stage` | Ensure a task is present in `dev/TODO/queue.md` |
| `migrate-task` | Move a task file (and its `queue.md` entry) from one repo's `dev/TODO/` to another's |
| `top` / `bottom` | Move a task (or several) to the front/back of the priority queue |
| `new-task` | File a new task to the `dev/TODO` backlog |
| `grill-me` | Adversarial frontier-round interview of a task/plan before implementation; the `/ccxp` Phase 2a.3 pre-IPM design pass |
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
push here; other machines pick up changes with `git pull`, or with
`/plugin update ccxp-skills` where the repo is installed as a plugin.

`.claude-plugin/plugin.json` declares `"skills": "."`, so the plugin's
skill root is the repo root rather than a `skills/` subdirectory. That is
deliberate: each skill sits beside the shared libs (`_gh/`, `_session/`,
`_taskid/`, `_ipm/`, `_docs/`, `_journal/`) and reaches them through
`../_gh/gh.sh`-style relative references. Moving the skills under
`skills/` would break every one of those and the symlink installer with
them. `.claude-plugin/marketplace.json` makes the repo its own
single-plugin marketplace, which is why `/plugin marketplace add` takes
the repo slug directly.

## Adding a new skill

1. Create `<name>/SKILL.md` at the repo root with proper frontmatter
   (`name`, `description`, `argument-hint`)
2. Commit + push
3. Other machines: `git pull`, or `/plugin update ccxp-skills`

No manifest edit is needed — `"skills": "."` means any root directory
containing a `SKILL.md` is picked up automatically, by both install
paths. The frontmatter `name` is what the skill is invoked as, so keep it
equal to the directory name. Verify with `claude plugin validate .`, and
`claude plugin details ccxp-skills` once installed to see the component
inventory and its token cost.

## Skill scripts

If a skill needs helper scripts (bash, python, etc.), put them under
`<skill>/scripts/` and reference them from `SKILL.md` by a path relative
to this skill's own directory (the harness prints that directory as "Base
directory for this skill" when the skill loads — resolve against it, not
against whatever the consumer repo's cwd happens to be):

```bash
bash ../<name>/scripts/<script>.sh <args>
```

There is no absolute path that works under every install method — a
plugin-cache install's path is version-pinned and moves on every
`/plugin update`, and the script runs against an arbitrary consumer
repo's cwd, not this repo's. Scripts must:

- Discover the consumer repo from cwd via
  `bash ../_gh/gh.sh repo view --json nameWithOwner --jq .nameWithOwner`
  — never hardcode `owner/repo`.
- Resolve sibling shared-lib scripts from *within* a script itself via
  `dirname "${BASH_SOURCE[0]}"`, never a hardcoded path — this is what
  makes the script's own invocations robust regardless of caller cwd
  (see `_taskid/in-this-repo.sh` for the pattern).
- Accept a `REPO` env var override for explicit targeting.
- Read shared config (e.g. `SLACK_WEBHOOK_URL`) from `~/.claude/.env`
  first, then `$(pwd)/.env`.

### `dev/EPICS.md` format (hub repo)

`ccxp/scripts/epic-status.sh` (T20260911-347027) reads a human-owned
`dev/EPICS.md` in `ROADMAP_TARGET_REPO` to roll up epic-level progress into
the daily `/ccxp` standup. Per epic:

```markdown
### E1 — <title>
Goal: <one line — the standing goal this epic exists for>
Done when: <one line — the concrete completion condition>
Deadline: YYYY-MM-DD          # optional
- T20260101-000001            # any repo; local tasks resolve from this
- T20260101-000002            # clone, others via the hub-scoped `gh api`
```

- No status rows in the file — status is always derived at standup time
  (from each task's own frontmatter + PR state), so the file can never drift
  out of sync with reality.
- `Deadline:` is optional; omit the line entirely when an epic has none.
- The bullet list is order-significant only for the "Leading" task tie-break
  (first-listed wins a rank tie) — otherwise unordered.
- This is the exact shape `tests/fixtures/epics/EPICS.md` exercises and
  `epic-status.sh`'s parser/render tests assert against — keep the two in
  sync rather than letting this doc drift from what the script actually
  parses.

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
- `_gh/auto-switch.sh` — `SessionStart` hook complement to `gh.sh` above.
  It covers what `gh.sh` can't: a **bare, unwrapped** `gh` call (a Bash-tool
  invocation running `gh pr view` directly, a human typing `gh` in the
  terminal, any tool that doesn't route through the wrapper) still uses
  whichever account `gh auth switch` last left active — global, mutable,
  shared across every shell and Claude Code session on the machine. This
  script probes accounts the same way `gh.sh` does, but deliberately runs
  `gh auth switch` — the opposite tradeoff from `gh.sh`'s no-global-mutation
  design — because that's the only lever available to fix a bare `gh`
  call. Exits 0 in every case (not a git repo, already-correct account, no
  account can see the repo) — it never blocks session start.

  Once an account is confirmed (already-active or reached by switching),
  it also wires the current repo's **local** git config (`.git/config`
  only — never `~/.gitconfig`) so a bare `git push`/`pull`/`fetch` stops
  depending on the SSH agent's currently-loaded key: `credential.helper`
  is pointed at `gh auth git-credential` (so it authenticates as whichever
  account was just selected) and `url."https://github.com/".insteadOf` is
  set for both `git@github.com:` and `ssh://git@github.com/`, forcing
  GitHub-origin traffic onto HTTPS so the credential helper actually gets
  consulted. `gh auth switch` and the SSH agent's active identity are
  independent auth paths — fixing one says nothing about the other.

  Wired automatically by the plugin via `hooks/hooks.json`
  (`${CLAUDE_PLUGIN_ROOT}/_gh/auto-switch.sh`) — nothing to do.

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
