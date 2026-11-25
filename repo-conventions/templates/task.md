---
status: Open
estimation: 1
# Optional — delete the lines you don't use:
# deadline: 2026-06-30         # hard date (release / compliance / customer) — informational, does not affect queue order
# blocks: [T20260101-000001]   # task IDs that depend on THIS one (bidirectional)
# depends_on: [T20260101-000002] # tasks this one waits on (pair with their blocks:); keep your real status
# needs: [human]               # human-only condition: human|vpn|owner-decision|person:<alias>|ext:<text>
# source: Retro 2026-06-09     # one-line origin (retro / RCA run / ticket / conversation)
# related: T20260101-000003    # see-also, non-blocking
# owner: Your Name             # who is driving it
# description: one-line gloss  # optional short summary
# target-repo: your-org/<repo>   # cross-repo: where the code change lands
#   (never your-org/ccxp-skills — that repo hosts its own dev/TODO now;
#   file work about it directly there, see its lifecycle.md § "Tasks about
#   ccxp-skills itself")
# target-path: /abs/path/to/<repo>     # only when reusing an existing checkout with WIP
# source-url: <canonical URL> # generic intake task (written by /to-task; dedup key)
# support-issue: <canonical issue URL> # legacy alias for source-url, pre-dates the /support -> /to-task rename
# when: 2026-11-14T14:00       # time to act: YYYY-MM-DD or YYYY-MM-DDTHH:MM (optional Z/offset) — never reorders the queue
# when-end: 2026-11-14T15:00   # optional end of a window (not before `when`)
# place: [office, vpn]         # context needed to do the work (slugs); absent = anywhere
# person: [person-a]           # aliases involved (call, review, handoff) — never emails or real names
# type: feature                # chore|feature|bug|event|research|spike|rca|support|other; `event` needs `when`
#   (waiting on someone: `needs: [person:<alias>]` or `needs: [ext:<text>]`)
# tier: 3                     # autopilot tier 1..4 (1 urgent: red nightly and the like; 2 support issues; 3 default when absent; 4 low) — omit unless the owner states one
# support-report: on                   # opt in to outward status reports (default off; later phase)
#
# Runtime fields written by tooling — do NOT hand-author:
#   scheduled (IPM only), claimed_by (/drive)
#
# There is no `priority:` field. Priority is your position in dev/TODO/queue.md
# (see /todo) — `/stage` appends this task to the end once filed; `/top` moves
# it to the front if it needs to jump the line.
---

# T{ID}: {one-line title}

## Problem

{What's wrong or what's needed — bullets, not a paragraph, with evidence (a
file:line, a failing command, a quoted requirement). Say what "done" looks like.}

<!--
SCAFFOLD NOTES (delete this block once the task is filed):

- Required frontmatter: `status` (Open|Design|In Progress|Review|Blocked by T{id}|Parked|Done)
  and `estimation` — a Fibonacci-style point value (1|2|3|5|8). Always file at `1`;
  `/incept` is the only place a point value is revised upward, once grilling
  surfaces real scope. Everything else is optional.
- Bullets, not paragraphs, in every section — ~3 per level, nest a sub-list
  instead of running past that or folding detail back into prose. See
  `templates/guidelines.md`'s Documentation section for the canonical wording.
- Words in `status:` such as `BLOCKED`, `SUPERVISED`, `needs manual` or `sign-off`
  gate nothing; only `Blocked by T{id}` (or `depends_on:`) keeps a task out of auto-pick.
- Generate {ID} with `bash _taskid/new.sh --check ./dev`, resolved relative
  to wherever the ccxp-skills plugin is installed (a loaded skill's own
  directory, printed as "Base directory for this skill" — not a hardcoded
  path).
- Do NOT add a `scheduled:` line by hand — only the IPM commit writes it, for
  whichever tasks land in that week's iteration; it is update-forward-only
  and never removed.
- Run `/stage T{ID}` to add this task to `dev/TODO/queue.md` (or just run
  `/todo sweep`, which picks up any untracked task automatically). New tasks
  always enter at the end of the queue; use `/top T{ID}` if it needs to jump
  the line.
- To mark a dependency, add the dependency's ID to this task's `depends_on:` AND this
  task's ID to the dependency's `blocks:` (both directions); keep the real `status:`
  (`Blocked by T{id}` is deprecated).
- As the task enters `/drive`, grow this body into the full design using
  repo-conventions/templates/design-doc.md (TLDR · Problem · Context ·
  Solution · Test plan · Done criteria · Closed · Skills invoked; +Root cause
  & Repo refs for code tasks). Keep it a one-pager — right sections, not length.
-->
