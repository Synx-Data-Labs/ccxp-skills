---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Slack internal-channel whitelist as config read by the /slack script, refusing other channels unless the owner adds them
type: feature
---

# T20261124-181781: Slack internal-channel whitelist as config (d100)

## Problem

- **Type**: feature
- Implements decision d100 (2026-11-12): all our Slack messages are internal; the whitelist of channels the agent may post to is #claude-notification, #slack-automation-alerts and #synxdb-cloud; posting elsewhere needs the owner's approval, and the owner adds channels to the whitelist.
- Today the whitelist is a decision text; the `/slack` script does not enforce it.
- Wanted: a config file (per profile, outside the repo, default shipped with the three channels) that `slack/scripts/*` reads; a post to any other channel is refused with a clear message and a nonzero exit, and only the owner edits the config.
- Bats tests: allowed channel passes, other channel refused, missing config falls back to the default list, malformed config fails closed.
- Retire when shipped: nothing; d100 stays as the rule (owner decides).

## Done criteria

- Whitelist config plus enforcement and bats tests merged; `slack/SKILL.md` documents the config and how the owner adds a channel.
