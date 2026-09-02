---
name: 1password-env-setup
description: Use when the user explicitly asks to bootstrap or refresh a repo's 1Password-backed .env — generates the skip-if-populated .envrc and materializes .env from .env.tpl via op inject
disable-model-invocation: false
argument-hint: "[path]"
---

# 1Password Env Setup

Bootstraps a repo's local secrets flow on top of `.env.tpl` (an `op://`
reference file your repo defines against your own 1Password vault):
materializes `.env` via `op inject`, and writes a `.envrc` (direnv) that
re-materializes it automatically on every `cd` into the repo — but skips the
1Password round-trip (and any interactive unlock prompt it can trigger) when
`.env` is already populated and not stale relative to `.env.tpl`.

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
3. Write `<path>/.envrc` with the skip-if-populated template (below).
   Idempotent — a no-op if the file already has this exact content.
4. Materialize `<path>/.env` via `op inject -i .env.tpl -o .env`, unless
   `.env` is already newer than `.env.tpl` (same staleness check as the
   `.envrc` itself performs on every `cd`). If the `op` CLI isn't installed,
   skip with install guidance rather than failing.
5. Run `direnv allow` in `<path>` so the new `.envrc` takes effect
   immediately. If `direnv` isn't installed, skip with install guidance.

Run directly:

```bash
bash 1password-env-setup/scripts/1password-env-setup.sh [path]
```

### The `.envrc` template

```bash
if [ -f .env ] && [ .env -nt .env.tpl ]; then
  : # already materialized and newer than the template -- skip the 1Password round-trip
else
  op inject -i .env.tpl -o .env
fi
dotenv .env
```

The mtime check (`.env` newer than `.env.tpl`) is a cheap, correct-enough
staleness signal — a rotation always touches `.env.tpl`'s freshness relative
to the last materialization, so a newer `.env` means nothing has changed
since.

## Important Notes

- **Never overwrites a hand-edited `.envrc` silently** — it only skips
  rewriting when the existing content is byte-identical to the generated
  template; any other existing `.envrc` is replaced (this skill assumes it
  owns `.envrc`, matching the one-`.envrc`-per-repo convention). If a repo
  needs additional `.envrc` logic beyond this template, add it by hand after
  running this skill, not before.
- Helper functions (`pes-envrc-content`, `pes-check-env-tpl`,
  `pes-write-envrc`, `pes-materialize-env`, `pes-direnv-allow`) are
  function-wrapped and BASH_SOURCE-guarded (see
  `statusline-setup/scripts/statusline-command.sh` for the same pattern), so
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
