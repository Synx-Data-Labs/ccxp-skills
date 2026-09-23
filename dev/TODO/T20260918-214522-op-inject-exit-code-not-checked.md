---
status: Coding — design skipped, self-evident fix per its own "Done looks like" (2026-09-23)
estimation: 30m
source: this conversation, 2026-09-18
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-214522: `1password-env-setup.sh` reports "materialized" even when `op inject` fails

## Problem

- **Type**: bug
- `pes-materialize-env()` in `1password-env-setup/scripts/1password-env-setup.sh` runs:

  ```bash
  op inject -i "$dir/.env.tpl" -o "$dir/.env"
  echo "materialized: $dir/.env"
  ```

  with no exit-code check between the two lines — the "materialized" message prints
  unconditionally, even when `op inject` fails.
- Reproduced while bootstrapping `lsc-pa/.env`: the script's `op inject` call also omits
  `--account`, so it resolved against the wrong signed-in 1Password account and failed with
  `"Personal" isn't a vault in this account` — but the script still printed
  `materialized: /Users/.../lsc-pa/.env`, which read as success.
- No data was lost in that run (`op inject -o` doesn't write partial output on failure, so the
  pre-existing `.env` was left untouched), but a real failure is easy to miss since the script's
  own output claims success.
- Done looks like:
  - `pes-materialize-env()` checks `op inject`'s exit status and reports failure (not
    "materialized") when it's non-zero, propagating a non-zero return so callers/CI notice.
  - Revisit whether the script should accept/pass an `--account`, matching the `.envrc` template
    it documents alongside (`lsc/.envrc` already passes `--account my.1password.com --force`)
    — an account mismatch should ideally surface as a distinct, actionable error rather than
    a generic inject failure.
  - Existing BATS-testable structure (function-wrapped, `BASH_SOURCE`-guarded) should make this
    easy to cover with a test that stubs a failing `op inject`.
