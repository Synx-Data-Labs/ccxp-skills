---
name: slack
description: Use when the user explicitly asks to send a Slack notification to the configured channel
disable-model-invocation: false
argument-hint: "--channel <name> <message>"
---

Send a Slack notification to a specified channel.

## Channels

There is no fixed channel list — `--channel <name>` accepts any name and maps to the env var
`SLACK_WEBHOOK_URL_<NAME>` (name uppercased, e.g. `--channel foo` → `SLACK_WEBHOOK_URL_FOO`).
No `--channel` at all (the default) uses the plain `SLACK_WEBHOOK_URL` var, unsuffixed, for
backward compatibility with the original single-channel skill. Onboarding a new channel is just
exporting its webhook under a new `SLACK_WEBHOOK_URL_<NAME>` var — no skill change required.

Example usage (illustrative, not the only options):

| Name | Channel | Env var | Purpose |
|------|---------|---------|---------|
| *(none — default)* | `#slack-automation-alerts` | `SLACK_WEBHOOK_URL` | Automation alerts, build notifications, testing |
| `cloud` | `#acme-cloud` | `SLACK_WEBHOOK_URL_CLOUD` | Release announcements only — use sparingly |
| `dev` | `#claude-notification` | `SLACK_WEBHOOK_URL_DEV` | Webhook fallback when MCP `slack_send_message` fails (see `ccxp/SKILL.md` Phase 1.4, T20260717-433409) — not for routine use, MCP is still the default path for this channel |

## Argument

`$ARGUMENTS` contains:

- Optional channel: `--channel <name>` — any name, maps to `SLACK_WEBHOOK_URL_<NAME_UPPERCASED>` (default: absent, uses plain `SLACK_WEBHOOK_URL`)
- Then either a plain text message or structured flags:
  - `/slack hello world`
  - `/slack --channel cloud --product "AcmeDB Cloud" --version "0.5.0" --status success`

## Prerequisites

`SLACK_WEBHOOK_URL` must be available for the default (no `--channel`) case; each named channel
additionally needs its own `SLACK_WEBHOOK_URL_<NAME>`. The script searches in this order, first
hit wins:

1. Already-exported env var
2. `~/.claude/.env` (recommended — machine-global, works from any consumer repo)
3. `$(pwd)/.env` (consumer repo's env, back-compat)

```
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...        # default, e.g. #slack-automation-alerts
SLACK_WEBHOOK_URL_CLOUD=https://hooks.slack.com/services/...  # --channel cloud, e.g. #acme-cloud
SLACK_WEBHOOK_URL_DEV=https://hooks.slack.com/services/...    # --channel dev, e.g. #claude-notification
```

## Workflow

1. Parse `$ARGUMENTS` for `--channel <name>`. If present, remove it from args.
2. Map the channel name to an env var, generically:
   - Absent → `SLACK_WEBHOOK_URL` (default, unsuffixed, back-compat)
   - Given → `SLACK_WEBHOOK_URL_<NAME_UPPERCASED>` (e.g. `--channel foo` → `SLACK_WEBHOOK_URL_FOO`; any name works, there is no fixed set)
3. Run the script with the selected webhook:

```bash
# Default (no --channel):
bash ~/.claude/skills/slack/scripts/slack-send.sh <remaining args>

# Named channel, e.g. --channel foo:
SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_FOO" bash ~/.claude/skills/slack/scripts/slack-send.sh <remaining args>
```

(The script loads `~/.claude/.env` itself, so no `source .env` wrapper is needed.)

4. Report the result to the user.

## When to notify proactively

Send a Slack notification whenever a long-running operation (CI run, build, pipeline dispatch) completes or needs attention — the user isn't always watching the terminal. Trigger this after dispatching workflow runs or waiting on background tasks, not only when explicitly asked.

## Examples

```
/slack hello world                                          # → default (SLACK_WEBHOOK_URL), e.g. #slack-automation-alerts
/slack --channel cloud --product "AcmeDB Cloud" --version "0.5.0" --status success  # → SLACK_WEBHOOK_URL_CLOUD, e.g. #acme-cloud
/slack --channel dev MCP send failed, this is the webhook fallback  # → SLACK_WEBHOOK_URL_DEV, e.g. #claude-notification
/slack --channel foo Deploy finished                        # → SLACK_WEBHOOK_URL_FOO (any name works, not just the examples above)
/slack --product "AcmeWidget4" --version "4.4.0" --status failure --details "Phase 3.3 timeout"
```
