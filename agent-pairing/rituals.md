# Routines due (daily standup, Monday IPM, Friday retro, and your own)

The ccxp-agent persona runs the team rituals itself, and since T20261114-195064 every configured routine (see
"Routines" below): its "Routines due" check calls `routine-due.sh claim` and dispatches `/routine run <name> --key <key>`.
The three built-ins behave exactly as the sections up to "Routines" describe; `ritual-due.sh` stays for installs that have not refreshed. There is no external scheduler (no routine, no
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

## Routines (configurable rituals)

Task: T20261114-144275 (part 1 of the routines epic T20261114-267875). `routine-due.sh` generalizes `ritual-due.sh`:
named routines come from a config file instead of the hard-coded three. The persona runs `routine-due.sh` (part 3,
T20261114-195064); with no config file it prints exactly what `ritual-due.sh` prints.

- **Limits**: a routine fires only while a persona session is open, at the check points above (no cron, no launchd, no cloud routine).
- **Commands**: `bash <plugin-dir>/agent-pairing/scripts/routine-due.sh [--repo DIR] list | claim | done <routine> <key> | release <routine> <key> | show <routine> | check`.
  - `list` and `claim` behave as in `ritual-due.sh`, in declaration order (built-ins first).
  - `check` lints the merged config and prints `<file>:<line>: <message>`; exit 1 when it finds a problem.
- **Layers** (later wins, merged per routine; dicts deep-merge, so one key can be overridden, lists and scalars replace):
  1. `agent-pairing/routines.default.yml`: `standup`, `ipm`, `retro`.
  2. `<hub repo>/dev/.routines.yml`: tracked, reviewed, no secrets. A profile `routines-file:` replaces this path.
  3. `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-routines.yml`: machine-local, never committed (`CCXP_ROUTINES_PROFILE_FILE` overrides the path).
- **Schema**: top-level keys `routines:` (map name to routine), `here:` (list of place slugs) and, profile only, `routines-file:`; any other key fails `check`.

```yaml
routines:
  inbox:
    description: clean the inbox
    schedule: {days: weekdays, at: "07:30", once_per: day}   # at must be quoted
    steps:
      - {skill: "/email-triage", args: "--window 24h"}
    report: journal
  retro: {enabled: false}
  standup:
    schedule: {at: "08:30"}
```

- **Routine keys** (all optional but `steps`): `description`, `enabled`, `schedule`, `steps` (`{skill, args}` list), `on_failure` (`stop|continue`),
  `report` (`slack|journal|none`), `tz` (IANA name), `also_claims` (a claim also claims the named routine with the same key; `standup` declares `[retro]`),
  `allow` (honored only from the profile file), `scope` (`repo`, the default, or `any` for repo-less routines such as the inbox).
- **Schedule keys**: `at` or `every` (`5m`, `2h`, `1d`; not both), `days` (`daily`, `weekdays` or a list of `mon`..`sun`), `once_per` (`day` or `week`), `not_before`, `not_after` (all `"HH:MM"`).
  - A `week` key is the date of the earliest listed day in the ISO week (ipm gives Monday, retro gives Friday); a window wrapping Sunday to Monday is rejected.
  - `at` gates only the day the key names; a missed run catches up on later days of the window.
  - `every:` routines are listed as `<routine> every`, never claimed (run inline), and `done <routine> every` rewrites one `<routine>.last` marker.
- **Example routines** (task dimensions, T20261114-380745; not in the built-in set, copy into `dev/.routines.yml`): `today` (`schedule: {days: daily, at: "08:00", once_per: day}`, step `/todo list --when today,overdue --group-by place`) and `waiting` (`schedule: {days: [mon], once_per: week}`, step `/todo list --waiting-on any --group-by person`). Add `--json` for a machine-readable result. `--here` reads the `here:` key of the profile file.
- **Failure handling**: a routine whose override is invalid keeps its previous definition and prints one warning; an unparsable file is skipped whole. The standup is never silenced.
- **YAML reader**: `python3 -I` with PyYAML, else `yq -o=json` (no line numbers or duplicate-name detection), else the three built-ins compiled into the script plus one warning.
- **Markers**: as above; `scope: any` routines keep theirs under `ccxp-rituals/_any/`.
- **Running** (T20261114-400715, part 2): the `/routine` skill runs a routine on demand, records each run under `ccxp-routines/` and applies `on_failure`; see `routine/SKILL.md`.
- **Starter routines** (T20261114-195064): `agent-pairing/routines.examples.yml` documents `inbox`, `nightly-check` (commented until its
  skill exists, T20261116-179192), `alerts` and a `standup` override; `tests/routine_due.bats` lints it and simulates a day.
  - `inbox`: weekdays 07:30, a read-only `/email-triage` summary then a mail-changing clean step (archive, label, drafts for review; it never sends, replies, forwards or deletes; needs profile-only `allow:` grants, T20261116-391393). `report: slack` and `--no-slack` on both steps give one message.
  - `alerts`: an `every: 5m` registration so `/routine list|show|disable` covers it; the persona's inline "Slack alerts check" does the work, and an `every:` routine is never claimed as a job.
  - `standup`, `ipm`, `retro` stay built in; `today` and `waiting` are the commented examples in `routines.default.yml`.
- **Make your own routine**: copy a starter block into `dev/.routines.yml` (shared, reviewed) or the profile file (this machine), set `schedule.at` (quoted) and `days`,
  check it with `routine-due.sh check`, preview it with `/routine run <name> --dry-run` (writes nothing, calls no skill), then leave it enabled.
  Each routine fires once per `once_per` window, and only while a persona session is open.
- **Limits (honest bound)**: routines fire only while a Claude Code session with the persona is open, at the check points above; the worst-case lag between
  a routine becoming due and its job starting is about 1 hour with autopilot idle waits, and with no autopilot and no user turn it waits for the next turn.
- **Persona refresh**: the persona change reaches installs through `persona-refresh.md` (automatic on the next prompt after a plugin update);
  an install with `CCXP_PERSONA_AUTO_REFRESH=0` keeps the old "Rituals due" path (`ritual-due.sh`, the three built-ins only) until refreshed by hand.
