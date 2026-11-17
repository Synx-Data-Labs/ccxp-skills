---
name: routine
description: Use when the user explicitly asks to list, show, run, enable, disable or see the last report of a configured routine (a named, scheduled sequence of skills such as the inbox or nightly check)
argument-hint: "list | show <name> | run <name> [--dry-run] [--key <key>] | enable <name> | disable <name> | last <name>"
---

# /routine

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Runs and manages routines: named step lists defined by part 1 (`agent-pairing/rituals.md` "Routines", `routine-due.sh`). A step is one Skill-tool call of a named skill with static args. This skill records what happened; it never decides whether a routine is due.

- `RR=<skills-root>/routine/scripts/run-routine.sh` (keep cwd on the working repo; add `--repo DIR` to name another).
- `RD=<skills-root>/agent-pairing/scripts/routine-due.sh`.

## Argument

- `list`: `bash $RR list` prints `name<TAB>enabled<TAB>schedule<TAB>last status and time`. Show it as a table.
- `show <name>`: `bash $RD show <name>` (the merged definition). Say which layer each key came from by reading `dev/.routines.yml` and the profile file `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-routines.yml`.
- `enable <name>` / `disable <name>`: `bash $RR enable|disable <name>`. This writes the machine-local profile file only, never the plugin defaults or the tracked `dev/.routines.yml`; a disable is a local override and the tracked file still lists the routine as enabled.
- `last <name>`: `bash $RR last <name>`; print the summary line and the step outcomes. Exit 3 means no run yet.
- `run <name> [--dry-run] [--key <key>]`: see Workflow. `--key` is the claim key `routine-due.sh claim` printed, passed by the persona job; absent on a manual run, which touches no claim.

## Workflow (`run`)

1. **Plan**: `bash $RR plan <name>` prints the steps (`index<TAB>skill<TAB>args`). With `--dry-run`, print them with the routine's `on_failure` and `report` (from `bash $RD show <name>`) and **stop: nothing is written, no skill is called, no claim is touched.**
2. **Begin**: `bash $RR begin <name> [--key <key>]` prints the key to use (`manual-<epoch>` without `--key`). A disabled routine still runs when asked by hand; mention it.
3. **Steps, in order**: for each step call the named skill through the Skill tool with its args (a fresh sub-agent per step where one is available; under the persona the whole run is one worktree job with `CCXP_CRON_MODE=1` in its prompt, so skills take their unattended defaults). Classify the result and record it: `bash $RR step <name> <key> <index> <outcome> "<one-line note>"`.
   - `ok`: the step did its work. `nothing-to-do`: nothing needed doing. `failed`: error or crash. `needs-human`: the skill said it cannot proceed unattended; put the question in the note.
   - The note is one line, no mail or chat text, customer names aliased (`dev/guidelines.md`). The script caps it at 200 characters.
   - `step` prints `continue` or `stop`: obey it. Under `on_failure: stop` (default) a `failed` or `needs-human` step prints `stop`; skip the remaining steps (do not record them, `finish` marks them skipped). Under `continue` it always prints `continue`.
4. **Finish**: `bash $RR finish <name> <key> "<one-line summary>"` rolls up the run (`ok`, `partial`, `failed`, `needs-human`) and calls `routine-due.sh done` or `release` itself:
   - no failed step: `done` (so `needs-human` is reported once and never retried, and is not an error);
   - a run that fails with nothing done (or with no step recorded at all, e.g. an aborted runner) rolls up `failed`; any mix with a success or a skipped tail is `partial` (a failed first step under `stop` is `partial` because the rest was skipped);
   - a failed step under `stop`: `release` (due again at the next check); once the run has been attempted 4 times (the first run plus 3 retries) it prints `claim=capped`, still releases, and the persona must stop re-launching it: `bash $RR attempts <name> <key>` exits 1 at the cap. Check it right after `claim`; when capped, run `bash $RD release <name> <key>` to drop the fresh claim (nothing waits for the TTL) and list the routine under Next;
   - a failed step under `continue`: `done` after the last step ran, so a flaky step does not re-fire the whole routine;
   - a manual run (`manual-` key): no claim call at all. A crashed job leaves no `done`; the 6 h TTL of part 1 supersedes the claim.
5. **Report** per the routine's `report:` (the record file is always written, so `last` and `/ccxp` standup can cite it):
   - `slack`: one message through `/slack` to the configured notification channel only (d1-8 whitelist), carrying the summary and the status, never a step's raw output. A step whose skill already posts (`/email-triage` DMs unless `--no-slack`) must be declared with its no-post flag in the routine's `args` when `report: slack`, so there is one message. If no channel is configured, skip the post and say so.
   - `journal`: a `dev/JOURNAL/` entry through the repo's usual docs PR path, only for a repo routine (`scope: repo`); otherwise treat as `none`.
   - `none`: the record only.

## Safety

- A step inherits the authorization of the job, nothing more. A routine never publishes, promotes, tags, releases or deletes (`trash.sh` only).
- `allow:` (capabilities beyond what a skill declares) counts only from the profile file; part 1's loader drops it from the tracked and default layers with a warning. Check with `bash $RR allowed <name> <capability>` (exit 0 = granted). `send` is never grantable.
- Never ask a question mid-run when unattended; a step that cannot go on is `needs-human`.

## Important Notes

- `last` reads `${CCXP_ROUTINES_RUN_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-routines}/<repo-key>/<routine>-<key>.json`; the record holds step outcomes and one summary line, nothing else.
- Starter routines (`inbox`, `nightly-check`, `alerts`, `standup`, `today`, `waiting`) are defined in later parts; a step that must fan out is a skill that does its own detection.
