# Detached background jobs (`claude --bg`) for ccxp-agent

Runbook for the dispatcher persona (`assets/ccxp-agent.md`). Verified on
`claude` 2.1.307 on 2026-10-22; `--bg` is a research-preview feature, so
re-probe after a major upgrade.

## When to detach

- **Detached `--bg` job**: builds, promotes, nightly/release work, waits over ~10 minutes, anything that must survive restarting the dispatcher.
- **In-process Agent-tool subagent**: short read-only lookups and quick edits in an isolated worktree.
- Both kinds use the same ledger number; a detached job's name is `j<N>-<slug>`.

## Launch

```bash
bash <skills-root>/agent-pairing/scripts/job-launch.sh <N> "<title>" <prompt-file> \
  [--cwd DIR] [--add-dir CLONE] [--allow 'Bash(make test *)'] [--env NAME] [--model M]
# -> JOB 52 name=j52-remove-pr-approve id=ab12cd34 dir=/tmp/ccxp-jobs/j52-...
```

- Writes `$TMPDIR/ccxp-jobs/<name>/{prompt.md,settings.json,job.json}` (dir 0700, settings 0600), runs `claude --bg --agent claude --permission-mode dontAsk --settings ... -- "<prompt>"`.
- Default settings: narrow allow-list (Read/Grep/Glob/Edit/Write, read-only git and gh, `git add`/`commit`); deny `git push`, `gh pr create|merge`, `gh workflow run`, `gh release`; `crossSessionInbound: accept`; a Stop hook that writes `last-stop`.
- Prompt file: same rules as an Agent-tool job prompt (goal in the user's words, limits, `NEEDS INPUT: <question>` convention, report of at most 10 lines, consent quoted).
- Authorization (the only way to lift a deny), a section in the prompt file:

```markdown
## Authorization
> "yes, push the branch and open the PR"   <- the user's own words, quoted
allow: push
allow: pr-create
```

Tokens: `push`, `pr-create`, `pr-merge`, `workflow-run`. `allow:` lines without a quoted `>` line, or an unknown token, abort the launch.

- `--env NAME` copies the value from the launching shell into the 0600 settings file (never argv, stdout or the prompt). Shell env is not inherited otherwise. Prefer jobs that fetch their own credentials (1Password) over `--env`.

## Observe and answer

```bash
bash <skills-root>/agent-pairing/scripts/job-status.sh [N|name] [--report]
bash <skills-root>/agent-pairing/scripts/job-resume.sh <N|name> "<user's answer>"
```

- `job-status.sh` prints `#N name state/status [waiting:...] id` for names `j<N>-*` only; `--report` prints the job's last assistant message from its transcript.
- `claude agents --json --all` states: `working/busy`, `done/idle` (also `failed` when the job's final line starts with `failed:`), `blocked/waiting` with `waitingFor: permission prompt`, `stopped`.
- Completion without polling: a finished job wakes the dispatcher only through cross-session messages (the job can `SendMessage` the dispatcher by its session name; same permission class, or the dispatcher accepts inbound). The dispatcher (main conversation only) can subscribe with `SendMessage ... notify_when_idle: true`. Otherwise check `job-status.sh` at the start of a turn and when asked; never loop.
- `NEEDS INPUT`: relay the question, then `job-resume.sh`. It stops the live process, waits, and wakes the SAME session with its saved options.
- `claude logs` is a raw screen dump; prefer `--report`.

## Dispatcher restart

- Jobs keep running. List `job-status.sh`, rebuild the ledger from names (`j<N>-<slug>`: number and title), re-subscribe with `notify_when_idle` for jobs still working, and continue numbering above the highest `N` seen.

## Verified facts and limits (from probes)

- `--bg` works from a Bash tool and survives the launching process; accepts `--permission-mode`, `--allowedTools`, `--disallowedTools`, `--settings`, `--add-dir`, `--model`, `--append-system-prompt`, `--plugin-dir`, `--agent`.
- `--add-dir` and `--allowedTools` are variadic and swallow a trailing prompt: the launcher passes the prompt after `--`.
- Jobs inherit the user's default agent (`ccxp-agent` would recurse as a dispatcher): the launcher passes `--agent claude`.
- Shell env vars are NOT inherited; the settings `env` block is.
- Workspace trust: a fresh git root (a /tmp clone, or a clone under a trusted dir) fails with `Workspace not trusted`. A non-git directory under an already trusted parent works. Use `--cwd <trusted non-git dir> --add-dir <clone>`, or accept the trust prompt once by hand. The launcher exits 3 with this hint.
- A job needing a permission prompt stalls (`blocked`, `waitingFor: permission prompt`); a message cannot approve it, so only `claude attach <id>` answers. Pre-scope the allow-list instead.
- `--resume` with any flag, or on a live process, starts an unsandboxed COPY; `job-resume.sh` stops first and passes no flags.
- A dispatcher in a different permission mode than the job has its messages held for approval unless the job's settings carry `crossSessionInbound: accept` (the launcher sets it). A message is never consent.
- Hooks in the per-job settings fire (Stop, Notification, SessionEnd). `agent_completed` on the dispatcher side and a job messaging its dispatcher were not tested.
- Deny rules hold even when the prompt asks for the denied command.
- Fallback if `--bg` is unavailable: `claude -p` in a herdr pane with the same settings file; not scripted here.

## Optional window: herdr

Only inside herdr (`test "${HERDR_ENV:-}" = 1`); never run bare `herdr`.

```bash
P=$(herdr pane split --current --direction down --no-focus | jq -r .result.pane.pane_id)
herdr pane run "$P" "claude attach j52-remove-pr-approve"   # live view; Ctrl+Z / close the pane to leave
herdr pane close "$P"
```

The job keeps running when the pane closes.
