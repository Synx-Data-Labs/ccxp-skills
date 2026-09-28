# Gotchas

Recurring footguns we've hit more than once. Each entry: what went wrong, what the fix is, how to recognize the symptom next time.

## gh CLI

### `gh api --jq` doesn't accept `--arg` / `--argjson`

`--jq` is a single positional filter, not a flag that forwards additional `jq` args. When you need variable substitution, **pipe to a separate `jq`** instead:

```bash
# WRONG — errors with "accepts 1 arg(s), received 4"
gh api graphql -f query='...' --jq '<filter>' --arg today "$today"

# CORRECT
gh api graphql -f query='...' | jq -r --arg today "$today" '<filter>'
```

**Symptom**: `gh: accepts 1 arg(s), received 4` (or similar argument-count error) from a `gh api` call that looks otherwise fine. The error message doesn't point at the cause; you can easily lose 5 min debugging the GraphQL query before realizing it's the wrapper.

**Why**: `gh api --jq` takes exactly one string argument (the filter). Any additional positional args (including `--arg key val` pairs intended for `jq`) get counted as positional args to `gh api`, blowing past its arg limit.

**Quick lookup if you hit it again**: search this doc for `--jq` or for the error text `accepts 1 arg(s)`.

## GitHub / gh CLI

### Rebase-only merges — don't trust the repo-settings API's `allow_*` flags

A branch-protection ruleset enforcing rebase-only merges can make `gh pr merge --squash`/`--merge` fail with `GraphQL: ... not allowed on this repository`, even when `gh api repos/OWNER/REPO --jq '{squash:...}'` reports all three merge methods (`allow_squash_merge`, `allow_merge_commit`, `allow_rebase_merge`) as `true`. A ruleset can override the repo-settings API's `allow_*` flags without those flags reflecting it.

**How to apply:** don't trust `gh api repos/OWNER/REPO --jq '{squash:...}'` as proof a merge method will work. Just try `gh pr merge --rebase` first, falling back to `--squash`/`--merge` only if rebase itself fails.

### Shallow clone breaks `gh pr create`'s branch-detection

`git clone --depth=N` (without `--no-single-branch`) restricts the fetch refspec to just the default branch. After creating a feature branch, committing, and `git push -u origin <branch>` (which reports success), `gh pr create` can still fail with `aborted: you must first push the current branch to a remote, or use the --head flag` — because no `refs/remotes/origin/<branch>` ref was ever created locally for `gh` to detect, even though the branch is genuinely on GitHub (`git ls-remote --heads origin <branch>` proves it).

**How to apply:** when `gh pr create` fails this way against a shallow/single-branch clone, pass the branch explicitly: `gh pr create --head <branch> ...`. No need to fetch full history or drop `--depth`.

### Retired: GitHub Copilot native code review

Older memories/JOURNAL entries may reference "Copilot review", a `copilot_code_review` repository ruleset, or Copilot Coding Agent assignment (`@copilot review`) as part of the PR merge gate. **That mechanism has been retired.** `address-pr/SKILL.md` §2.d now dispatches its own independent, fresh Claude Code review agent (`Agent` tool, `code-improvement-scanner` or `general-purpose`) instead of relying on GitHub's native Copilot review or the ruleset that used to gate on it — this removes the org-tier dependency (Copilot Enterprise / Code Review add-on) entirely. If you find a repo ruleset still named "Code Quality Copilot review for default branch", its `enforcement` field can flip between `active`/`disabled` independent of any doc claiming a fixed state — check it directly (`gh api repos/OWNER/REPO/rulesets`) rather than trusting a prior note, but don't assume it's part of the current merge gate either way; `address-pr`'s own review loop is the authoritative mechanism now.

## Testing (BATS / Python)

### Hermetic `git init` test fixtures need a local identity

A throwaway `git init .` BATS fixture that later runs a real `git commit` (e.g. seeding a repo for branch/log lookups) must set `git config user.email`/`user.name` **locally in that fixture**, not rely on a global identity. Dev boxes typically have `~/.gitconfig` set, so the test passes locally; GitHub Actions runners have no global git identity at all, so the same test fails there with "Please tell me who you are" (exit 128).

**How to apply:** any new BATS test doing a real `git init` + `git commit` in `$BATS_TEST_TMPDIR` must add `git config user.email t@t; git config user.name t` right after `git init`.

### Backslash-escaped quotes inside an f-string `{}` are a SyntaxError on Python <3.12

`f"...{p[\"key\"]}..."` — a backslash-escaped quote inside the `{}` expression part of an f-string — is invalid syntax on Python <3.12 ("f-string expression part cannot include a backslash"). CI runners may run either version depending on the workflow's `setup-python` pin, and a version using this idiom can pass a BATS test that only exercises the surrounding function (not the actual print path) while crashing with a real SyntaxError when invoked for real.

**How to apply:** in any embedded `python3 -c '...'` one-liner, never nest a dict/attribute access needing an escaped quote inside an f-string's `{}`. Use `.format(...)` or assign to a plain variable first instead — both work identically on every Python version.

## Claude Code / session mechanics

### A foreign idle Claude Code session's liveness is not detectable

Detecting whether *another* Claude Code session is alive on the same host is not feasible on stable, documented signals: the long-lived `claude` binary's environ does not carry the session ID (only ephemeral per-tool-call `bash` children do, and an idle session — model thinking, or waiting on a long external run — has no such child process at any given instant), `/proc/<pid>/environ` is ptrace-gated, and `~/.claude/sessions/<pid>.json` is undocumented/version-fragile internals.

**How to apply:** never base an anti-steal / takeover decision on "is the owning session alive?" — use durable, on-`main` ownership instead (a task claim, not a liveness probe). If you must approximate liveness, use git/PR *progress* (commit/PR `updatedAt`), never a process probe, and fail toward "assume live"/defer.

### ultracode requires a keyword in free-text prompts — it cannot fire in `-p /skill` headless dispatch

Claude Code **ultracode** = `effortLevel:"xhigh"` settings **plus** a separate `ultracode:true` boolean — not an effort-enum value (`CLAUDE_CODE_EFFORT_LEVEL=ultracode` is rejected, and setting that env var at all forces `ultracode:false`). The `ultracode` keyword in a free-text `-p` prompt does orchestrate headless, but keyword-trigger and slash-command dispatch are mutually exclusive in one `-p` prompt: `/ccxp ultracode` dispatches the skill and ignores the keyword; `ultracode /ccxp` fires the keyword but doesn't dispatch the slash command. So a cron's `-p /<skill>` shape can never get ultracode session-mode.

**How to apply:** the only viable path for headless substantive work is baking orchestration into the skill itself — a skill whose own instructions tell the agent to call the `Workflow` tool directly (see `/drive` Phase 3.1: an always-on, strictly-sequential design→implement→test→verify Workflow for code-class tasks). Confirm it's actually orchestrating by grepping the session log for `TOOL Workflow`.

## Release / CI mechanics

### `sync-tasks@v4` reconcile mode takes ~12 minutes, not seconds

The `actions/sync-tasks@v4` action in `reconcile` mode does a full-repo sweep (re-discovers every task folder, reconciles each mirror issue) and takes roughly 12 minutes per run — even when it changes little. By contrast `dry-run`/`sync` modes finish in ~20 seconds. A long-running `sync-tasks-to-issues` workflow run on `mode=reconcile` is normal, not a hang. This duration scales with repo task/issue count.

## Slack

### Use mrkdwn `<url|text>` links, not markdown `[text](url)`

For clickable links in Slack messages, use Slack mrkdwn `<url|text>` — not markdown `[text](url)`. Verified by sending both formats through both delivery paths: the `/slack` webhook renders `[text](url)` **literally as text** (only mrkdwn is clickable there), while MCP `slack_send_message` accepts both. `<url|text>` is the one format portable across both paths — use it for any skill posting links to Slack.

## Claiming / installing

### A missing skill/plugin dependency should be installed, not just reported

When a skill's own instructions reference another skill that isn't in the current session's available-skills list (an "Unknown skill: ..." error from the `Skill` tool), don't just report it as unavailable and move on. Either install it directly if there's a safe path, or — if installation requires a user-run slash command (e.g. `/plugin install <name>@<marketplace>`, which the `Bash` tool cannot execute since it's a CLI REPL command, not a shell command) — give the exact, ready-to-run install command so the user can act on it immediately rather than being left to figure out the fix themselves.

## 1Password CLI

### `op` fails with "multiple accounts found" and no hint which to pick

A machine signed into more than one 1Password account fails a bare `op signin` (or `op vault list`, `op item list`, …) with a "multiple accounts found" error that doesn't say which account to pick. Always disambiguate explicitly:

```bash
op signin --account <your-org>.1password.com
```

**Symptom**: `[ERROR] 1234 multiple accounts found, specify the one to sign in to with
--account` (or similar) from a plain `op` call that looks otherwise fine.

**Why**: `op` has no default-account concept once more than one account is registered on
the machine; every command that needs a session must say which account explicitly.

### `eval "$(op signin ...)"` must run in the same shell invocation as the command that uses it

`op signin`'s non-interactive model exports a session token that only the *current* shell
sees — splitting the `eval` and the command that consumes it across two invocations
(e.g. two separate tool calls) loses the token:

```bash
# Works — eval and the op call share one shell invocation:
eval "$(op signin --account your-org.1password.com)" && op vault list

# Fails — a separate tool call / subshell doesn't inherit the exported session token:
eval "$(op signin --account your-org.1password.com)"
op vault list   # runs in a fresh invocation -> not signed in
```

**Symptom**: `op` reports "account is not signed in" right after a `signin` call that
appeared to succeed — the error gives no hint that the real cause is a shell-invocation
boundary, not a bad credential.

**Why**: `eval "$(op signin ...)"` works by exporting a session-token env var into the
*current* shell process; it isn't persisted anywhere `op` can pick up from a fresh
process.
