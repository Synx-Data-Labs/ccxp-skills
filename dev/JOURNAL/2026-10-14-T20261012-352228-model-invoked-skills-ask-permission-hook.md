---
status: Done
estimation: 1
source: this conversation, 2026-10-12 (Job 28 research on whether Claude Code supports "ask" for skills)
claimed_by:
claimed_role:
scheduled: 2026-10-12
---

# T20261012-352228: Make model-invoked skills ask the user for permission instead of being blocked

## Problem

- **Type**: feature
- Want: when the model calls a sensitive skill, the user is asked for permission, rather than the skill being invisible to the model.
- Today 6 skills set `disable-model-invocation: true`: autopilot, bottom, cleanup-branch, memory-to-skill, agent-pairing, _test-nested-target (33 more set it false, 11 leave it absent; 50 SKILL.md total).
- That flag removes the skill from the model's context entirely, so the model cannot even request it.
- Idea: remove the flag on the chosen skills and ship a PreToolUse hook (matcher `Skill`) that returns `permissionDecision: "ask"` for a configured list.
- Done looks like: chosen skills prompt the user when model-invoked, user-typed `/skill` is unaffected, and the hook ships with the plugin.

## Context

- **Verified (official docs: permissions.md, skills.md, hooks.md, plugins/manifest-reference.md)**:
  - No frontmatter key requires confirmation.
  - `disable-model-invocation: true` removes the skill from the model's context.
  - Permission rule evaluation order is deny > ask > allow.
  - A PreToolUse hook with matcher `Skill` can return `permissionDecision: "ask"`.
  - Plugins can ship hooks (`hooks/hooks.json`) but NOT permission rules; the alternative is `ask` rules in project `.claude/settings.json`.
- **Not verified (inferred or undocumented)**:
  - Rules `Skill(name)` / `Skill(name *)` appear in docs only under allow/deny; `ask` prompting is inferred.
  - Plugin-namespaced matching such as `ccxp-skills:agent-pairing` is undocumented.
  - A PreToolUse hook should fire only on model calls, with user-typed `/skill` skipping it; docs are silent.
  - Hook stdin field for the skill name is likely `tool_input.skill`, UNVERIFIED.
- **Code mentions to update** (other docs not yet grepped):
  - `skill-conventions/scripts/skill_score.py:155-156` awards 2 points for the key being present ("argument-hint + explicit disable-model-invocation").
  - `skill-conventions/scripts/test_skill_quality.py:18` fixture.
  - Possibly `skill-conventions/SKILL.md` and docs inside skill dirs.

## Work items

- **First: spike to verify the unknowns**
  - Hook input field name for the skill name.
  - Plugin-qualified name matching.
  - Whether `ask` prompts under headless `-p`, and is auto-denied under `dontAsk` mode.
  - That typed `/skill` skips the hook.
- Then: remove `disable-model-invocation` from the chosen skills, add `hooks/hooks.json` plus a script returning ask for a configured list.
  - The model still sees these skills in its list once the flag is removed, so descriptions must say when to use them.
  - Update `skill_score.py` and its test fixture for the changed scoring rule.

## Open question

- Which of the 6 skills go to "ask" vs stay blocked? autopilot and cleanup-branch may be better left fully blocked.

## Spike results (2026-10-14, claude 2.1.300, verified by running `claude -p`)

- **Hook stdin field**: `tool_input.skill` (plus `tool_name: "Skill"`, optional `tool_input.args`). Verified.
- **Plugin-qualified name**: a plugin skill arrives as `<plugin>:<skill>` (e.g. `spk:pdemo`); the hook strips the prefix and matches the bare name. Verified with `--plugin-dir`.
- **Typed `/skill` skips the hook**: `claude -p "/demo"` ran the skill and wrote no hook stdin. Verified.
- **Headless `ask`**: under `-p` the call is denied (appears in `permission_denials`, reason shown to the model); `--permission-mode dontAsk` is the same. Verified. The interactive TUI prompt was NOT exercised (no TTY here); relies on the documented `ask` semantics.
- **Plugin hook end-to-end**: `claude -p --plugin-dir <repo>` calling `ccxp-skills:autopilot` hit `hooks/hooks.json` and returned the hook's reason. Verified.

## Decision

- **ask list** (`hooks/ask-skills.txt`): `autopilot` (user-requested, so the dispatcher can call it), `bottom`, `memory-to-skill`; each flipped to an explicit `disable-model-invocation: false`.
- **Stay blocked**: `cleanup-branch` (destructive), `agent-pairing` (rewrites profile settings; its SKILL.md says the user alone decides), plus `epic`, `to-task`, `skill-conventions`, `_test-nested-target`, untouched.
- **`skill_score.py` unchanged**: it awards points for the key being present, and `false` still counts, so no scoring-rule or fixture change is needed.
- **Design PR skipped**: estimation 1, approach specified by the user, spike recorded here.
- **Manual step (not done here)**: none required for the plugin path. Users not using the plugin install can copy the hook into their own settings.

## Closed (2026-10-14)

- Shipped in the implementation PR that moves this file to `dev/JOURNAL/`: `hooks/{hooks.json,skill-ask.sh,ask-skills.txt}`, `tests/skill_ask_hook.bats`, docs in `README.md` and `skill-conventions/SKILL.md`.
- Unverified: the interactive permission dialog itself.
