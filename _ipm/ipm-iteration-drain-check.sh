#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

# IPM hard gate: drain all non-terminal tasks off the *previous* iteration
# (T20260622-147834; made file-only by T20261005-554581 — this repo and its
# consumers no longer run a GitHub Project board at all, so the gate that
# used to query one via `gh project item-list` reported a permanently
# red/wrong result for every board-less repo, e.g. a Monday drain gate
# blaming an unrelated, already-closed task).
#
# At the end of every Monday IPM, every task still carrying the just-closed
# iteration's `scheduled:` Monday that is NOT terminal (Done/Parked) must be
# migrated out (its task-file `scheduled:` advanced to the current or a
# future Monday). The carry logic (`ipm/SKILL.md` step 1) covers in-flight
# (`In Progress`/`Review`) and `claimed_by` tasks, but an `Open`/`Design`
# task with an empty claim is caught by neither path and silently strands on
# the closed iteration. This gate fails the IPM until it's drained.
#
# "Previous iteration" is a plain calendar computation now, not a board
# lookup: the current iteration's Monday is the most recent Monday <= today;
# the previous iteration's Monday is 7 days before that. No client-side
# counter (`ls | wc -l`) is ever involved — a counter desyncs the moment a
# Monday IPM is skipped or backfilled; a fixed 7-day step from a date window
# does not have that failure mode.
#
# Source of truth is the task files' `scheduled:` frontmatter — no board, no
# cross-repo partition, no lint-frozen sub-partition. Those existed solely to
# cope with a multi-repo GitHub Project (T20260628-592642's cross-repo
# warning, T20260628-951477's lint-frozen warning); a file-only, single-repo
# gate has neither hazard, so both partitions are gone along with the board.
#
# Deps: bash + python3 (date arithmetic only — same idiom as
# todo/scripts/_lib.sh's todo-current-monday). No `gh`, no `jq`, no network.
#
# A `Parked` task is deliberately set aside (moved to dev/PARKING/), not
# stranded work, so the default terminal set is "Done|Parked" — only
# genuinely-active statuses (Open/Design/In Progress/Review/Blocked) count as
# offenders.
#
# Exit: 0 if no non-terminal task's `scheduled:` equals the previous
#         iteration's Monday;
#       1 if one or more such offenders exist (printed);
#       2 on a usage error.

_ipm_drain_usage() {
  cat <<'EOF'
Usage: ipm-iteration-drain-check [options]

  --prev-start YYYY-MM-DD   Force the previous iteration's Monday (skip the
                            calendar computation below). Useful for tests /
                            an explicit backfilled IPM.
  --today YYYY-MM-DD        Override "today" for the calendar computation
                            (default: the current date). Ignored when
                            --prev-start is given.
  --terminal "A|B"          Statuses that count as drained/terminal (regex
                            alternation; default "Done|Parked"). Parked tasks
                            are deliberately set aside (dev/PARKING/), so they
                            are NOT stranded work to force-migrate.
  --todo-dir DIR            Where to read task files from (default:
                            dev/TODO under the current directory — the IPM's
                            own clone).
  -h, --help                Show this help.

Reads every *.md file directly under --todo-dir and flags any whose `status:`
is non-terminal AND whose `scheduled:` equals the previous iteration's Monday
(computed from --today, or forced via --prev-start) as an offender still
pinned to the week that just closed.
EOF
}

# Current-iteration Monday for a given "today" — most recent Monday <= today.
# Same weekday-offset idiom as todo/scripts/_lib.sh's todo-current-monday
# (not `date -d monday`, which resolves to the NEXT Monday on any day that
# isn't itself Monday — a real bug caught in that script's own history).
_ipm_drain_monday_of() {
  local today="$1"
  python3 -c "
import datetime
d = datetime.date.fromisoformat('${today}')
print((d - datetime.timedelta(days=d.weekday())).isoformat())
"
}

_ipm_drain_minus_days() {
  local date="$1" days="$2"
  python3 -c "
import datetime
d = datetime.date.fromisoformat('${date}')
print((d - datetime.timedelta(days=${days})).isoformat())
"
}

# Read one YAML frontmatter field from a task file. Prints '' (exit 0) if
# absent or the file has no frontmatter block — same shape as
# todo/scripts/_lib.sh's todo-fm-get (kept as its own copy here rather than
# sourcing that file, same each-script-keeps-its-own-copy convention
# _session/task-state.sh's ts_fm_get documents over reaching into another
# script's internals).
_ipm_drain_fm_get() {
  local file="$1" field="$2"
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ "^"f":" { sub("^"f":[ ]?", ""); print; exit }
  ' "$file"
}

ipm-iteration-drain-check() {
  local prev_start="" today="" terminal="Done|Parked" todo_dir="dev/TODO"

  while [ $# -gt 0 ]; do
    case "$1" in
      --prev-start) prev_start="${2:-}"; shift 2 ;;
      --today)      today="${2:-}";      shift 2 ;;
      --terminal)   terminal="${2:-}";   shift 2 ;;
      --todo-dir)   todo_dir="${2:-}";   shift 2 ;;
      -h|--help)    _ipm_drain_usage; return 0 ;;
      *) echo "ipm-iteration-drain-check: unknown arg '$1'" >&2
         _ipm_drain_usage >&2; return 2 ;;
    esac
  done
  today="${today:-$(date +%F)}"

  if [ -z "$prev_start" ]; then
    local cur_monday
    cur_monday="$(_ipm_drain_monday_of "$today")"
    prev_start="$(_ipm_drain_minus_days "$cur_monday" 7)"
  fi

  if [ ! -d "$todo_dir" ]; then
    echo "ipm-iteration-drain-check: --todo-dir '${todo_dir}' not found" >&2
    return 2
  fi

  local offenders="" f status scheduled title
  for f in "$todo_dir"/*.md; do
    [ -e "$f" ] || continue   # no glob match -> literal path, skip
    scheduled="$(_ipm_drain_fm_get "$f" scheduled)"
    [ "$scheduled" = "$prev_start" ] || continue
    status="$(_ipm_drain_fm_get "$f" status)"
    if [[ "$status" =~ ^($terminal)$ ]]; then continue; fi
    title="$(basename "$f")"
    offenders+="  ${title}  [${status:-(none)}]  scheduled=${scheduled}"$'\n'
  done
  offenders="${offenders%$'\n'}"

  if [ -n "$offenders" ]; then
    echo "❌ Previous iteration (${prev_start}) has non-terminal tasks that must be drained"
    echo "   (advance each task file's scheduled: to this or a future Monday):"
    echo "$offenders"
    return 1
  fi

  echo "✅ Previous iteration (${prev_start}): no non-terminal tasks still scheduled there."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ipm-iteration-drain-check "$@"
fi
