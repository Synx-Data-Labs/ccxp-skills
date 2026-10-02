---
status: Open
estimation: 1
source: 75033us/trade /memory-to-skill run, 2026-10-02
related: T20260925-427007
---

# T20261002-303999: Resolve Claude config paths via $CLAUDE_CONFIG_DIR, not hardcoded ~/.claude

## Problem

- **Type**: bug
- Scripts hardcode `$HOME/.claude`, but Claude Code honors
  `$CLAUDE_CONFIG_DIR` (e.g. `~/.claude-personal` for a second account),
  so a non-default session reads/writes the wrong tree
- Repro (2026-10-02, session with `CLAUDE_CONFIG_DIR=~/.claude-personal`):
  - `memory-to-skill/scripts/find-memory-dir.sh` defaulted
    `claude_home="${HOME:-}/.claude"` and exited 1 "no memory directory",
    though memory existed under `~/.claude-personal/projects/.../memory`
  - `/memory-to-skill` would have reported "no memory to review" and stopped
- Already noted, untracked: `dev/quality/skill-review-2026-09-28/batch4.md:92`
  (same review also flags `.`/`_` path-encoding drift)
- Other hardcoded `~/.claude` sites to triage (some may intentionally be
  machine-global, decide per site):
  - `_session/_lib.sh:53,110`, `_session/claimant-id.sh:30`
    (`.env`, `state/session-id`)
  - `_session/task_claim.sh:516`, `_session/attribution.sh:63` (`.env`)
  - `_session/lint_frozen.sh:42` (`skills/` path; overlaps T20260925-427007)
- Done when:
  - `find-memory-dir.sh` defaults to `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`,
    with a BATS case for the env override
  - Each other site either honors `CLAUDE_CONFIG_DIR` or carries a comment
    saying why it is deliberately machine-global
