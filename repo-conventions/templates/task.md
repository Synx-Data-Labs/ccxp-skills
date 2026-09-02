---
status: Open
estimation: 2h
# Optional — delete the lines you don't use:
# deadline: 2026-06-30         # hard date (release / compliance / customer) — informational, does not affect queue order
# blocks: [T20260101-000001]   # task IDs that depend on THIS one (bidirectional)
# blocked-by: T20260101-000002 # the task blocking this one (pair with its blocks:)
# source: Retro 2026-06-09     # one-line origin (retro / RCA run / ticket / conversation)
# related: T20260101-000003    # see-also, non-blocking
# owner: Your Name             # who is driving it
# description: one-line gloss  # optional short summary
# target-repo: your-org/<repo>   # cross-repo: where the code change lands
#   (never your-org/ccxp-skills — that repo hosts its own dev/TODO now;
#   file work about it directly there, see its lifecycle.md § "Tasks about
#   ccxp-skills itself")
# target-path: /abs/path/to/<repo>     # only when reusing an existing checkout with WIP
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

- Required frontmatter: `status` (Open|Design|Coding|Review|Blocked by T{id}|Parked|Done)
  and `estimation` (15m|30m|1h|2h|4h|1d|2d|1w). Everything else is optional.
- Bullets, not paragraphs, in every section — ~3 per level, nest a sub-list
  instead of running past that or folding detail back into prose. See
  `templates/guidelines.md`'s Documentation section for the canonical wording.
- A `BLOCKED` or `SUPERVISED` substring anywhere in `status:` (e.g.
  `Coding — SUPERVISED (needs VPN to GitLab)`) tells the consumer repo's `/ccxp`
  pre-flight gate not to wake an hourly cron session for this task.
- Generate {ID} with `bash ~/.claude/skills/_taskid/new.sh --check ./dev`.
- Do NOT add a `scheduled:` line by hand — only the IPM commit writes it, for
  whichever tasks land in that week's iteration; it is update-forward-only
  and never removed.
- Run `/stage T{ID}` to add this task to `dev/TODO/queue.md` (or just run
  `/todo sweep`, which picks up any untracked task automatically). New tasks
  always enter at the end of the queue; use `/top T{ID}` if it needs to jump
  the line.
- To mark a dependency, set `status: Blocked by T{id}` on the blocked task AND add
  this task's ID to the blocker's `blocks:` list (both directions).
- As the task enters `/drive`, grow this body into the full design using
  repo-conventions/templates/design-doc.md (TLDR · Problem · Context ·
  Solution · Test plan · Done criteria · Closed · Skills invoked; +Root cause
  & Repo refs for code tasks). Keep it a one-pager — right sections, not length.
-->
