---
status: Done
estimation: 30m
source: this conversation, 2026-09-18
claimed_by:
claimed_role:
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

## Test plan

- [x] `tests/1password_env_setup.bats` — new cases, written test-first (RED
  verified before each fix, confirmed failing for the right reason — not
  a typo — then green after implementing):
  - [x] `pes-materialize-env` reports failure (not "materialized") and
    returns non-zero when `op inject` fails
  - [x] `pes-materialize-env` gives an actionable `OP_ACCOUNT` hint for the
    exact "isn't a vault in this account" error text from the reported
    incident
  - [x] `pes-materialize-env` passes `--account` to `op inject` when
    `OP_ACCOUNT` is set; omits it when unset (back-compat, unchanged
    default behavior)
  - [x] `pes-materialize-env` surfaces `op`'s own stderr warning on an
    otherwise-successful run (added addressing the PR #91 review)
  - [x] `1password-env-setup` (entry point) propagates a
    `pes-materialize-env` failure instead of silently succeeding, and
    confirms `pes-direnv-allow` never runs after that failure
- [x] `bats tests/1password_env_setup.bats` green (23/23)
- [x] `shellcheck 1password-env-setup/scripts/1password-env-setup.sh` clean
- [x] Full repo suite (`tests/*.bats _docs/*.bats`) still green
- [x] `bash _docs/doc-impact.sh origin/main` clean (the `1password-env-setup/SKILL.md`
  update was made proactively, not left for the gate to catch)

## Done criteria

- [x] `pes-materialize-env()` checks `op inject`'s exit status, reports
  failure (not "materialized") on non-zero, and returns non-zero —
  `1password-env-setup/scripts/1password-env-setup.sh` (`pes-materialize-env`)
- [x] The non-zero return propagates to callers/CI — `1password-env-setup()`'s
  entry point now does `pes-materialize-env "$dir" || return 1`
- [x] `--account` revisited and resolved: added as an opt-in `OP_ACCOUNT`
  env var passthrough (not a hardcoded default), plus an actionable hint
  when the error text matches the exact account-mismatch shape observed —
  `tests/1password_env_setup.bats`'s `OP_ACCOUNT` cases
- [x] Covered by BATS per the task's own suggestion —
  `tests/1password_env_setup.bats`, 7 new cases

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `1password-env-setup/scripts/1password-env-setup.sh` | `pes-materialize-env`, `1password-env-setup` | the fix target |
| `1password-env-setup/SKILL.md` | step 4 | documents the new `OP_ACCOUNT` behavior and failure propagation |
| `tests/1password_env_setup.bats` | new cases | test coverage |

## Closed (2026-09-23)

- Shipped in **PR #90** (claim) and the implementation PR that follows.
  `pes-materialize-env()` now checks `op inject`'s exit status, reports
  a real failure (not "materialized") with the actual `op` error text,
  and returns non-zero; `1password-env-setup()`'s entry point propagates
  that failure instead of continuing silently. All Done criteria met,
  including the "revisit `--account`" open question: resolved as an
  opt-in `OP_ACCOUNT` env var (not a hardcoded default), plus a specific
  hint when the error text matches the exact "isn't a vault in this
  account" shape from the original incident.
- **Scope decision, not deferred silently**: did *not* propagate
  `--account`/`OP_ACCOUNT` into the generated `.envrc` **template**
  (`pes-envrc-content()`) — only into the standalone
  `pes-materialize-env()` call path. The task's own reference to
  `lsc/.envrc` already having `--account ... --force` hand-added
  describes a repo that customized its *own* generated file after the
  fact, not something this script's template currently does for anyone.
  Changing the template affects every repo that regenerates its
  `.envrc` via this skill — a bigger blast radius than this 30m bug fix
  warranted; left as a candidate follow-up if it turns out to matter in
  practice, not filed as a new task since nothing concrete points at it
  being needed yet.
- **PR #91 review round (1 real finding, fixed)**: capturing `op
  inject`'s combined stdout+stderr to detect failure and report the
  real error also silently discarded any warning `op` prints on an
  *otherwise-successful* run — a genuine behavior regression from the
  pre-fix version, where such output printed straight to the terminal.
  Caught by independent review before this PR merged (I'd already found
  and fixed it myself moments earlier, but the diff under review was
  the pre-fix snapshot, so the finding still landed and confirmed the
  fix was both real and correct). Fixed: `$err` is now echoed to stderr
  on the success path too when non-empty, RED/GREEN-verified via a
  temporary `git stash` of just the fix. Also strengthened the
  entry-point propagation test per the reviewer's secondary suggestion
  (asserts `pes-direnv-allow` never runs after a failure, not just a
  non-zero exit).
- No follow-up tasks filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — 5 new BATS cases
  written and run first (RED verified: failing for the right reason —
  the old unconditional "materialized" echo, not a typo), then the
  fix implemented to green
- Verification (`superpowers:verification-before-completion`): yes —
  shellcheck clean, full 713-test repo suite green, `doc-impact.sh`
  clean (the `SKILL.md` update was made proactively alongside the code
  change, not left for the gate to catch), quality-probe recorded
  (shellcheck 0/0/0/0; one non-blocking `max_fn_lines` warning from the
  function growing to accommodate the new error-handling branches)
- Systematic debugging (`superpowers:systematic-debugging`): no —
  didn't get stuck; a small, well-scoped bug fix with the approach
  already spelled out in the task's own "Done looks like"
- Receiving code review (`superpowers:receiving-code-review`): yes —
  `/address-pr` §2.d on the implementation PR (#91), 1 real finding
  (the success-path stderr-swallowing regression above), fixed, 0
  pushback
