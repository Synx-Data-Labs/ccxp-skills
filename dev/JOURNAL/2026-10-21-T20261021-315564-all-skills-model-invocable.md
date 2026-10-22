---
status: Done
estimation: 2
source: user request, 2026-10-21 ("I want the agent to call all the skills")
claimed_by:
claimed_role:
---

## Problem

- **Type**: chore
- 42 SKILL.md files carried `disable-model-invocation` (37 false, 5 true); the 5 `true` skills were hidden from the agent.

## TLDR

- Removed the line (and attached comments) from every SKILL.md; the default is model-invocable.
- Rationale kept in `skill-conventions` §1: `true` blocks preloading into subagents, and `/autopilot` dispatches a subagent to run `/drive`.
- Dropped the two bats assertions on the flag; `skill_score.py` now awards the 2 invocation points for the flag being absent.
- Ask hook (`hooks/ask-skills.txt`) unchanged: it still gates autopilot, bottom, memory-to-skill.

## Test Plan

- [x] `bats tests/*.bats _docs/*.bats _slack/*.bats`, skill-quality tests, score ratchet.

## Notes

- Gap: agent-pairing, cleanup-branch, epic, to-task are now model-callable with no ask prompt.
