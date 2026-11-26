---
status: Open
estimation: 8   # umbrella; children sum to 10
depends_on: [T20261125-305580, T20261125-119704, T20261125-107918, T20261125-303266, T20261125-230436, T20261125-239989]
source: owner request via job 1579, 2026-11-25
related: T20261125-264487, T20261125-366351, dev/EPICS/E3-dependency-chain.md
description: ccxp upgrade path: per-repo schema marker, ordered idempotent migrations, /ccxp-upgrade skill, preflight warnings, hard gate, release check
---

# T20261125-424111: ccxp upgrade path (schema marker, migrations, /ccxp-upgrade)

## Problem

- **Type**: feature
- Owner's words: "we also need to think about upgrade path from ccxp version x to ccxp version y, and if there is a schema change (e.g. in our case, retire 'blocks' and replaced with 'depends_on'), then there should be an upgrade automation for that repo, so that the task files would be consistent with the new schema"; then "yes, file and drive it".
- Today a schema change (E3 retires `blocks:`) leaves every consumer repo inconsistent until someone hand-edits; nothing tells a repo it is behind.
- Related: [T20261125-264487](T20261125-264487-retire-blocks-field-depends-on-only.md) (job 1577, retire blocks tooling; its `todo-deps.sh migrate` is wrapped by migration 0001) and epic E3.

## Design

- **Marker**: one committed file `dev/.ccxp-schema` holding a single integer (no marker = schema 0).
  - Chosen over a key in a config file because no committed per-repo config exists (`dev/.autopilot-config.json` is local and gitignored); one integer file is trivially diffable and needs no parser.
- **Plugin side**: `_schema/schema.env` with `CCXP_SCHEMA=<n>` (newest migration number) and `CCXP_MIN_REPO_SCHEMA=<m>`.
- **Migrations**: `_schema/migrations/NNNN-slug/{check,apply,README.md}`, run in order for N above the repo schema up to `CCXP_SCHEMA`.
  - `check <repo>`: read-only report, exit 0 nothing to do, 10 would change, other = error.
  - `apply <repo>`: idempotent rewrite; the runner writes the marker only after every pending migration applied.
  - Each ships before/after bats fixtures under `tests/fixtures/schema/NNNN/`.
  - 0001 = blocks to depends_on, wrapping `todo-deps.sh migrate` once job 1577 lands it.
- **Runner**: `_schema/schema.sh` with `repo-schema`, `plugin-schema`, `status`, `pending`, `check`, `apply`, `gate`, `release-check`.
- **`/ccxp-upgrade`**: reads the schema, shows the dry-run of every pending migration, makes ONE branch and ONE PR via the normal lint/review/`/address-pr` flow in a fresh worktree (never the owner's shared clone); `--all` iterates `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-repos.json`. Never merges except through `/address-pr`.
- **Detection**: drive, todo and autopilot preflight warn "repo schema N, plugin needs M: run /ccxp-upgrade"; never a silent write.
- **Hard gate**: repo schema below `CCXP_MIN_REPO_SCHEMA` makes drive and autopilot refuse with a clear message.
- **Two-release window**: release N ships compat reader plus migration and warns; release N+1 drops the old form and raises `CCXP_MIN_REPO_SCHEMA`.
- **Release check**: a `CCXP_SCHEMA` bump without a migration directory and a test fails; release notes list schema changes and migration ids.
- **Local state files** (autopilot-state schema 2, ledger schema 3): gitignored and per machine, so they migrate by reader tolerance (a state without the current `schema` reads as off, the ledger (one JSON object, schema 3) upgrades an older object in place on write and refuses to write a newer one (`ledger.sh`)); documented, no runner step.

## Split

- [T20261125-305580](T20261125-305580-schema-marker-and-gate.md): marker, plugin schema, `gate`
- [T20261125-119704](T20261125-119704-migration-runner-and-bats.md): runner plus fixtures
- [T20261125-107918](T20261125-107918-ccxp-upgrade-skill.md): the skill
- [T20261125-303266](T20261125-303266-schema-preflight-warnings.md): warnings and gate wiring
- [T20261125-230436](T20261125-230436-schema-release-check.md): release check
- [T20261125-239989](T20261125-239989-upgrade-path-docs.md): docs, window rule, state files

## Done criteria

- All six sub-tasks closed; migration 0001 wired to job 1577's migrate once it lands (otherwise a follow-up task says so).
