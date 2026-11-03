---
status: Open
estimation: 1
source: conversation 2026-11-02 (owner's redesign of the 5.9.0 autopilot, T20261102-261809)
related: T20261102-261809
description: autopilot drives from the top of queue.md; a task it cannot advance is /bottom'ed and parked after 3 visits; no status marker in task files
---

# T20261102-296642: autopilot: drive from the top of queue.md; a no-progress task is /bottom'ed and parked after 3 visits (no status marker in task files)

## Problem

- **Type**: feature
- Owner's words (2026-11-02), verbatim:
  > here is my design, don't put that status in the task file. I want the autopilot to be able to drive the task as much as possible. Since queue.md is the record of priority, if a task indeed blocked (by human or not), then /bottom the task, and continue move to the next. We can record how many times the /autopilot visited the task, and if we already visited 3 times, and still cannot push the task forward, we can park them. I don't worry high priority tasks, since if it's high priority, I will ping you more often, and will drive them personally.
- This replaces the 5.9.0 design (T20261102-261809, PRs #545 to #548): a `needs a human` suffix written into each task's `status:` line, `todo/scripts/needs-human.sh`, `todo-next.sh --skip-needs-human`, `autopilot-state.sh pickable/marked/attention-list`.
- Done looks like: no marker and no skip list anywhere; a no-progress cycle ends with the task `/bottom`'ed and a local visit counter bumped; the third no-progress visit parks the task; reports list what was parked.
