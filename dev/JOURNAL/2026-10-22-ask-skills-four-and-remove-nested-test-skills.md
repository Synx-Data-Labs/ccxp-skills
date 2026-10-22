# Ask-list: add four skills; remove nested-invocation test skills

- **Ask-list**: `agent-pairing`, `cleanup-branch`, `epic`, `to-task` added to `hooks/ask-skills.txt`
  - They were `disable-model-invocation: true` before PR #411 and became prompt-free
  - New bats tests check every listed skill gets an `ask` and exists as a directory
- **Removed**: `_test-nested-invoker`, `_test-nested-target`
  - They probed a flag that no longer exists
  - Dropped from `dev/quality/skill-scores.json`; ratchet still passes
