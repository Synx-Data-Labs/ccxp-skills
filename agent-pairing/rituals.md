# Rituals due (daily standup, Monday IPM, Friday retro)

The ccxp-agent persona runs the team rituals itself. There is no external scheduler (no routine, no
GitHub Actions cron, no `claude --bg` timer): the persona piggybacks on the places it already wakes up.
Task: T20261107-228304. Owner decision: use the persona's own periodic wake as the trigger.

## What runs when

- **Check points**: session start (after the resume reconcile), every user turn, every autopilot wake.
  - Each check runs `bash <plugin-dir>/agent-pairing/scripts/ritual-due.sh claim`.
  - It is token-free and network-free: pure bash on the local clock plus a few marker files.
  - When nothing is due it prints nothing and writes nothing, and the persona does nothing.
- **Rituals** (day boundaries and weekdays in `America/Chicago`, override with `CCXP_RITUAL_TZ`):

| Ritual | Due | Once per | Job runs |
|--------|-----|----------|----------|
| `standup` | every day | calendar day | `/ccxp` (its Friday Phase 2b is the retro) |
| `ipm` | Mon-Fri | ISO week (a missed Monday catches up Tue-Fri) | `/ipm` |
| `retro` | Fri-Sun | week (a missed Friday catches up on the weekend) | `/retro` |

- **One job per check**: priority standup, ipm, retro. A second due ritual is dispatched at the next check.
- **Friday**: claiming `standup` also claims `retro`, because `/ccxp` runs the retro itself; no duplicate.
- Releasing the retro on its own while the Friday standup job is still running makes it due again, so a `/retro` job
  could run beside the `/ccxp` job; release the standup instead.
- Each job runs in a worktree with `CCXP_CRON_MODE=1` stated in its prompt (rituals only, no focused work).

## Idempotency and races

- Markers: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-rituals/<repo>-<hash of the origin URL>/<ritual>-<key>.claim.<n>` and `.done`.
  - `key` is the day (standup), the week's Monday (ipm) or the week's Friday (retro).
  - A claim is created with `O_EXCL`; of several sessions that see the same state, exactly one wins.
  - The persona claims at dispatch; the job's last action is `ritual-due.sh --repo <repo> done <ritual> <key>`
    (on failure `release`, which makes the ritual due again at the next check).
- A claim with no `done` older than 6 hours (`CCXP_RITUAL_TTL`) is treated as a dead job and superseded by a new
  claim at the next check (again after each further 6 hours). A job slower than that can end up running twice.
  The claim is taken before the job is dispatched, so if a turn aborts between the two, that ritual waits out the 6 hours
  (or a manual `release <ritual> <key>`).
- `done` and `release` need the `<key>` that `claim` printed (a job that crosses midnight must not finish the next day's ritual).
  A Friday standup's retro claim follows only that same standup: if the standup job dies, the retro is picked up again
  by the re-claimed standup or the weekend catch-up.
- Markers are local to the profile dir, not git: two machines or two profiles each run their own standup.
  The ritual artifacts themselves (the daily-summary journal entry, the Slack thread) are not consulted.
- Only a git repo with `dev/TODO/` is in scope. Off switches: `CCXP_RITUALS=0`, or an empty file `off` in `ccxp-rituals/` (the base dir, above the per-repo dirs).

## Limits (be honest about them)

- It runs only while a Claude Code session with the persona is open and awake. Nothing fires from a closed
  laptop or a closed session; the first check after the next start (or the next turn) runs the catch-up.
- With autopilot's idle waits of 30-60 minutes, the worst-case lag between a ritual becoming due and its job
  starting is about 1 hour. With no autopilot and no user turn, a ritual waits for the next turn.
- The persona needs a release of this plugin to reach installs (persona refresh: `persona-refresh.md`).
- Not built here: the old usage-cost warning of the launchd wrapper (separate follow-up task); event-driven
  CI wake (CI failures are still found by the persona's polling at the same check points).
