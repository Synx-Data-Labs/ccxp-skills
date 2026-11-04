---
name: secrets-check
description: Use when the user explicitly asks to check a working change for secret-handling problems before a PR — runs the repo's secret-handling lint on the diff and reports masked findings
argument-hint: "[base-ref]"
---

# Secrets Check

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Check the current branch's changes for secret-handling problems (token literals, secrets on a command line, echoed or dumped secret variables, `set -x` with secrets) before opening a PR. Reports only; never edits files and never fixes a finding automatically, because a fix would have to touch the secret value.

## Argument

`<arg>` is optional: the base ref to diff against (default `origin/main`).

## Workflow

1. **Run the check** from the repo root:

   ```bash
   bash <skills-root>/secrets-check/scripts/secrets-check.sh "${BASE:-origin/main}"
   ```

   - With the repo's secret-handling lint script (`lint-secret-handling.sh` under its `scripts/` dir) present it runs `--diff <base>` and relays its output: exit 0 clean (warnings advisory), 1 findings, 2 usage or allowlist error. The lint masks every matched value (first 4 characters plus `...`) and prints `file:line` plus the rule id, never the source line.
   - Without it the script falls back to a rough built-in grep set on the added lines and prints only the rule and a diff line index, so no value reaches the transcript. Say plainly that the fallback is not the repo's lint.

2. **Never** re-run a finding's line through `cat`/`grep` output into the transcript, and do not fix automatically.

3. **Report**: pass or fail, the rule ids hit, the masked findings, and for each the safe form (stdin, `--token-file`, `op run`, `op inject`; see the repo's `SECURITY.md` when it has one). A finding that is a deliberate fixture is allowed through the repo's own allowlist (`.secret-lint-allow`), never by weakening the check.

## Notes

- The `secret-guard` PreToolUse hook (`hooks/secret-guard.sh`) is the live, per-command counterpart; this skill is the pre-PR gate on the whole diff. Both name the same rule ids.
- `/gcpr` and `/address-pr` recommend running it before the PR is opened or merged.
