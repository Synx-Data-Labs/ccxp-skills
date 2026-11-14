# Slack alerts check (automatic RCA of #slack-automation-alerts failures)

The ccxp-agent persona reads #slack-automation-alerts and starts one `labrun-rca` job per unanswered failure
alert. Task: T20261113-631854. Owner decision d115 (design and rejected options: T20261112-160248). No cloud
routine, no workflow, no launchd: the persona piggybacks on the places it already wakes up.

## What runs when

- **Check points**: session start (after the resume reconcile), every user turn, every autopilot wake.
- Each check runs `bash <plugin-dir>/agent-pairing/scripts/alerts-due.sh check` (token-free, network-free).
  - Within 5 minutes of the last check it prints nothing and exits 1: the persona does nothing.
  - Otherwise it records the check and prints the read window start: the last-seen ts minus 10 minutes, or `-`.
- **Read**: `slack_read_channel` on #slack-automation-alerts only (owner whitelist d1-8), newest 20 messages, nothing older than the window start. Read tools only; posting stays inside jobs.
- **Candidate**: a bot-authored message announcing a failure (`failed`/`failure`, not success or recovered). Cheap filter; the job decides the rest (branch, already green) and stays silent for a non-failure.
- **Plan**: one whitespace-separated line per candidate, `<ts> <reply_count> <ack_only 0|1> <age_minutes>`, piped to `alerts-due.sh plan`.
  - Handled (no output): the thread has a reply, or a file under `<profile dir>/ccxp-context/` or a ledger row carries the `ts`. A run id alone does not count: a bare `/rca` job of the CI-failure response never replies in the thread, so the alert job still runs and reuses that RCA and task (`/rca` step 3.5).
  - Exception: an ack-only thread (only the "Running RCA" reply) older than 60 minutes with no live job (no context file touched in the last hour, no ledger row) is not handled.
  - Output, oldest first: `dispatch <ts>` for at most 3 alerts, `next <ts>` for the rest (listed under Next).
- Afterwards `alerts-due.sh done <newest ts the read returned>` advances the marker (never backwards). When the cap held alerts back, `done` pins the marker to just before the oldest `next` alert, so the following read sees them again. A state failure makes `check`/`done` exit 3 with a message (exit 1 only ever means "not due"). A read that finds nothing new writes only the marker.
- **Dispatch**: per `dispatch` line one background job, repo context block resolved from the run URL's `owner/repo`, whose prompt runs `/labrun-rca <channel_id> <ts>` through the Skill tool. Job title and context file carry the run id and the `ts`: that is the dedupe record. Pre-authorized: the one thread reply (d2-3) and task filing and driving per the CI-failure rule (d0-4); no publish, promote, tag or release.
- **One path**: when the CI-failure response finds a failed run that has an alert in the channel, it dispatches the `labrun-rca` job instead of a bare `/rca` job. A failed run with no alert keeps the `/rca` job.

## Known limit

The persona runs only while a session is open: no overnight coverage; autopilot wakes give partial cover. The next
check catches up on everything unanswered within the 20-message read plus the 10-minute overlap. An ack-only thread
is re-dispatched only while its alert is still inside that window (the marker moves to the newest message read),
so a dead job on an alert older than about 70 minutes with newer channel traffic is not retried automatically.

## Knobs

`CCXP_ALERTS=0` turns it off. `CCXP_ALERTS_DIR`, `CCXP_CONTEXT_DIR`, `CCXP_LEDGER_FILE` relocate state;
`CCXP_ALERTS_MIN_GAP` (300), `CCXP_ALERTS_OVERLAP` (600), `CCXP_ALERTS_CAP` (3); `CCXP_ALERTS_NOW` is a test hook.
Tests: `bats tests/alerts_due.bats`.
