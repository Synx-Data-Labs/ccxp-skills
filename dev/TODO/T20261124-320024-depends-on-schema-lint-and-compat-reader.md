---
status: Open
estimation: 2
blocks: [T20261124-419462]
source: owner request 2026-11-24 (decision d158), epic E3
description: Define the depends_on and needs frontmatter fields, update lint, add a compat reader for legacy Blocked by
---

# T20261124-320024: Spec, depends_on schema, lint and compat reader

## Problem

- **Type**: feature
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Scope: schema and tolerance only; no behavior change for existing files. No edits under `hud/` (other jobs are there) and net-zero prose in SKILL.md files; detail goes in docs and scripts.
- Do:
  - document `depends_on: [T..]` and `needs: [...]` (todo `SKILL.md` Task metadata, `lifecycle.md`, `repo-conventions/templates/task.md` and `guidelines.md`); mark `Blocked by T{id}` deprecated (still valid)
  - lint (`repo-conventions/scripts/lint_tasks.py`): allow both keys; `depends_on` ids must resolve to a task file and not cycle; `Blocked by` gets a deprecation warning, not an error
  - compat reader in `todo/scripts/_lib.sh` (one function): a task's dependencies = `depends_on` plus any legacy `Blocked by T..` in `status:`; `todo-gated` treats a task with only `depends_on` as not gated
  - tests: `test_lint_tasks.py`, `tests/todo-next.bats`, a new bats for the reader
- Resolves epic open questions Q1 and Q2 in its Closed section (or records the owner's answer).

## Done criteria

- Mixed old and new task files lint and pick correctly; new tests green; `claude plugin validate .` clean; no version bump.
