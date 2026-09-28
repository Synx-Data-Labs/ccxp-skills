#!/usr/bin/env bash
# iteration.sh <current|next> — print a date (YYYY-MM-DD) that falls inside the
# current or next Project Iteration, for use as a new task's `scheduled:` value
# so the task lands in that iteration on the board (and shows in the Iterations
# view). Prints the iteration's startDate (always in-window, deterministic).
#
# Used by /drive to auto-stage newly-created tasks at creation time:
#   - a blocker / dependency  -> `iteration.sh current`  (work it this iteration)
#   - a follow-up             -> `iteration.sh next`     (deferred to next)
#
# Best-effort: on any failure (no PAT, no Iteration field, network, no active
# iteration) it prints NOTHING and exits 0 — callers treat empty output as
# "leave the task unscheduled / backlog" rather than failing.
#
# Testability: set SESSION_TODAY=YYYY-MM-DD to override "today" (dependency
# injection), and override _session_gh to inject a canned API response.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_lib.sh"

# Echo the startDate of the current (default) or next iteration; empty on failure.
session_iteration_date() {
  local which="${1:-current}"
  _session_resolve_project || return 1
  local q raw
  q='query($id:ID!){ node(id:$id){ ... on ProjectV2 {
        field(name:"Iteration"){ ... on ProjectV2IterationField {
          configuration { iterations { startDate duration } } } } } } }'
  raw="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" 2>/dev/null)" || return 1

  printf '%s' "$raw" | SESSION_ITER_WHICH="$which" python3 -c '
import sys, os, json, datetime

which = os.environ.get("SESSION_ITER_WHICH", "current")
today_env = os.environ.get("SESSION_TODAY")
try:
    today = datetime.date.fromisoformat(today_env) if today_env else datetime.date.today()
except ValueError:
    today = datetime.date.today()

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

cfg = ((((data.get("data") or {}).get("node") or {}).get("field") or {})
       .get("configuration") or {})
parsed = []
for it in (cfg.get("iterations") or []):
    try:
        sd = datetime.date.fromisoformat(it["startDate"])
        dur = int(it.get("duration") or 7)
        parsed.append((sd, dur))
    except Exception:
        pass
parsed.sort()
if not parsed:
    sys.exit(0)

# "current" = the iteration whose [start, start+duration) contains today;
# if today sits in a gap before any iteration, treat the next upcoming as current.
cur = None
for i, (sd, dur) in enumerate(parsed):
    if sd <= today < sd + datetime.timedelta(days=dur):
        cur = i
        break
if cur is None:
    for i, (sd, _dur) in enumerate(parsed):
        if sd > today:
            cur = i
            break
if cur is None:
    sys.exit(0)

idx = cur + (1 if which == "next" else 0)
if idx >= len(parsed):
    sys.exit(0)
print(parsed[idx][0].isoformat())
'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  session_iteration_date "${1:-current}"
fi
