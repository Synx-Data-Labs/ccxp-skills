---
name: 1password-env-setup
description: Use when the user explicitly asks to bootstrap or refresh a repo's 1Password-backed .env — installs the refresh-env helper, generates a hash-checking .envrc, and materializes .env from .env.tpl via op inject
argument-hint: "[path]"
---

# 1Password Env Setup

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Bootstraps a repo's local secrets flow on top of `.env.tpl` (an `op://`
reference file your repo defines against your own 1Password vault):
materializes `.env` via `op inject`, and writes a `.envrc` (direnv) that
re-materializes it automatically on every `cd` into the repo — but skips the
1Password round-trip (and any interactive unlock prompt it can trigger) when
`.env` is fresh **by content**: the sha256 of `.env.tpl` and of the generated
`.env` still match the hashes recorded at the last refresh. mtime is not used.

This skill owns the **bootstrap mechanism only** — the `op://` reference
list inside `.env.tpl` is repo-specific and out of scope here. An adopting
team designs that part itself: a vault layout for where each secret lives,
the `op://<vault>/<item>/<field>` references written into `.env.tpl`, a
CI/GHA secrets-sync approach if the pipeline also needs these values, and a
rotation cadence for the underlying 1Password items.

## Argument

`[path]` is optional — the target repo directory. Defaults to the current
directory.

## Workflow

1. Resolve `<path>` (default `.`). Verify it exists.
2. Verify `<path>/.env.tpl` exists. If not, stop and report — this skill
   bootstraps `.env`/`.envrc` from an existing `.env.tpl`; the `op://`
   reference list itself must already be written (design your own vault
   layout and reference format — see "Cross-references" below).
3. Install the standalone helper as `<path>/refresh-env` (executable copy of
   `scripts/refresh-env.sh`; idempotent), then write `<path>/.envrc` calling it
   (below). Idempotent — a no-op if the content is already identical.
4. Materialize `<path>/.env` through `refresh-env` (content-hash check, then
   `op inject` only if stale). If the `op` CLI isn't installed, skip with
   install guidance rather than failing. A failed `op inject` (wrong account,
   network, etc.) is reported as a failure and stops the workflow
   (T20260918-214522). Set `OP_ACCOUNT` (e.g. `OP_ACCOUNT=my.1password.com`)
   to pass `--account` through to `op inject`.
   `refresh-env` removes its `.env.tmp.*`/`.env.err.*` on every exit path
   (success, failure, signal, EXIT) and sweeps leftovers older than
   `REFRESH_ENV_SWEEP_MINS` (default 10) that no process holds open. A repo
   whose `.envrc` is an old inline-`mktemp` template (no `./refresh-env`)
   leaks one temp file per killed direnv run; re-run this skill to replace it.
5. Run `direnv allow` in `<path>` so the new `.envrc` takes effect
   immediately. If `direnv` isn't installed, skip with install guidance.

Run directly:

```bash
bash <skills-root>/1password-env-setup/scripts/1password-env-setup.sh [path]
```

### The `.envrc` template

```bash
if ./refresh-env .; then
  dotenv .env
else
  log_error "refresh-env failed -- .env NOT loaded (see message above); then run ./refresh-env"
fi
```

### The `refresh-env` helper

Callable by any process (direnv, launchd, a Claude Code hook, a script):
`<path>/refresh-env [--check|--force] [dir]` (the installed copy defaults to
its own directory).

- **Freshness by content** — `.env.tpl.sha256` (template hash at last refresh)
  and `.env.sha256` (hash of the `.env` the generator wrote), both mode 0600,
  hashes only, never values. Stale reasons: `missing`, `no-state`,
  `tpl-changed`, `env-edited-outside-generator` (a hand edit, even one newer
  than the template, is caught).
- **`--check`** — no `op` call; prints `fresh` (exit 0) or `stale: <reason>`
  (exit 3) plus `drift: <KEY>` lines: keys `.env.tpl` defines as `op://`
  references whose `.env` line is missing or still an unresolved `op://`.
  Key names only.
- **`--force`** — refresh regardless of hashes (a vault value rotated while the
  template did not change cannot be seen by hashes).
- **Unlock** — `op inject` runs with a bounded wait (`REFRESH_ENV_OP_TIMEOUT`,
  default 60s). Timeout or an auth/sign-in failure prints a clear "1Password
  needs your unlock" message naming the command to run, exits 75, leaves the old
  cache and hashes untouched, and callers must not load the stale cache.
- **Safety** — `mkdir` lock with stale-lock recovery, `mktemp` temp file under
  `umask 077` moved into place only on success, hashes written before the move.
- **Exit codes** — 0 fresh/refreshed, 1 error, 2 usage or no `.env.tpl`,
  3 stale (`--check`), 10 `op` missing, 75 unlock needed, timed out or lock held.
- **First run after upgrade** — no recorded state counts as stale, so the first
  call costs one biometric approval. A `.envrc` deployed before this change keeps
  its old mtime logic until the skill is re-run.

## Important Notes

- **Never overwrites a hand-edited `.envrc` silently** — it only skips
  rewriting when the existing content is byte-identical to the generated
  template; any other existing `.envrc` is replaced (this skill assumes it
  owns `.envrc`, matching the one-`.envrc`-per-repo convention). If a repo
  needs additional `.envrc` logic beyond this template, add it by hand after
  running this skill, not before.
- Helper functions (`pes-envrc-content`, `pes-check-env-tpl`,
  `pes-install-helper`, `pes-write-envrc`, `pes-materialize-env`, `pes-direnv-allow`) are
  function-wrapped and BASH_SOURCE-guarded (see
  `quality-probe/scripts/probe.sh` for the same pattern), so
  BATS can source the script and unit-test each step without invoking `op`
  or `direnv` for real.
- Does not install `op` or `direnv` — it detects their absence and prints
  install guidance instead of failing, since a missing CLI on one box
  shouldn't block the `.envrc`/`.env.tpl` bootstrap from being written.

## Cross-references

- [1Password CLI: secret references](https://developer.1password.com/docs/cli/secret-references/) —
  the public `op://<vault>/<item>/<field>` syntax this skill's `op inject`
  step resolves; use it as the starting point for writing your own
  `.env.tpl`.
- Not covered here, and specific to your own setup: a vault layout for
  where these secrets live, a CI/GHA secrets-sync approach if your pipeline
  also needs them, and a rotation cadence for the underlying 1Password
  items.
