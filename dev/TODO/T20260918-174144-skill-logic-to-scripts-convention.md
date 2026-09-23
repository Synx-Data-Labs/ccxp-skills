---
status: Open
estimation: 1h
source: this conversation, 2026-09-18
related: T20260914-359646
claimed_by:
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-174144: Document convention: move deterministic skill logic into bundled scripts

## Problem

- **Type**: chore
- `skill-conventions/SKILL.md` has no rule for this pattern yet (checked: no
  mention of "bundle"/"token-free"/"token-optim")
- `T20260914-359646` already applies the exact pattern to `/todo next` and
  `/todo list` — porting deterministic queue-walk/table logic into
  sourceable scripts so neither costs an LLM turn — but it's a one-off task,
  not a documented convention future skill authors know to follow
- Maintainer wants this codified in `skill-conventions/SKILL.md`: when a
  SKILL.md workflow step is deterministic/mechanical (no judgment calls
  involved), it belongs in a bundled script the skill invokes — not markdown
  logic the LLM re-derives on every run — to save tokens
- Maintainer also wants a required validation step: any such conversion must
  prove behavior parity (e.g. BATS tests comparing the script's output
  against the skill's own prior real invocations) before the SKILL.md is
  switched over to invoke the script — mirroring `T20260914-359646`'s own
  test-plan pattern
- Done looks like: `skill-conventions/SKILL.md` has a new section stating
  the rule plus the required behavior-parity validation step, citing
  `T20260914-359646` as the worked example
