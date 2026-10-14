---
name: epic
description: Use when the user explicitly asks to check, refresh, or drive a standing epic (dev/EPICS/E<n>) — per-epic progress, member-link upkeep, or working its member tasks one at a time via /drive
disable-model-invocation: true
# true on purpose: `drive` merges PRs across many tasks, so only the user may start it.
# Nothing nest-invokes /epic (it dispatches /drive, which stays model-invocable).
argument-hint: "status [E<n>] | refresh [E<n>] | drive <E<n>>"
---

Work with the epics in `dev/EPICS/E<n>-*.md` (format: README "dev/EPICS/E*.md" section).

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

All deterministic parts live in `<skills-root>/epic/scripts/epic.sh` (sourceable, tested by `tests/epic.bats`). Run it from the repo toplevel; never `cd` into the skills root.

## Argument

- `status [E<n>]` — read-only progress; no arg = all epics.
- `refresh [E<n>]` — repair member links, propose missing members.
- `drive <E<n>>` — work the epic's tasks one at a time. **Merges PRs.** User-invoked only.
- No arg or an unknown verb: print this list and stop.

## Workflow: `status`

- Run `bash <skills-root>/epic/scripts/epic.sh status [E<n>]`; print verbatim.
- It prints a per-member table (status, `claimed_by`, deadline, drive verdict), then `epic-status.sh render` counts.
- Never edits anything.

## Workflow: `refresh`

1. Run `bash <skills-root>/epic/scripts/epic.sh refresh [E<n>]`. It runs `_taskid/epic-links.sh sync` + `lint`, then reports per epic:
   - moved/closed members (old and new link);
   - plain lines with no task file here (other repo: kept plain, not driveable from here);
   - **candidates**: open `dev/TODO` tasks that are not members but are linked by `related:`/`blocks:`/`blocked-by:` or share a title keyword.
2. Candidates are **proposals only**. List them and ask which to add; never auto-add. Add approved ones with `bash <skills-root>/_taskid/epic-links.sh add E<n> T<id>`.
3. The only file edited is the epic file (links). Land it by the normal branch + PR flow; do not commit to `main`.

## Workflow: `drive <E<n>>`

Sequential: one task at a time, never parallel, a fresh sub-agent per task. Failures never stop the loop.

1. **Plan.** `bash <skills-root>/epic/scripts/epic.sh plan E<n>` — members in **epic-file order** (not `queue.md` order) with a verdict:
   - `drive`: in `dev/TODO`, not done/parked, not claimed by a live peer, no open blocker, not SUPERVISED.
   - `skip` (reason recorded): `done`, `parked`, `peer:<who>`, `blocked:<Tid>`, `supervised`.
   - `external`: no task file here (other repo) — listed as "not driveable from here".
   - Show the plan to the user, then start. No confirmation gate: the user invoking `drive` is the go-ahead.
2. **Loop.** `results=$(mktemp)`; `attempted=""`. Repeat:
   - `id=$(bash <skills-root>/epic/scripts/epic.sh next E<n> $attempted)`; exit 1 means exhausted, go to step 3. It re-reads live state every call, so a merged task that unblocks another is picked up.
   - Dispatch one fresh sub-agent (Agent tool, foreground): *"Run `/drive <id>` to completion in this repo. Reply with only: `MERGED #<pr>` or `FAILED` or `NEEDS INPUT: <question>`, then one paragraph (what happened, where it stopped, the next concrete action)."*
   - Map the reply and record it: `epic.sh record "$results" <id> merged|failed|escalated "<one-line summary>"`; append `<id>` to `attempted`.
   - On `FAILED`/`NEEDS INPUT`: summarize, do **not** stop, do not retry, do not ask the user. Take the next member.
   - Before the next task make sure the checkout is on `main`, up to date, and clean (`/drive` leaves it so; if not, record the leftover and stop dispatching — never stash or reset).
3. **Report.** `bash <skills-root>/epic/scripts/epic.sh report E<n> "$results"` and print verbatim:
   - Merged list, then "for the next iteration" ordered by priority (task `deadline` first, then `queue.md` position), each with its failure/skip reason and next action; then "Not driveable from here".
   - Add a one-line summary of anything that did not fit the table (e.g. leftover checkout state).

## Important Notes

- `drive` inherits `/drive`'s own merge gates (CI, review, tiered merge); `/epic` adds no merge path of its own and never calls `gh pr merge`.
- Peer claims are never overridden; `reclaimable` stale claims are driven like unclaimed ones.
- Only `refresh` writes, and only epic member links. Epic membership is owned by the human: propose, never auto-add.
