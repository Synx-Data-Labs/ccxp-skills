# Task per job

Every job that changes a repo gets a task in that repo, so the owner's goal and the decisions made in chat land in git (task file, design section, journal) and not only in a job report. The persona's "Writing a job prompt" has the one-line rule; this page has the detail. Task T20261121-412600.

## When it applies

- A job that will write, edit, stage, commit or check out a branch in a repo that has a `dev/TODO/` directory.
- The dispatcher checks with a read-only `ls <repo path>/dev/TODO` (the repo path comes from "Repo context per job"). No directory, no task: the rule never applies to a repo without the conventions layer.

## What the job does first

- Step 1: `/new-task` with the goal in the owner's own words plus the decisions made in chat. If a task for this work already exists (the owner named one, or `ls dev/TODO` shows it), reuse it and skip `/new-task`.
- Step 2: `/drive T<id>` to completion, through the Skill tool. The task file, design section and journal then carry the decisions; merges go only through `/address-pr`.
- Step 3: once the task exists, repeat the ledger start line with `--task T<id>` (a repeated `start` keeps everything else stored).

## Exceptions (tight and explicit)

- Read-only jobs (research, lookups, reports that write nothing in the repo).
- Machine-state jobs (disk cleanup, installs, settings, profile moves).
- Pure ledger or decision bookkeeping.
- Mechanical queue moves: `/top`, `/bottom`, `/stage`.
- The owner typed a skill command that already runs the lifecycle: `/drive`, `/address-pr`, `/land` (the persona already tells the job to run it verbatim).
- A repo without `dev/TODO/`.

An exception is declared, not silent: the dispatcher passes `--no-task "<reason>"` to `ledger.sh start` for a repo-changing job that is exempt (see `hud/scripts/ledger.md`, "Task per job").

## Decisions into git

- The owner's chat decisions (and the d-refs from the decisions log that cover the area) go into the task's design/decisions section, the d-ref and the owner's words quoted.
- The decisions log itself (`ccxp-decisions.json`) is machine state and not in git; the task file is where the history lives.
- Update the section at each milestone, not only at the end; a job that learns a new decision from its prompt writes it in the same way.

## Keeping the overhead low

- A tiny job still files a task: `/new-task` is a short back-and-forth, files at `estimation: 1`, and the job drives it as `estimation: 1`.
- If the job is really an exception, say so in `--no-task` instead of skipping the check.
