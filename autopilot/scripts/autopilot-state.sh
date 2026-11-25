#!/usr/bin/env bash
# autopilot-state.sh — deterministic state/guardrail helpers for /autopilot
# (T20261028-151063). The skill's prose drives the loop; every decision that
# can be computed lives here so it is unit-tested.
#
# Usage: autopilot-state.sh <cmd> [args]
#   status                      print on|paused|off (legacy/malformed file = off)
#   report                      human-readable status (counters, notices, overdue)
#   start                       print started|busy|dispatch|already-on|paused
#   pause | off                 transitions; print paused | "off <clone-path>" | noop
#   resume                      print dispatch|busy (a cycle is still finishing: do nothing)|noop
#   busy on [<task-id>] [--slot N] [--urgent]|off [--slot N]
#                               mark a dispatched cycle running in slot N (default 1; 1-16); --urgent marks
#                               urgent tier 1/2 work, which runs in a reserved slot and does not use up routine-free
#                               (optionally which task it drives, T<yyyymmdd>-<6 digits>; an
#                               invalid id is ignored; the HUD shows "running r<n>" from the
#                               ledger) / finished; bare `off` clears every slot. `on` re-marks a
#                               busy slot (as before) but exits 3 when the task is in another slot.
#   slots [--summary]           "<slot><TAB><task><TAB><since>" per busy slot (fresh: under 3 h);
#                               --summary prints one line instead: "routine 1 of 3, reserved 2, busy 0, routine-free 1, free 3"
#   routine-free                routine slots still free: max_dop minus reserved_slots minus the running cycles not marked --urgent, never below 0
#                               (a routine pick needs this above 0; the reserved slots are for urgent tier 1/2 work only)
#   guard                       ok | hold <reason> (exit 0 / 1): free memory and load, for a slot
#                               beyond the first running one (see ap-guard)
#   hold <seconds> <reason>     wake again in <seconds> without recording a cycle (a guard hold,
#                               a ramp wake); prints the seconds
#   wake <seconds> [reason]     record that a wake is armed <seconds> from now (1-86400): sets next_wake_at only,
#                               no counters, slots or last_hold; run it with EVERY ScheduleWakeup the loop arms
#                               (a wake armed without it leaves next_wake_at stale and the HUD reports a stall)
#   set-clone <slot> <path>     remember the slot's dispatch clone (slot 1 = dispatch_clone_path)
#   cap                         print ok | capped:<cycles|merges>  (rolls the day)
#   record <outcome> [merged] [task-id] [reason] [--slot N]
#                               outcome: progress|idle|stuck|waiting|bottomed|capped;
#                               bottomed = a cycle that only stalled on tasks (leaves the
#                               stuck/waiting counters and the notice flags alone, wakes in 60 s);
#                               updates counters + next_wake_at, prints the
#                               notice kind to send (idle|resumed|stuck|waiting|
#                               capped) or "none"
#                               every record also appends one line to the history log
#   stats [--json]              rolling-24h and lifetime progress from the history
#                               log + state counters (see ap-stats)
#   delay <outcome>             seconds until the next wake
#   remaining                   seconds until next_wake_at (0 when due)
#   overdue [grace-seconds]     seconds the next loop is late (total lateness), reported only when it exceeds
#                               the grace (default 600), else 0: status on, no cycle running, a known wake
#                               time past by more than the grace. Same rule as the HUD stalled cell (hud/model.ts stalledFor)
#   eligible <task-file>        exit 0 when the status line allows auto-driving (not
#                               gated: see todo-gated in todo/scripts/_lib.sh)
#   pickable [repo-root]        pick | drift | none: pick = /drive could take a task
#                               (todo-next.sh --skip-gated --check), drift =
#                               nothing pickable but `todo-sweep.sh plan` has mechanical
#                               findings (a /drive sweep would fix them), none = idle
#   top [repo-root] [--nth N] [--urgent]
#                               the id of the first (Nth) task of the tiered order: tiers 1..4 (--urgent: 1 and 2,
#                               what a reserved slot takes), each in queue order rotated by its cursor (the last task
#                               dispatched from the tier comes last), skipping gated, in-flight and held tasks; or nothing
#   plan <file|-> [--fallback T<id>]
#                               one "<task-id><TAB>advanced|stalled<TAB><reason><TAB><source>"
#                               line per task a /drive report names (MERGED:/ADVANCED: =
#                               advanced; NEEDS-ATTENTION: or STUCK: last task = stalled
#                               unless advanced; source = merged|advanced|attention|stuck).
#                               A STUCK with no task id names the --fallback task, if given.
#   prune [repo-root]           drop the holds of tasks that are no longer in
#                               <repo-root>/dev/TODO (closed or parked by someone else);
#                               prints the dropped ids
#   hold-add <task-id> <kind> <condition> <reason>
#                               record a hold (d152: a hold is a recorded fact with a reason AND a release
#                               condition, never a silent skip). kind waiting|needs-human|stalled; condition
#                               `until <time>` (ISO UTC, or a date), `run:<id>`, `pr:<n>`, `file-changed <path>`
#                               or `task-left-todo <T-id>` (one argument, or several joined by spaces); exit 2 on an
#                               unknown kind/condition or an empty reason, nothing written. Stored in the state
#                               file's "holds", which `off`/`start` carry over; `top` and `pickable` pass over held tasks.
#   holds [--json]              "<task><TAB><kind><TAB><reason><TAB><condition><TAB><since>" per hold
#   release <task-id>           drop one hold; print released|none
#   holds-check [repo-root]     release every hold whose condition is met (time passed, run completed or PR
#                               closed via `gh api`, file mtime or git commit after the hold, task no longer in
#                               dev/TODO); print "released <task> (<condition>)" per release. A gh failure keeps the hold.
#   hold-report <file> [--fallback T<id>] [--repo <root>]
#                               Phase 4: turn a /drive report into holds instead of a bottom PR. Per stalled task `plan`
#                               names: NEEDS-ATTENTION -> needs-human, STUCK -> stalled; a WAITING report with --fallback ->
#                               waiting. Release conditions: needs-human = the task file changes (else until +24h),
#                               stalled = until +2h, waiting = until +1h. Prints "held <id> <kind>" per hold, or "skip <id>"
#                               for a STUCK while stuck_count >= 3 (likely an outage, not the task). Nothing is written to
#                               queue.md or a task file. A report with nothing stalled prints nothing.
#   notify <kind> <text>        Slack (--channel dev) when possible, else record
#                               in the state file; always exit 0
#   classify <file|->           parse a /drive sub-agent's final report (the
#                               MERGED:/STUCK:/NEEDS-ATTENTION:/WAITING: lines)
#                               -> "<outcome> <merged> <task-id|-> <reason>",
#                               outcome progress|waiting|stuck|idle, ready for
#                               `record`; exit 2 (and a stuck line) when no
#                               report line is recognized
#   attention <file|->          one "<task-id><TAB><reason>" line per
#                               NEEDS-ATTENTION entry of a report
#   clone-path [repo-root] [--slot N]
#                               deterministic dispatch-clone path for a repo (slot 1, the
#                               default, unchanged; slot N>=2 appends -sN)
#   done                        "- Merged T<id> (<slug>)[ — PR #<n>]" per journal
#                               file added since started_at ("- No tasks merged
#                               this run" when none); needs a git repo
#   final-report [--stopped <why>]
#                               the Phase 5 bullet report (elapsed, Done,
#                               Needs your attention) from the state file
#   config-show [--json]        every setting with its effective value, default|override
#                               and the config file path (read-only)
#   config-set <key> <value>    validate, then atomically write one override (keeps other keys,
#                               file mode 600); exit 2 on a bad key/value, state untouched
#   config-reset [<key>]        drop one override, or all five settings' overrides
# Env (tests): AUTOPILOT_GUARD_MEM_FREE_PCT, AUTOPILOT_GUARD_LOAD, AUTOPILOT_GUARD_NCPU, AUTOPILOT_STATE_FILE, AUTOPILOT_CONFIG_FILE, AUTOPILOT_HISTORY_FILE,
#   AUTOPILOT_NOW, AUTOPILOT_TODAY, AUTOPILOT_SLACK_SEND, AUTOPILOT_REPO_ROOT.
# Config (dev/.autopilot-config.json): daily_cycle_cap, daily_merge_cap, idle_retry_minutes,
#   max_dop (cycles at the
#   same time, 3-16, default 3: 2 slots are always reserved for urgent work, so below 3 is refused and a
#   smaller file value reads as 3), reserved_slots (0-8, default 2, at most max_dop minus 1: slots kept for
#   urgent tier 1/2 work; routine picks fill max_dop minus reserved_slots).

set -euo pipefail

_ap_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
_ap_dir() { dirname "${BASH_SOURCE[0]}"; }
ap-repo-root() { printf '%s' "${AUTOPILOT_REPO_ROOT:-$(_ap_root)}"; }
ap-state-file() { printf '%s' "${AUTOPILOT_STATE_FILE:-$(_ap_root)/dev/.autopilot-state.json}"; }
ap-config-file() { printf '%s' "${AUTOPILOT_CONFIG_FILE:-$(_ap_root)/dev/.autopilot-config.json}"; }
ap-history-file() { printf '%s' "${AUTOPILOT_HISTORY_FILE:-$(dirname "$(ap-state-file)")/.autopilot-history.jsonl}"; }
ap-now() { printf '%s' "${AUTOPILOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }
ap-today() { printf '%s' "${AUTOPILOT_TODAY:-$(date +%F)}"; }

# ISO-8601 UTC -> epoch seconds (GNU or BSD date); empty when unparseable.
_ap_epoch() {
  [ -n "${1:-}" ] || return 0
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}
_ap_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# max_dop: the configured number of cycles at the same time, clamped to 3-16 (default 3): 2 slots are
# always reserved for urgent work. A smaller file value reads as 3 (never rewritten; config-show and report say so).
ap-max-dop() {
  local v; v=$(ap-config max_dop 3)
  if [ "$v" -gt 16 ]; then v=16; elif [ "$v" -lt 3 ]; then v=3; fi
  printf '%s' "$v"
}

# reserved_slots: slots kept for urgent tier 1/2 work (0-8, default 2), at most max_dop minus 1.
# A zero is a valid value here, so it is read apart from ap-config (which ignores non-positive numbers).
ap-reserved-slots() {
  local f v="" max; f=$(ap-config-file); max=$(( $(ap-max-dop) - 1 ))
  [ -f "$f" ] && v=$(jq -r '.reserved_slots // empty' "$f" 2>/dev/null || true)
  [[ "$v" =~ ^[0-9]+$ ]] || v=2
  if [ "$v" -gt 8 ]; then v=8; fi
  if [ "$v" -gt "$max" ]; then v=$max; fi
  printf '%s' "$v"
}

# Routine slots: how many cycles routine picks may fill (max_dop minus reserved_slots, at least 1).
ap-routine-limit() { printf '%s' $(( $(ap-max-dop) - $(ap-reserved-slots) )); }

ap-routine-free() {
  local n room; n=$(( $(ap-routine-limit) - $(_ap_routine_busy) )); room=$(( $(ap-max-dop) - $(_ap_busy_count) ))
  if [ "$room" -lt "$n" ]; then n=$room; fi   # never more than the slots physically free
  if [ "$n" -lt 0 ]; then n=0; fi
  printf '%s\n' "$n"
}

# One line: "routine 1 of 3, reserved 2" (the dispatcher and the HUD read this).
ap-routine-line() { printf 'routine %s of %s, reserved %s' "$(ap-routine-limit)" "$(ap-max-dop)" "$(ap-reserved-slots)"; }

# One notice per config value that was clamped on read (empty when the file is fine). Never rewrites the file.
ap-config-notices() {
  local f raw; f=$(ap-config-file); [ -f "$f" ] || return 0
  raw=$(jq -r '.max_dop // empty' "$f" 2>/dev/null || true)
  if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -lt 3 ]; then
    echo "notice: max_dop $raw in the config file is below 3 (2 slots are reserved for urgent work); using 3. Fix it with: config set max_dop <3-16>"
  fi
  raw=$(jq -r '.reserved_slots // empty' "$f" 2>/dev/null || true)
  if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" != "$(ap-reserved-slots)" ]; then
    echo "notice: reserved_slots $raw in the config file is above the cap (8, and max_dop minus 1); using $(ap-reserved-slots). Fix it with: config set reserved_slots <n>"
  fi
}

# Config value with default; a missing file, key or non-positive-integer gives the default.
ap-config() {
  local key="$1" def="$2" f v=""
  f=$(ap-config-file)
  [ -f "$f" ] && v=$(jq -r --arg k "$key" '.[$k] // empty' "$f" 2>/dev/null || true)
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

ap-status() {
  local f s
  f=$(ap-state-file)
  [ -f "$f" ] || { echo off; return 0; }
  s=$(jq -r 'select(.schema == 2) | .status // empty' "$f" 2>/dev/null || true)
  case "$s" in on|paused|off) echo "$s" ;; *) echo off ;; esac
}

# Atomic write: jq filter applied to the current state via temp file + mv.
# Serialized with a lock file (holds the pid; a lock older than 5 s (a write takes milliseconds) is a
# crashed writer and is broken, inside the 10 s a waiter retries), so two cycles finishing close together never interleave read-modify-write.
# Lock mechanics live in _session/lock.sh (an atomic noclobber lock file; never mkdir, see there).
# shellcheck source=/dev/null
. "$(_ap_dir)/../../_session/lock.sh"
_ap_lock() { lock_acquire "$(ap-state-file).lock" 5 200 0.05; }
_ap_unlock() { lock_release "$(ap-state-file).lock"; }

_ap_update() {
  local f tmp rc=0; f=$(ap-state-file); tmp="$f.tmp.$$"
  _ap_lock || { echo "autopilot-state: could not lock $f" >&2; return 1; }
  # the retired visits counter and parked list (T20261124-115593) are dropped from an old file on its next write
  if jq "$@" "$f" | jq 'if type == "object" then del(.visits, .parked) else . end' > "$tmp" && mv "$tmp" "$f"; then :; else rm -f "$tmp"; rc=1; fi
  _ap_unlock
  return $rc
}

# A fresh run zeroes the run counters but never the lifetime baseline: the
# lifetime_* fields are carried over from the previous state file (seeded from its
# run counters when it predates them), so `off` then `start` keeps the average.
_ap_fresh() {
  local f carry=""; f=$(ap-state-file); mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && carry=$(jq -c 'select(type == "object") | {
      lifetime_started_at: (((.lifetime_started_at // .started_at) | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) // null),
      lifetime_cycles: ((.lifetime_cycles // .cycle_count) | numbers // 0),
      lifetime_merged: ((.lifetime_merged // .merged_count) | numbers // 0),
      holds: ((.holds | objects // {}) | with_entries(select(.value | type == "object"))),
      cursors: ((.cursors | objects // {}) | with_entries(select(.value | type == "string")))}' "$f" 2>/dev/null) || carry=""
  [ -n "$carry" ] || carry=null
  jq -n --arg now "$(ap-now)" --arg day "$(ap-today)" --argjson carry "$carry" '{
    schema: 2, status: "on", started_at: $now, run_started_at: $now, paused_at: null,
    lifetime_started_at: (($carry.lifetime_started_at | strings) // $now),
    lifetime_cycles: ($carry.lifetime_cycles // 0), lifetime_merged: ($carry.lifetime_merged // 0),
    cycle_count: 0, merged_count: 0, stuck_count: 0, waiting_count: 0,
    last_cycle_at: null, last_outcome: null, last_task: null, last_stuck_reason: null,
    holds: ($carry.holds // {}), cursors: ($carry.cursors // {}),
    dispatch_clone_path: null, dispatch_clone_paths: {}, slots: {}, idle_notified: false, stuck_notified: false,
    waiting_notified: false, capped_notified: false,
    day: $day, cycles_today: 0, merges_today: 0, notices: [],
    next_wake_at: null, busy_since: null, current_task: null}' > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# jq prelude: the state with `.slots` materialized. A file from before slots (no `.slots` key) that
# has a busy_since reads as slot 1 busy; once `.slots` exists it alone is authoritative.
AP_JQ_MIGRATE='(if (.slots | type) == "object" then . else
    .slots = (if ((.busy_since | strings) // "") != "" then {"1": {task: .current_task, since: .busy_since}} else {} end) end)'

# Busy slots (fresh: marked under 3 h ago, else a crashed cycle), one "<slot><TAB><task><TAB><since>" each.
# `_ap_slots routine` leaves out the slots marked urgent (busy on ... --urgent).
_ap_slots() {
  local f now only="${1:-}"; f=$(ap-state-file)
  [ -f "$f" ] || return 0
  now=$(_ap_epoch "$(ap-now)"); [[ "$now" =~ ^[0-9]+$ ]] || return 0
  jq -r --argjson now "$now" --arg only "$only" "$AP_JQ_MIGRATE"' | .slots | to_entries
    | map(select((.value | type) == "object" and ($only != "routine" or .value.urgent != true) and ((.value.since | strings | (try fromdateiso8601 catch null)) as $e | $e != null and ($now - $e) < 10800)))
    | sort_by(.key | tonumber)[] | [.key, (.value.task // ""), .value.since] | @tsv' "$f" 2>/dev/null || true
}

_ap_busy_count() { _ap_slots | grep -c . || true; }
# Cycles that count against the routine limit (urgent ones run in the reserved slots).
_ap_routine_busy() { _ap_slots routine | grep -c . || true; }

# 0 when any cycle is marked busy.
_ap_is_busy() { [ "$(_ap_busy_count)" -gt 0 ]; }

# The legacy fields mirror the oldest busy slot, so a pre-slots reader keeps working.
AP_JQ_MIRROR='(.slots | to_entries | sort_by(.value.since // "") | .[0].value) as $o
    | .busy_since = ($o.since // null) | .current_task = ($o.task // null)'

# Comma list of the task ids in flight (busy slots with a task).
_ap_inflight() { _ap_slots | cut -f2 | grep . | paste -sd, - || true; }

# --slot N parser: sets AP_SLOT (default 1) and leaves the other args in AP_REST.
_ap_parse_slot() {
  AP_SLOT=1; AP_REST=()
  while [ $# -gt 0 ]; do
    if [ "$1" = --slot ]; then
      [[ "${2:-}" =~ ^([1-9]|1[0-6])$ ]] || { echo "--slot takes 1-16, got '${2:-}'" >&2; return 2; }
      AP_SLOT="$2"; shift 2
    else AP_REST+=("$1"); shift; fi
  done
}

ap-remaining() {
  local f w we now; f=$(ap-state-file)
  w=$(jq -r '.next_wake_at // empty' "$f" 2>/dev/null || true)
  [ -n "$w" ] || { echo 0; return 0; }
  we=$(_ap_epoch "$w"); now=$(_ap_epoch "$(ap-now)")
  if [ -n "$we" ] && [ -n "$now" ] && [ "$we" -gt "$now" ]; then echo $(( we - now )); else echo 0; fi
}

ap-overdue() {
  local grace="${1:-600}" f w we now late
  [[ "$grace" =~ ^[0-9]+$ ]] || { echo "overdue [grace-seconds]: a whole number" >&2; return 2; }
  [ "$(ap-status)" = on ] && ! _ap_is_busy || { echo 0; return 0; }
  f=$(ap-state-file)
  w=$(jq -r '.next_wake_at // empty' "$f" 2>/dev/null || true)
  [ -n "$w" ] || { echo 0; return 0; }
  we=$(_ap_epoch "$w"); now=$(_ap_epoch "$(ap-now)")
  [ -n "$we" ] && [ -n "$now" ] || { echo 0; return 0; }
  late=$(( now - we ))
  if [ "$late" -gt "$grace" ]; then echo "$late"; else echo 0; fi
}

# A wake may fire early: ScheduleWakeup reports its time rounded to the minute, so a wake lands up to
# 59 s before the second-precise next_wake_at (T20261124-243982). Within this many seconds counts as due.
# Trade-off: a typed "on" cannot be told from an early wake, so within this many seconds of next_wake_at it dispatches
# (after a 60 s progress record that is all but the first second). Longer delays keep a typed "on" already-on.
AP_WAKE_TOLERANCE="${AP_WAKE_TOLERANCE:-59}"

# Shared by start (when on) and resume: dispatch only if due and not busy.
_ap_due() {
  local tol="$AP_WAKE_TOLERANCE"
  [[ "$tol" =~ ^[0-9]+$ ]] || tol=59
  if [ "$(_ap_routine_busy)" -ge "$(ap-routine-limit)" ] || [ "$(_ap_busy_count)" -ge "$(ap-max-dop)" ]; then echo already-on; return 0; fi
  if [ "$(ap-remaining)" -gt "$tol" ]; then echo already-on; else echo dispatch; fi
}

ap-start() {
  case "$(ap-status)" in
    on) _ap_due ;;
    paused) echo paused ;;
    off)
      local busy="" carry_slots=""
      if [ -f "$(ap-state-file)" ] && _ap_is_busy; then
        busy=1; carry_slots=$(jq -c "$AP_JQ_MIGRATE | .slots" "$(ap-state-file)")
      fi
      _ap_fresh
      if [ -n "$busy" ]; then _ap_update --argjson sl "$carry_slots" '.slots = $sl | '"$AP_JQ_MIRROR"; echo busy; else echo started; fi ;;
  esac
}

ap-pause() {
  [ "$(ap-status)" = on ] || { echo noop; return 0; }
  _ap_update --arg now "$(ap-now)" '.status = "paused" | .paused_at = $now'
  echo paused
}

# Shifts started_at by the pause length so HUD elapsed stays frozen across it.
ap-resume() {
  [ "$(ap-status)" = paused ] || { echo noop; return 0; }
  local f p s pe se now d=0; f=$(ap-state-file)
  p=$(jq -r '.paused_at // empty' "$f"); s=$(jq -r '.started_at // empty' "$f")
  pe=$(_ap_epoch "$p"); se=$(_ap_epoch "$s"); now=$(_ap_epoch "$(ap-now)")
  if [ -n "$pe" ] && [ -n "$se" ] && [ -n "$now" ] && [ "$now" -ge "$pe" ]; then
    _ap_update --arg ns "$(_ap_iso $(( se + now - pe )))" '.started_at = $ns'
  fi
  _ap_update '.status = "on" | .paused_at = null | .next_wake_at = null'
  if [ "$(_ap_routine_busy)" -ge "$(ap-routine-limit)" ] || [ "$(_ap_busy_count)" -ge "$(ap-max-dop)" ]; then echo busy; else echo dispatch; fi
}

# Prints the dispatch clone path for the caller to remove, and clears the state's copy.
ap-off() {
  local f clone=""; f=$(ap-state-file)
  [ "$(ap-status)" = off ] && { echo noop; return 0; }
  clone=$(jq -r '.dispatch_clone_path // empty' "$f" 2>/dev/null || true)
  local extra; extra=$(jq -r '(.dispatch_clone_paths | objects // {}) | to_entries | sort_by(.key | tonumber)[] | .value | strings' "$f" 2>/dev/null || true)
  _ap_update '.status = "off" | .paused_at = null | .dispatch_clone_path = null | .dispatch_clone_paths = {} | .next_wake_at = null'
  printf 'off %s\n' "$clone"
  local c; while IFS= read -r c; do [ -z "$c" ] || printf 'clone %s\n' "$c"; done <<< "$extra"
}

ap-busy() {
  [ -f "$(ap-state-file)" ] || return 0
  local mode="${1:-}"; shift || true
  _ap_parse_slot "$@" || return 2
  case "$mode" in
    on)
      # An id that is not a task id is ignored (the cycle is still marked busy), never an error.
      local t="" inflight urgent=false a
      for a in ${AP_REST[@]+"${AP_REST[@]}"}; do
        if [ "$a" = --urgent ]; then urgent=true; elif [ -z "$t" ]; then t="$a"; fi
      done
      [[ "$t" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || t=""
      [ "$(ap-status)" = off ] && return 0
      inflight=$(_ap_slots | awk -F'\t' -v s="$AP_SLOT" -v t="$t" 't != "" && $2 == t && $1 != s {f=1} END {exit !f}' && echo yes || true)
      if [ -n "$inflight" ]; then echo "busy: $t is already in flight in another slot" >&2; return 3; fi
      _ap_update --arg now "$(ap-now)" --arg t "$t" --arg s "$AP_SLOT" --argjson u "$urgent" "$AP_JQ_MIGRATE"' | .slots[$s] = ({task: (if $t == "" then null else $t end), since: $now} + (if $u then {urgent: true} else {} end)) | '"$AP_JQ_MIRROR"
      [ -z "$t" ] || _ap_cursor_set "$t" ;;
    off)
      if [ ${#AP_REST[@]} -eq 0 ] && ! printf '%s ' "$@" | grep -q -- '--slot'; then
        _ap_update "$AP_JQ_MIGRATE"' | .slots = {} | '"$AP_JQ_MIRROR"
      else
        _ap_update --arg s "$AP_SLOT" "$AP_JQ_MIGRATE"' | .slots |= del(.[$s]) | '"$AP_JQ_MIRROR"
      fi ;;
    *) echo "busy on [<task-id>] [--slot N] [--urgent]|off [--slot N]" >&2; return 2 ;;
  esac
}

ap-slots() {
  case "${1:-}" in
    "") _ap_slots ;;
    --summary) printf '%s, busy %s, routine-free %s, free %s\n' "$(ap-routine-line)" "$(_ap_busy_count)" "$(ap-routine-free)" \
      "$(( $(ap-max-dop) - $(_ap_busy_count) > 0 ? $(ap-max-dop) - $(_ap_busy_count) : 0 ))" ;;
    *) echo "slots [--summary]" >&2; return 2 ;;
  esac
}

# set-clone <slot> <path>: remember a slot's dispatch clone (slot 1 is dispatch_clone_path).
ap-set-clone() {
  local slot="${1:-}" path="${2:-}"
  [[ "$slot" =~ ^([1-9]|1[0-6])$ ]] && [ -n "$path" ] || { echo "set-clone <slot 1-16> <path>" >&2; return 2; }
  [ -f "$(ap-state-file)" ] || return 0
  if [ "$slot" = 1 ]; then _ap_update --arg p "$path" '.dispatch_clone_path = $p'
  else _ap_update --arg s "$slot" --arg p "$path" '.dispatch_clone_paths = (((.dispatch_clone_paths | objects // {})) | .[$s] = $p)'; fi
}

_ap_roll_day() {
  _ap_update --arg d "$(ap-today)" 'if .day != $d then .day = $d | .cycles_today = 0 | .merges_today = 0 | .capped_notified = false else . end'
}

ap-cap() {
  [ "$(ap-status)" = on ] || { echo ok; return 0; }
  _ap_roll_day
  local f cc mc; f=$(ap-state-file)
  # Cycles in flight count against the cycle cap, so parallel dispatch cannot overshoot it. A merge is
  # only counted once it lands, so the merge cap can be exceeded by at most max_dop-1 merges.
  cc=$(( $(jq -r '.cycles_today // 0' "$f") + $(_ap_busy_count) )); mc=$(jq -r '.merges_today // 0' "$f")
  if [ "$cc" -ge "$(ap-config daily_cycle_cap 64)" ]; then echo capped:cycles
  elif [ "$mc" -ge "$(ap-config daily_merge_cap 64)" ]; then echo capped:merges
  else echo ok; fi
}

ap-delay() {
  local outcome="${1:?outcome}" f n d key; f=$(ap-state-file)
  case "$outcome" in
    progress|bottomed) echo 60 ;;
    idle) echo $(( $(ap-config idle_retry_minutes 32) * 60 )) ;;
    capped) echo 3600 ;;
    held) echo 300 ;;
    stuck|waiting)
      key=waiting_count; [ "$outcome" = stuck ] && key=stuck_count
      n=$(jq -r --arg k "$key" '.[$k] // 1' "$f" 2>/dev/null || echo 1)
      if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then n=1; fi
      [ "$n" -gt 6 ] && n=6
      d=$(( 300 * (1 << (n - 1)) )); [ "$d" -gt 1800 ] && d=1800
      echo "$d" ;;
    *) echo "bad outcome: $outcome" >&2; return 1 ;;
  esac
}

# hold <seconds> <reason>: wake again in <seconds> without recording a cycle (a guard hold, a ramp wake).
ap-hold() {
  local sec="${1:-}" reason="${2:-}" f nw
  [[ "$sec" =~ ^[0-9]+$ ]] && [ "$sec" -ge 1 ] && [ "$sec" -le 3600 ] || { echo "hold <seconds 1-3600> <reason>" >&2; return 2; }
  f=$(ap-state-file)
  if [ "$(ap-status)" = on ]; then
    reason=$(printf '%s' "$reason" | tr '\n\t\r' '   ' | cut -c1-200)
    nw=$(( $(_ap_epoch "$(ap-now)") + sec ))
    _ap_update --arg w "$(_ap_iso "$nw")" --arg r "$reason" --arg now "$(ap-now)" '.next_wake_at = $w | .last_hold = {at: $now, reason: $r}'
  fi
  echo "$sec"
}

# wake <seconds> [reason]: record the wake the loop is arming, so next_wake_at never goes stale while it idles.
# Touches nothing but next_wake_at (hold also sets last_hold); a no-op unless the status is on.
ap-wake() {
  local sec="${1:-}" nw
  [[ "$sec" =~ ^[0-9]+$ ]] && [ "$sec" -ge 1 ] && [ "$sec" -le 86400 ] || { echo "wake <seconds 1-86400> [reason]" >&2; return 2; }
  sec=$((10#$sec))  # no octal reading of a leading zero
  if [ "$(ap-status)" = on ]; then
    nw=$(( $(_ap_epoch "$(ap-now)") + sec ))
    _ap_update --arg w "$(_ap_iso "$nw")" '.next_wake_at = $w'
  fi
  echo "$sec"
}

# guard: ok | hold <reason> (exit 0 / 1). Used for a slot beyond the first running one only. Holds when free
# memory is under AUTOPILOT_GUARD_MEM_MIN_PCT (default 20) percent of the total, or the 1-minute load
# per CPU is over AUTOPILOT_GUARD_LOAD_MAX (default 1.5); when a probe cannot be read it holds too
# (fail closed: an extra slot is optional). Tests inject AUTOPILOT_GUARD_MEM_FREE_PCT / _LOAD / _NCPU.
_ap_mem_free_pct() {
  if [ -n "${AUTOPILOT_GUARD_MEM_FREE_PCT:-}" ]; then printf '%s' "$AUTOPILOT_GUARD_MEM_FREE_PCT"; return 0; fi
  local total pages ps free insp spec avail
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t > 0 && a != "") printf "%d", a * 100 / t}' /proc/meminfo; return 0
  fi
  if command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
    total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
    pages=$(vm_stat 2>/dev/null) || return 0
    ps=$(printf '%s\n' "$pages" | sed -nE 's/.*page size of ([0-9]+) bytes.*/\1/p' | head -1)
    free=$(printf '%s\n' "$pages" | sed -nE 's/^Pages free: +([0-9]+)\./\1/p')
    insp=$(printf '%s\n' "$pages" | sed -nE 's/^Pages inactive: +([0-9]+)\./\1/p')
    spec=$(printf '%s\n' "$pages" | sed -nE 's/^Pages speculative: +([0-9]+)\./\1/p')
    [[ "$total" =~ ^[0-9]+$ && "$ps" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] || return 0
    avail=$(( (free + ${insp:-0} + ${spec:-0}) * ps ))
    printf '%d' $(( avail * 100 / total ))
  fi
}
_ap_load_per_cpu() {
  local load ncpu
  load="${AUTOPILOT_GUARD_LOAD:-}"
  if [ -z "$load" ]; then
    if [ -r /proc/loadavg ]; then load=$(awk '{print $1}' /proc/loadavg)
    else load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}') || load=""; fi
  fi
  ncpu="${AUTOPILOT_GUARD_NCPU:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || true)}"
  [[ "$load" =~ ^[0-9]+(\.[0-9]+)?$ && "$ncpu" =~ ^[1-9][0-9]*$ ]] || return 0
  awk -v l="$load" -v n="$ncpu" 'BEGIN {printf "%.2f", l / n}'
}
ap-guard() {
  local min="${AUTOPILOT_GUARD_MEM_MIN_PCT:-20}" max="${AUTOPILOT_GUARD_LOAD_MAX:-1.5}" mem load
  mem=$(_ap_mem_free_pct) || mem=""; load=$(_ap_load_per_cpu) || load=""
  if ! [[ "$mem" =~ ^[0-9]+$ ]]; then echo "hold free memory unreadable"; return 1; fi
  if ! [[ "$load" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "hold load unreadable"; return 1; fi
  if [ "$mem" -lt "$min" ]; then echo "hold free memory ${mem}% is under ${min}%"; return 1; fi
  if awk -v l="$load" -v m="$max" 'BEGIN {exit !(l > m)}'; then echo "hold load ${load} per CPU is over ${max}"; return 1; fi
  echo "ok"
}

# Appends one JSON line {ts, outcome, merged, task} to the history log. One
# small O_APPEND write, so concurrent writers cannot interleave; failure-tolerant
# by design: a history problem must never break `record` (always returns 0).
# Only the task id is kept (anything else becomes ""), never free text.
ap-history-append() {
  local outcome="$1" merged="$2" task="$3" h line
  [[ "$task" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || task=""
  {
    h=$(ap-history-file)
    mkdir -p "$(dirname "$h")" &&
      line=$(jq -nc --arg ts "$(ap-now)" --arg o "$outcome" --argjson m "$merged" --arg t "$task" '{ts: $ts, outcome: $o, merged: $m, task: $t}') &&
      printf '%s\n' "$line" >> "$h"
  } 2>/dev/null || true
  return 0
}

AP_TASK_ID_RE='^T[0-9]+(-[0-9]+)?$'

# prune [repo-root]: drop the holds of tasks that no longer have a dev/TODO file. Needs a dev/TODO
# directory (a wrong root never wipes them); prints each dropped id.
ap-prune() {
  local root="${1:-$(ap-work-root)}" f id
  f=$(ap-state-file)
  [ -f "$f" ] && [ -d "$root/dev/TODO" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! compgen -G "$root/dev/TODO/$id-*.md" >/dev/null; then
      _ap_update --arg id "$id" 'if (.holds | type) == "object" then del(.holds[$id]) else . end' && printf '%s\n' "$id"
    fi
  done < <(jq -r '((.holds | objects) // {}) | keys[]' "$f" 2>/dev/null || true)
  return 0
}

# --- holds (T20261124-340374) ----------------------------------------------------
# A hold is a recorded fact: reason + one release condition (d152). The state keeps
# .holds = {"<T-id>": {kind, reason, cond, since}}; cond is the canonical condition text.

AP_HOLD_KIND_RE='^(waiting|needs-human|stalled)$'
AP_HOLD_USAGE='hold-add <task-id> <waiting|needs-human|stalled> "<until <time>|run:<id>|pr:<n>|file-changed <path>|task-left-todo <T-id>>" "<reason>"'

# _ap_hold_cond <words...>: print the canonical condition, or return 1 when it is not one of the five forms.
_ap_hold_cond() {
  local c arg
  c=$(printf '%s' "$*" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$c" in *$'\t'*|*$'\n'*) return 1 ;; esac   # the TSV listing and holds-check split on tabs
  case "$c" in
    "until "*)
      arg=$(printf '%s' "${c#until }" | sed -E 's/^[[:space:]]+//')
      [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?$ ]] || return 1
      case "$arg" in
        *T*:*:*) arg="${arg%Z}Z" ;;
        *T*) arg="${arg%Z}:00Z" ;;
        *) arg="${arg}T00:00:00Z" ;;
      esac
      [ -n "$(_ap_epoch "$arg")" ] || return 1
      printf 'until %s' "$arg" ;;
    run:*) [[ "${c#run:}" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$c" ;;
    pr:*) [[ "${c#pr:}" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$c" ;;
    "file-changed "*)
      arg=$(printf '%s' "${c#file-changed }" | sed -E 's/^[[:space:]]+//')
      case "$arg" in ""|/*|..|../*|*/../*|*/..) return 1 ;; esac
      printf 'file-changed %s' "$arg" ;;
    "task-left-todo "*)
      arg=$(printf '%s' "${c#task-left-todo }" | sed -E 's/^[[:space:]]+//')
      [[ "$arg" =~ $AP_TASK_ID_RE ]] || return 1
      printf 'task-left-todo %s' "$arg" ;;
    *) return 1 ;;
  esac
}

ap-hold-add() {
  local id="${1:-}" kind="${2:-}" reason cond f
  if [ $# -lt 4 ]; then echo "$AP_HOLD_USAGE" >&2; return 2; fi
  shift 2
  reason="${!#}"
  cond=$(_ap_hold_cond "${@:1:$#-1}") || { echo "hold-add: unknown release condition '${*:1:$#-1}'. $AP_HOLD_USAGE" >&2; return 2; }
  [[ "$id" =~ $AP_TASK_ID_RE ]] || { echo "hold-add: bad task id '$id'. $AP_HOLD_USAGE" >&2; return 2; }
  [[ "$kind" =~ $AP_HOLD_KIND_RE ]] || { echo "hold-add: unknown kind '$kind' (waiting|needs-human|stalled)" >&2; return 2; }
  reason=$(printf '%s' "$reason" | tr '\n\t\r' '   ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200)
  [ -n "$reason" ] || { echo "hold-add: a hold needs a reason (d152: no hold without a reason and a release condition)" >&2; return 2; }
  f=$(ap-state-file)
  if [ ! -s "$f" ]; then mkdir -p "$(dirname "$f")"; printf '{}\n' > "$f"; fi
  _ap_update --arg id "$id" --arg k "$kind" --arg c "$cond" --arg r "$reason" --arg now "$(ap-now)" \
    '.holds = (((.holds | objects) // {}) | .[$id] = {kind: $k, reason: $r, cond: $c, since: $now})' || return 1
  printf 'held %s %s\n' "$id" "$kind"
}

# holds [--json]
ap-holds() {
  local f; f=$(ap-state-file)
  if [ "${1:-}" = --json ]; then
    { [ -f "$f" ] && jq -c '[((.holds | objects) // {}) | to_entries | sort_by(.value.since, .key)[]
      | {task: .key, kind: .value.kind, reason: .value.reason, condition: .value.cond, since: .value.since}]' "$f" 2>/dev/null; } || echo '[]'
    return 0
  fi
  [ -f "$f" ] || return 0
  jq -r '((.holds | objects) // {}) | to_entries | sort_by(.value.since, .key)[]
    | [.key, .value.kind, .value.reason, .value.cond, .value.since] | join("\t")' "$f" 2>/dev/null || true
}

# release <task-id> -> released | none
ap-release() {
  local id="${1:-}" f
  [[ "$id" =~ $AP_TASK_ID_RE ]] || { echo "release <task-id>" >&2; return 2; }
  f=$(ap-state-file)
  if [ -f "$f" ] && jq -e --arg id "$id" '((.holds | objects) // {}) | has($id)' "$f" >/dev/null 2>&1; then
    _ap_update --arg id "$id" 'del(.holds[$id])' || return 1
    echo released
  else
    echo none
  fi
}

# hold-report <file> [--fallback T<id>] [--repo <root>] (see the usage header)
ap-hold-report() {
  local src="" fallback="" root="" id st reason source kind cond f line stuck tab=$'\t'
  while [ $# -gt 0 ]; do
    case "$1" in
      --fallback) fallback="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
      --repo) root="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
      *) [ -n "$src" ] || src="$1"; shift ;;
    esac
  done
  { [ -n "$src" ] && [ -f "$src" ]; } || { echo "hold-report <file> [--fallback T<id>] [--repo <root>]" >&2; return 2; }
  [ -n "$root" ] || root=$(ap-work-root)
  [ "$(ap-status)" = on ] || return 0
  stuck=$(jq -r '(.stuck_count | numbers) // 0' "$(ap-state-file)" 2>/dev/null || echo 0)
  local plan; plan=$(ap-plan "$src" ${fallback:+--fallback "$fallback"}) || return $?
  local seen=" "
  while IFS=$tab read -r id st reason source; do
    [ -n "$id" ] || continue
    seen="$seen$id "
    [ "$st" = stalled ] || continue
    case "$source" in
      attention)
        kind=needs-human
        f=$(compgen -G "$root/dev/TODO/$id-*.md" | head -1) || true
        if [ -n "$f" ]; then cond="file-changed dev/TODO/$(basename "$f")"; else cond="until $(_ap_iso $(( $(_ap_epoch "$(ap-now)") + 86400 )))"; fi ;;
      *)
        kind=stalled
        if [ "$stuck" -ge 3 ]; then printf 'skip %s\n' "$id"; continue; fi
        cond="until $(_ap_iso $(( $(_ap_epoch "$(ap-now)") + 7200 )))" ;;
    esac
    ap-hold-add "$id" "$kind" "$cond" "$reason" || true
  done <<< "$plan"
  if [ -n "$fallback" ] && [[ "$fallback" =~ $AP_TASK_ID_RE ]]; then
    case "$seen" in *" $fallback "*) ;; *)
      line=$(_ap_report_lines "$src" | grep -m1 '^WAITING:' || true)
      if [ -n "$line" ]; then
        ap-hold-add "$fallback" waiting "until $(_ap_iso $(( $(_ap_epoch "$(ap-now)") + 3600 )))" "waiting: ${line#WAITING:}" || true
      fi ;;
    esac
  fi
  return 0
}

_ap_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }

# _ap_hold_met <condition> <since-iso> <root>: exit 0 when the release condition holds. Anything that
# cannot be read (gh error, missing path or directory) is "not met": a hold is never dropped on a guess.
_ap_hold_met() {
  local cond="$1" since="$2" root="$3" arg v se mt
  case "$cond" in
    "until "*) se=$(_ap_epoch "${cond#until }"); v=$(_ap_epoch "$(ap-now)"); [ -n "$se" ] && [ -n "$v" ] && [ "$v" -ge "$se" ] ;;
    run:*) arg="${cond#run:}"; v=$(cd "$root" && gh api "repos/{owner}/{repo}/actions/runs/$arg" --jq .status 2>/dev/null) || return 1; [ "$v" = completed ] ;;
    pr:*) arg="${cond#pr:}"; v=$(cd "$root" && gh api "repos/{owner}/{repo}/pulls/$arg" --jq .state 2>/dev/null) || return 1; [ "$v" = closed ] ;;
    "file-changed "*)
      arg="${cond#file-changed }"; se=$(_ap_epoch "$since"); [ -n "$se" ] || return 1
      mt=$(_ap_mtime "$root/$arg")
      if [ -n "$mt" ] && [ "$mt" -gt "$se" ]; then return 0; fi
      [ -n "$(git -C "$root" log -1 --format=%H --since="$since" -- "$arg" 2>/dev/null)" ] ;;
    "task-left-todo "*)
      arg="${cond#task-left-todo }"; [ -d "$root/dev/TODO" ] || return 1
      ! compgen -G "$root/dev/TODO/$arg-*.md" >/dev/null ;;
    *) return 1 ;;
  esac
}

# holds-check [repo-root]: release every hold whose condition is met; print "released <task> (<condition>)".
ap-holds-check() {
  local root="${1:-$(ap-work-root)}" f id cond since
  f=$(ap-state-file)
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r id cond since; do
    [ -n "$id" ] || continue
    if _ap_hold_met "$cond" "$since" "$root"; then
      _ap_update --arg id "$id" 'del(.holds[$id])' && printf 'released %s (%s)\n' "$id" "$cond"
    fi
  done < <(jq -r '((.holds | objects) // {}) | to_entries | sort_by(.value.since, .key)[] | [.key, .value.cond, .value.since] | join("\t")' "$f" 2>/dev/null || true)
  return 0
}

# stats [--json]: progress over the rolling last 24 h (now-86400 < ts <= now) and lifetime
# averages per 24 h. One jq pass over the state file and the history log.
#   - window counts come from the history log only (cycles exclude `capped` ticks,
#     which dispatch nothing), so they are exact from the first logged cycle;
#   - lifetime totals come from the state's lifetime_cycles/lifetime_merged (the
#     baseline from before the log existed, kept across off/start), or the log when larger;
#   - lifetime days = max(1, (now - earliest of lifetime_started_at, first log ts) / 86400);
#   - trend compares merged_24h with the average rounded to 1 decimal: up|down|flat
#     ("same" = equal at that one displayed decimal, so an integer count is flat only
#     against an average that rounds to a whole number such as 5.0);
#   - `approx` is true when the log does not reach back over the whole window (no log
#     yet, or its first line is newer than now-24h) while the state shows a cycle inside
#     the window: the work the log lacks is then estimated from the state's calendar-day
#     counters (cycles_today/merges_today, the day of the last cycle), and merged_24h and
#     cycles_24h are the larger of log and counters. That is an ESTIMATE, not a bound: the
#     counters cover a local calendar day, so they can include work older than the window
#     (over-count) or miss the earlier-day part of it, or have just been rolled to zero
#     (under-count). Consumers must label it, and the HUD draws no trend arrow for it. With no log and
#     no cycle inside the window the 24h figures are an exact zero (approx false).
# Timestamps must be strict UTC (YYYY-MM-DDTHH:MM:SSZ, what `record` writes); future-dated
# or malformed history lines are skipped. Never fails on missing files (all zero).
ap-stats() {
  local json=0 sf hf now_e out
  case "${1:-}" in --json) json=1 ;; '') ;; *) echo "stats [--json]" >&2; return 2 ;; esac
  sf=$(ap-state-file); hf=$(ap-history-file)
  [ -f "$sf" ] || sf=/dev/null
  [ -f "$hf" ] || hf=/dev/null
  now_e=$(_ap_epoch "$(ap-now)"); [[ "$now_e" =~ ^[0-9]+$ ]] || now_e=$(date -u +%s)
  out=$(jq -n -R -c --argjson now "$now_e" --slurpfile st "$sf" '
    def ep: try fromdateiso8601 catch null;
    def n: if type == "number" and . >= 0 then . else 0 end;
    def r2: (. * 100 | round) / 100;
    ($st[0] | if type == "object" then . else {} end) as $s
    | [inputs | fromjson? | select(type == "object")
       # old logs may hold visit|advance|park lines from the retired counter: not cycles
       | select(((.outcome | strings // "") | IN("visit", "advance", "park")) | not)
       | select((.ts | strings | ep) != null) | {t: (.ts | ep), o: (.outcome | strings // ""), m: (.merged | n)}] as $h
    | ($now - 86400) as $cut
    | ($h | map(select(.t > $cut and .t <= $now))) as $w
    | def cyc: map(select(.o != "capped")) | length;
      def cnt($k): map(select(.o == $k)) | length;
      ([(($s.lifetime_cycles // $s.cycle_count) | n), ($h | cyc)] | max) as $lc
    | ([(($s.lifetime_merged // $s.merged_count) | n), ($h | map(.m) | add // 0)] | max) as $lm
    | ([($s.lifetime_started_at // $s.started_at | strings | ep), ($h | map(.t) | min)] | map(select(. != null)) | min // $now) as $start
    | ((($now - $start) / 86400) | if . < 1 then 1 else . end) as $days
    | ($lm / $days | r2) as $am | ($lc / $days | r2) as $ac
    | ($s.last_cycle_at | if type == "string" then ep else null end) as $lct
    | ((($h | map(.t) | min) as $hmin | $hmin == null or $hmin > $cut) and $lct != null and $lct > $cut and $lct <= $now) as $approx
    | (if $approx then ($s.merges_today | n) else 0 end) as $est_m
    | (if $approx then ($s.cycles_today | n) else 0 end) as $est_c
    | ([($w | map(.m) | add // 0), $est_m] | max) as $m24
    | {has_history: (($h | length) > 0), window_hours: 24, approx: $approx,
       cycles_24h: ([($w | cyc), $est_c] | max), merged_24h: $m24,
       stuck_24h: ($w | cnt("stuck")), waiting_24h: ($w | cnt("waiting")), idle_24h: ($w | cnt("idle")),
       lifetime_cycles: $lc, lifetime_merged: $lm, lifetime_days: ($days | r2),
       avg_cycles_24h: $ac, avg_merged_24h: $am,
       trend: (($am * 10 | round) / 10 | if $m24 > . then "up" elif $m24 < . then "down" else "flat" end)}' "$hf" 2>/dev/null) || out=""
  [ -n "$out" ] || { echo "stats: could not read state/history" >&2; return 1; }
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | jq -r '
    (if .trend == "up" then "▲" elif .trend == "down" then "▼" else "=" end) as $m
    | (if .approx then "24h: ~\(.merged_24h) merged/~\(.cycles_24h) cycles (estimate from the calendar-day counters, the log does not cover 24h yet)"
       elif .has_history then "24h: \(.merged_24h) merged/\(.cycles_24h) cycles (\(.stuck_24h) stuck, \(.waiting_24h) waiting, \(.idle_24h) idle) \($m)"
       else "24h: no history logged yet" end),
      "lifetime: \(.lifetime_merged) merged/\(.lifetime_cycles) cycles over \(.lifetime_days) days · average \(.avg_merged_24h) merged/\(.avg_cycles_24h) cycles per 24h"'
}

# record <outcome> [merged] [task-id] [reason] -> notice kind (or none)
ap-record() {
  _ap_parse_slot "$@" || return 2
  set -- ${AP_REST[@]+"${AP_REST[@]}"}
  local outcome="${1:?outcome}" merged="${2:-0}" task="${3:-}" reason="${4:-}" f notice=none
  case "$outcome" in progress|idle|stuck|waiting|bottomed|capped) ;; *) echo "bad outcome: $outcome" >&2; return 1 ;; esac
  [[ "$merged" =~ ^[0-9]+$ ]] || merged=0
  [ "$(ap-status)" = on ] || { echo none; return 0; }
  f=$(ap-state-file)
  _ap_roll_day
  local was_idle was_stuck was_wait was_capped cycle=1 d nw
  was_idle=$(jq -r '.idle_notified' "$f"); was_stuck=$(jq -r '.stuck_notified' "$f")
  was_wait=$(jq -r '.waiting_notified' "$f"); was_capped=$(jq -r '.capped_notified' "$f")
  [ "$outcome" = capped ] && cycle=0   # a capped tick dispatched nothing
  _ap_update --arg o "$outcome" --arg now "$(ap-now)" --arg t "$task" --arg r "$reason" --argjson m "$merged" --argjson c "$cycle" --arg slot "$AP_SLOT" '
    (.lifetime_started_at //= .started_at) | (.lifetime_cycles //= .cycle_count) | (.lifetime_merged //= .merged_count)
    | .lifetime_cycles += $c | .lifetime_merged += $m
    | .cycle_count += $c | .cycles_today += $c | .merged_count += $m | .merges_today += $m
    | .last_cycle_at = (if $c == 1 then $now else .last_cycle_at end) | .last_outcome = $o
    | .last_task = (if $t == "" then null else $t end)
    | .last_stuck_reason = (if $o == "stuck" and $r != "" then $r else null end)
    | .stuck_count = (if $o == "stuck" then .stuck_count + 1 elif $o == "waiting" or $o == "bottomed" then .stuck_count else 0 end)
    | .waiting_count = (if $o == "waiting" then .waiting_count + 1 elif $o == "bottomed" then .waiting_count else 0 end)
    | '"$AP_JQ_MIGRATE"' | .slots |= del(.[$slot]) | '"$AP_JQ_MIRROR"
  ap-history-append "$outcome" "$merged" "$task"
  case "$outcome" in
    progress)
      [ "$was_idle" = true ] && notice=resumed
      _ap_update '.idle_notified = false | .stuck_notified = false | .waiting_notified = false | .capped_notified = false' ;;
    idle)
      if [ "$was_idle" != true ]; then notice=idle; _ap_update '.idle_notified = true'; fi ;;
    stuck)
      if [ "$(jq -r .stuck_count "$f")" -ge 3 ] && [ "$was_stuck" != true ]; then notice=stuck; _ap_update '.stuck_notified = true'; fi ;;
    waiting)
      if [ "$(jq -r .waiting_count "$f")" -ge 2 ] && [ "$was_wait" != true ]; then notice=waiting; _ap_update '.waiting_notified = true'; fi ;;
    capped)
      if [ "$was_capped" != true ]; then notice=capped; _ap_update '.capped_notified = true'; fi ;;
    bottomed) : ;;
  esac
  d=$(ap-delay "$outcome"); nw=$(( $(_ap_epoch "$(ap-now)") + d ))
  _ap_update --arg w "$(_ap_iso "$nw")" '.next_wake_at = $w'
  echo "$notice"
}

# A `Blocked by` status is not auto-driven (prose words like SUPERVISED are not gates). The
# definition is shared with todo-next.sh --skip-gated (todo-gated, _lib.sh).
ap-eligible() {
  local file="${1:?task file}" line
  [ -f "$file" ] || return 1
  # shellcheck source=../../todo/scripts/_lib.sh
  source "$(_ap_dir)/../../todo/scripts/_lib.sh"
  line=$(awk 'NR==1&&$0!="---"{exit} /^---$/{n++; if(n==2)exit} n==1&&/^status:/{print; exit}' "$file")
  if todo-gated "$line"; then return 1; fi
  return 0
}

# --- the repo the dispatcher reads --------------------------------------------

# The dispatch clone (pulled every cycle) when the state names a live one, else the repo root.
# AUTOPILOT_REPO_ROOT overrides both (tests, the final report).
ap-work-root() {
  local f c
  if [ -n "${AUTOPILOT_REPO_ROOT:-}" ]; then printf '%s' "$AUTOPILOT_REPO_ROOT"; return 0; fi
  f=$(ap-state-file)
  c=$(jq -r '.dispatch_clone_path // empty' "$f" 2>/dev/null || true)
  if [ -n "$c" ] && [ -d "$c/dev/TODO" ]; then printf '%s' "$c"; else _ap_root; fi
}

# --- tier cursors (T20261124-670976) -------------------------------------------
# A task's tier is its frontmatter `tier:` (todo-tier, default 3). The pick is made inside the
# highest tier (lowest number) with an eligible task; a per-tier cursor (state `.cursors`, tier ->
# the last task dispatched from it) rotates that tier's queue-order list so the task just dispatched
# comes last: a task that ended without a hold is not re-picked ahead of its tier-mates, and the
# list wraps. Only a recorded hold (`holds`) makes the pick pass over a task (d152).

# _ap_tier_of <root> <task-id>: the task file's effective tier, nothing when it has no file there.
_ap_tier_of() {
  local f
  f=$(compgen -G "$1/dev/TODO/$2-*.md" | head -1) || true
  [ -n "$f" ] || return 0
  # shellcheck source=../../todo/scripts/_lib.sh
  ( source "$(_ap_dir)/../../todo/scripts/_lib.sh" && todo-tier "$f" )
}

# _ap_cursor_set <task-id>: remember it as its tier's cursor (a task without a file is ignored).
_ap_cursor_set() {
  local t
  t=$(_ap_tier_of "$(ap-work-root)" "$1") || true
  [[ "$t" =~ ^[1-4]$ ]] || return 0
  _ap_update --arg t "$t" --arg id "$1" '.cursors = (((.cursors | objects) // {}) | .[$t] = $id)' || true
}

# held task ids, comma separated
_ap_held() { jq -r '((.holds | objects) // {}) | keys | join(",")' "$(ap-state-file)" 2>/dev/null || true; }

# in-flight and held ids as one --exclude list (empty when none)
_ap_exclude() {
  local a b; a=$(_ap_inflight); b=$(_ap_held)
  if [ -n "$a" ] && [ -n "$b" ]; then printf '%s,%s' "$a" "$b"; else printf '%s%s' "$a" "$b"; fi
}

# _ap_rotate <tier> : stdin = a tier's ids in queue order; stdout = the same ids, the tier's cursor task last.
_ap_rotate() {
  local c i n=0 pos=-1; local -a ids
  c=$(jq -r --arg t "$1" '((.cursors | objects) // {})[$t] // empty' "$(ap-state-file)" 2>/dev/null || true)
  ids=(); while IFS= read -r i; do [ -z "$i" ] || ids+=("$i"); done
  n=${#ids[@]}; [ "$n" -gt 0 ] || return 0
  if [ -n "$c" ]; then for ((i = 0; i < n; i++)); do [ "${ids[i]}" = "$c" ] && pos=$i; done; fi
  for ((i = pos + 1; i < n; i++)); do printf '%s\n' "${ids[i]}"; done
  if [ "$pos" -ge 0 ]; then for ((i = 0; i <= pos; i++)); do printf '%s\n' "${ids[i]}"; done; fi
}

# top [repo-root] [--nth N] [--urgent]: the id of the first (Nth) task of the tiered order: tiers 1..4
# (--urgent: 1 and 2 only, what a reserved slot may take), each tier in queue order rotated by its cursor,
# skipping gated tasks, tasks in flight in a busy slot (and tasks Blocked by one) and held tasks. Nothing
# when none. With no cursor and no tiers set it is the id bare /drive picks.
ap-top() {
  local root="" nth=1 urgent=0 tiers="1 2 3 4" t excl order="" ids all
  while [ $# -gt 0 ]; do
    case "$1" in
      --nth) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "top [repo-root] [--nth N] [--urgent]" >&2; return 2; }; nth="$2"; shift 2 ;;
      --urgent) urgent=1; tiers="1 2"; shift ;;
      *) root="$1"; shift ;;
    esac
  done
  [ -n "$root" ] || root=$(ap-work-root)
  excl=$(_ap_exclude)
  # one scan of the queue (it is the slow part): "<id><TAB><tier>" in queue order, gated tasks left out
  local -a args=(--skip-gated --ids)
  [ "$urgent" = 0 ] || args+=(--tier 1,2)
  all=$(cd "$root" && bash "$(_ap_dir)/../../todo/scripts/todo-next.sh" "${args[@]}" 2>/dev/null) || all=""
  for t in $tiers; do
    # rotate the tier's whole list (so the cursor keeps its place even while its task is in flight or held),
    # then keep only the tasks that are free to pick
    ids=$(printf '%s\n' "$all" | awk -F'\t' -v t="$t" '$2 == t {print $1}')
    order="$order$(printf '%s\n' "$ids" | _ap_rotate "$t" | grep -vxF -f <(printf '%s\n' "${excl//,/$'\n'}") || true)"$'\n'
  done
  # the claim check is the slow part of a scan: make it only for the candidates in order, until the Nth is free
  local id n=0 picked=""
  while IFS= read -r id; do
    [[ "$id" =~ $AP_TASK_ID_RE ]] || continue
    case "$(cd "$root" && . "$(_ap_dir)/../../todo/scripts/_lib.sh" && todo-claim-state "$id" "$TODO_LIB_REPO_ROOT")" in peer:*) continue ;; esac
    n=$((n + 1))
    if [ "$n" -ge "$nth" ]; then picked="$id"; break; fi
  done <<< "$order"
  [ -z "$picked" ] || printf '%s\n' "$picked"
  return 0
}

# pickable [repo-root]: pick | drift | none (see the usage header). Tasks in flight in a busy slot and held
# tasks are not pickable; drift (a /drive sweep would fix mechanical findings) only counts when no slot is busy.
ap-pickable() {
  local root="${1:-$(ap-work-root)}" scripts plan excl; local -a args=(--skip-gated --check)
  scripts="$(_ap_dir)/../../todo/scripts"
  excl=$(_ap_exclude); [ -z "$excl" ] || args+=(--exclude "$excl")
  if (cd "$root" && bash "$scripts/todo-next.sh" "${args[@]}") 2>/dev/null; then echo pick; return 0; fi
  if _ap_is_busy; then echo none; return 0; fi
  plan=$(bash "$scripts/todo-sweep.sh" plan --root "$root" 2>/dev/null || true)
  if printf '%s\n' "$plan" | grep -qE $'^(ADD|REMOVE|UNBLOCK|CLOSE_DONE|ORDER_VIOLATION)\t'; then echo drift; else echo none; fi
}

# Never errors: Slack when it works, else only the state file. Every notice is
# appended to .notices (last 20) with via: slack|fallback.
ap-notify() {
  local kind="${1:?kind}" text="${2:?text}" sender out="" via=fallback
  sender="${AUTOPILOT_SLACK_SEND:-$(_ap_dir)/../../slack/scripts/slack-send.sh}"
  if [ -f "$sender" ] && out=$(bash "$sender" --channel dev "$text" 2>&1) && printf '%s' "$out" | grep -qi 'sent successfully'; then via=slack; fi
  if [ -f "$(ap-state-file)" ]; then
    _ap_update --arg k "$kind" --arg t "$text" --arg v "$via" --arg now "$(ap-now)" \
      '.notices = (((.notices // []) + [{kind: $k, text: $t, via: $v, at: $now}]) | .[-20:])' 2>/dev/null || true
  fi
  echo "$via"
  return 0
}

ap-report() {
  local f st; f=$(ap-state-file); st=$(ap-status)
  echo "autopilot: $st"
  [ "$st" = off ] && return 0
  jq -r '"cycles \(.cycle_count) (today \(.cycles_today)), merged \(.merged_count) (today \(.merges_today)), stuck \(.stuck_count), last \(.last_outcome // "none")",
         (if .next_wake_at then "next cycle \(.next_wake_at)" else empty end),
         (.notices[-3:][]? | "notice [\(.via)] \(.kind): \(.text)")' "$f"
  ap-holds | while IFS=$'\t' read -r aid kind areason acond _; do
    [ -z "$aid" ] || printf 'held: %s (%s) — %s; releases on %s\n' "$aid" "$kind" "$areason" "$acond"
  done
  ap-config-notices
  echo "slots: $(_ap_busy_count) of $(ap-max-dop) running ($(ap-routine-line))"
  local sl stask ssince
  while IFS=$'\t' read -r sl stask ssince; do [ -z "$sl" ] || printf '  slot %s: %s since %s\n' "$sl" "${stask:-a cycle}" "$ssince"; done < <(_ap_slots)
  jq -r 'select(.last_hold) | "last hold \(.last_hold.at): \(.last_hold.reason)"' "$f" 2>/dev/null || true
  if [ "$st" = on ] && [ "$(_ap_busy_count)" -lt "$(ap-routine-limit)" ] && ! _ap_is_busy; then
    local w we now; w=$(jq -r '.next_wake_at // empty' "$f"); we=$(_ap_epoch "$w"); now=$(_ap_epoch "$(ap-now)")
    if [ -n "$we" ] && [ -n "$now" ] && [ $(( now - we )) -gt 600 ]; then echo "overdue: no wake fired since $w — type /autopilot on to recover"; fi
  fi
}

# --- classify: a /drive sub-agent's final report -> a `record` line ----------

# Report lines, normalized: CR, leading bullets/quotes/backticks and ** removed.
_ap_report_lines() {
  local src="${1:--}"
  if [ "$src" = - ]; then cat; else [ -f "$src" ] || return 2; cat "$src"; fi \
    | sed -E 's/\r$//; s/\*\*//g; s/^[[:space:]>`_*-]+//'
}

# _ap_id_reason <text>: prints "<id><TAB><reason>" when the text starts with a task id (the longest
# match, so a bare id never splits at its own dash), dropping a leading dash / em dash separator.
_ap_id_reason() {
  local rest="$1" id reason re_id='^(T[0-9]+(-[0-9]+)?)'
  [[ "$rest" =~ $re_id ]] || return 1
  id="${BASH_REMATCH[1]}"; reason="${rest#"$id"}"
  reason=$(printf '%s' "$reason" | sed -E 's/^[[:space:]]*(—|-)?[[:space:]]*//')
  printf '%s\t%s\n' "$id" "$reason"
}

_ap_strip_runs() { sed -E 's/[[:space:]]*;[[:space:]]*runs:.*$//; s/[[:space:]]+$//'; }

ap-classify() {
  local src="${1:-}" line rest id reason lines
  [ -n "$src" ] || { echo "classify <file|->" >&2; return 2; }
  lines=$(_ap_report_lines "$src") || { echo "classify: no such file: $src" >&2; return 2; }
  local merged=0 merged_id="" stuck=0 stuck_id="" stuck_reason="" waiting=0 wait_reason="" attn=0 adv=0 adv_id=""
  local re_id='^(T[0-9]+(-[0-9]+)?)'
  while IFS= read -r line; do
    case "$line" in
      MERGED:*)
        rest=$(printf '%s' "${line#MERGED:}" | sed -E 's/^[[:space:]]+//')
        case "$rest" in ''|'<'*|'T<'*) continue ;; esac   # empty or the unfilled template
        merged=$(( merged + 1 ))
        if [[ "$rest" =~ $re_id ]]; then merged_id="${BASH_REMATCH[1]}"; fi ;;
      STUCK:*)
        rest=$(printf '%s' "${line#STUCK:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
        case "$rest" in ''|'<'*) continue ;; esac
        stuck=1; stuck_id=""; stuck_reason="$rest"
        if [[ "$rest" =~ (.*)[[:space:]]+—[[:space:]]+last[[:space:]]+task[[:space:]]+(T[0-9]+(-[0-9]+)?) ]]; then
          stuck_reason="${BASH_REMATCH[1]}"; stuck_id="${BASH_REMATCH[2]}"
        fi ;;
      WAITING:*)
        rest=$(printf '%s' "${line#WAITING:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
        case "$rest" in ''|'<'*) continue ;; esac
        waiting=1; wait_reason="$rest" ;;
      ADVANCED:*)
        rest=$(printf '%s' "${line#ADVANCED:}" | sed -E 's/^[[:space:]]+//')
        if [[ "$rest" =~ $re_id ]]; then adv=$(( adv + 1 )); adv_id="${BASH_REMATCH[1]}"; fi ;;
      NEEDS-ATTENTION:*)
        rest=$(printf '%s' "${line#NEEDS-ATTENTION:}" | sed -E 's/^[[:space:]]+//')
        if [[ "$rest" =~ $re_id ]]; then attn=$(( attn + 1 )); fi ;;
    esac
  done <<EOF_LINES
$lines
EOF_LINES
  # Precedence follows autopilot/SKILL.md Phase 4: progress (merged or advanced, nothing
  # stuck), waiting (nothing merged), stuck, then a lone NEEDS-ATTENTION = progress with 0
  # merged (the stalled task gets a hold; wake in 60 s).
  if [ "$merged" -gt 0 ] && [ "$stuck" = 0 ]; then
    printf 'progress %s %s -\n' "$merged" "${merged_id:--}"
  elif [ "$adv" -gt 0 ] && [ "$stuck" = 0 ] && [ "$waiting" = 0 ]; then
    printf 'progress 0 %s -\n' "${adv_id:--}"
  elif [ "$merged" = 0 ] && [ "$waiting" = 1 ]; then
    printf 'waiting 0 - %s\n' "$wait_reason"
  elif [ "$stuck" = 1 ]; then
    [ -n "$stuck_id" ] || stuck_id="${merged_id:--}"
    printf 'stuck %s %s %s\n' "$merged" "$stuck_id" "${stuck_reason:-stuck}"
  elif [ "$attn" -gt 0 ]; then
    printf 'bottomed 0 - only needs-attention tasks reported\n'
  else
    printf 'stuck 0 - dispatch failed or report unparseable\n'
    return 2
  fi
}

ap-attention() {
  local src="${1:-}" line rest ir reason
  [ -n "$src" ] || { echo "attention <file|->" >&2; return 2; }
  local lines; lines=$(_ap_report_lines "$src") || { echo "attention: no such file: $src" >&2; return 2; }
  while IFS= read -r line; do
    case "$line" in NEEDS-ATTENTION:*) ;; *) continue ;; esac
    rest=$(printf '%s' "${line#NEEDS-ATTENTION:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
    ir=$(_ap_id_reason "$rest") || continue
    reason="${ir#*$'\t'}"
    printf '%s\t%s\n' "${ir%%$'\t'*}" "${reason:-needs attention}"
  done <<EOF_LINES
$lines
EOF_LINES
}

# plan <file|-> [--fallback T<id>]: one "<task-id><TAB>advanced|stalled<TAB><reason><TAB><source>" line
# per task the report names, in order of first appearance (source: merged|advanced|attention|stuck).
# advanced = on a MERGED: or ADVANCED: line; stalled = on a NEEDS-ATTENTION: line, or the "last task"
# of a STUCK: line, and not also advanced. A STUCK without a task id names the --fallback task (the
# one the dispatcher recorded before dispatch) when given. WAITING lines and an unparseable report
# name nothing (`hold-report` handles WAITING).
ap-plan() {
  local src="" fallback="" line rest id reason recs="" lines
  while [ $# -gt 0 ]; do
    case "$1" in
      --fallback) fallback="${2:-}"; shift; [ $# -eq 0 ] || shift ;;
      *) [ -n "$src" ] || src="$1"; shift ;;
    esac
  done
  [ -n "$src" ] || { echo "plan <file|-> [--fallback T<id>]" >&2; return 2; }
  [ -z "$fallback" ] || [[ "$fallback" =~ $AP_TASK_ID_RE ]] || fallback=""
  lines=$(_ap_report_lines "$src") || { echo "plan: no such file: $src" >&2; return 2; }
  local re_stuck='(.*)[[:space:]]+—[[:space:]]+last[[:space:]]+task[[:space:]]+(T[0-9]+(-[0-9]+)?)' tab=$'\t' ir
  while IFS= read -r line; do
    case "$line" in
      MERGED:*|ADVANCED:*)
        rest=$(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
        if ir=$(_ap_id_reason "$rest"); then
          id="${ir%%"$tab"*}"; reason="${ir#*"$tab"}"
          recs="${recs}${id}${tab}advanced${tab}$(printf '%s' "${reason:-advanced}" | tr '\t' ' ')${tab}$(printf '%s' "${line%%:*}" | tr 'A-Z' 'a-z')"$'\n'
        fi ;;
      STUCK:*)
        rest=$(printf '%s' "${line#STUCK:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
        case "$rest" in ''|'<'*) continue ;; esac
        if [[ "$rest" =~ $re_stuck ]]; then
          recs="${recs}${BASH_REMATCH[2]}${tab}stalled${tab}$(printf '%s' "${BASH_REMATCH[1]:-stuck}" | tr '\t' ' ')${tab}stuck"$'\n'
        elif [ -n "$fallback" ]; then
          recs="${recs}${fallback}${tab}stalled${tab}$(printf '%s' "$rest" | tr '\t' ' ')${tab}stuck"$'\n'
        fi ;;
      NEEDS-ATTENTION:*)
        rest=$(printf '%s' "${line#NEEDS-ATTENTION:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
        if ir=$(_ap_id_reason "$rest"); then
          id="${ir%%"$tab"*}"; reason="${ir#*"$tab"}"
          recs="${recs}${id}${tab}stalled${tab}$(printf '%s' "${reason:-needs attention}" | tr '\t' ' ')${tab}attention"$'\n'
        fi ;;
    esac
  done <<EOF_LINES
$lines
EOF_LINES
  printf '%s' "$recs" | awk -F'\t' '
    { ids[NR] = $1; st[NR] = $2; rs[NR] = $3; sr[NR] = $4; if ($2 == "advanced" && !($1 in ar)) { ar[$1] = $3; as[$1] = $4 } }
    END { for (i = 1; i <= NR; i++) { if (seen[ids[i]]++) continue
            if (ids[i] in ar) print ids[i] "\tadvanced\t" ar[ids[i]] "\t" as[ids[i]]; else print ids[i] "\tstalled\t" rs[i] "\t" sr[i] } }'
}

# --- dispatch clone path ------------------------------------------------------

_ap_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum
  else openssl dgst -sha256 | sed 's/^.* //'; fi
}

ap-clone-path() {
  _ap_parse_slot "$@" || return 2
  local root="${AP_REST[0]:-}" hash suffix=""
  [ -n "$root" ] || root=$(_ap_root)
  [ "$AP_SLOT" = 1 ] || suffix="-s$AP_SLOT"
  hash=$(printf '%s' "$root" | _ap_sha256 | cut -c1-8)
  printf '/tmp/autopilot-clone-%s-%s%s\n' "$(basename "$root")" "$hash" "$suffix"
}

# --- final report -------------------------------------------------------------

# "T<id> (<slug>)" from the task's file name under dev/{TODO,PARKING,JOURNAL}; bare id when not found.
_ap_label() {
  local id="$1" root f b slug; root=$(ap-repo-root)
  for f in "$root"/dev/TODO/"$id"-*.md "$root"/dev/PARKING/"$id"-*.md "$root"/dev/JOURNAL/*-"$id"-*.md; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .md); slug="${b#*"$id"-}"
    printf '%s (%s)' "$id" "$slug"; return 0
  done
  printf '%s' "$id"
}

# The PR a journal file records: frontmatter pr:, else the one distinct "PR #n" in it, else none.
_ap_journal_pr() {
  local f="$1" pr prs
  [ -f "$f" ] || return 0
  pr=$(awk 'NR==1&&$0!="---"{exit} /^---$/{n++; if(n==2)exit} n==1&&/^pr:/{sub(/^pr:[[:space:]]*/,""); print; exit}' "$f")
  pr=$(printf '%s' "$pr" | grep -Eo '[0-9]+' | tail -1 || true)
  if [ -z "$pr" ]; then
    prs=$(grep -Eo 'PR #[0-9]+' "$f" | sort -u || true)
    [ "$(printf '%s\n' "$prs" | grep -c .)" = 1 ] && pr="${prs#PR #}"
  fi
  [ -z "$pr" ] || printf '%s' "$pr"
}

ap-done() {
  local f started root path b id slug pr n=0; f=$(ap-state-file); root=$(_ap_root)
  started=$(jq -r '.run_started_at // .started_at // empty' "$f" 2>/dev/null || true)
  if [ -n "$started" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      b=$(basename "$path" .md); id=""; slug="$b"
      if [[ "$b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(T[0-9]+(-[0-9]+)?)-(.*)$ ]]; then id="${BASH_REMATCH[1]}"; slug="${BASH_REMATCH[3]}"; fi
      pr=$(_ap_journal_pr "$root/$path")
      printf -- '- Merged %s%s\n' "${id:+$id }($slug)" "${pr:+ — PR #$pr}"
      n=$(( n + 1 ))
    done < <(git -C "$root" log --since="$started" --diff-filter=A --name-only --pretty=format: -- dev/JOURNAL/ 2>/dev/null \
      | grep -E '^dev/JOURNAL/[0-9]{4}-[0-9]{2}-[0-9]{2}-[^/]*\.md$' | sort -u || true)
  fi
  [ "$n" -gt 0 ] || echo "- No tasks merged this run"
}

ap-final-report() {
  local why=user-requested f started se now secs h m el
  while [ $# -gt 0 ]; do
    case "$1" in
      --stopped) why="${2:?--stopped needs a reason}"; shift 2 ;;
      *) echo "final-report [--stopped <why>]" >&2; return 2 ;;
    esac
  done
  f=$(ap-state-file)
  [ -f "$f" ] || { echo "final-report: no state file" >&2; return 2; }
  started=$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)
  se=$(_ap_epoch "$started"); now=$(_ap_epoch "$(ap-now)"); el="unknown"
  if [ -n "$se" ] && [ -n "$now" ] && [ "$now" -ge "$se" ]; then
    secs=$(( now - se )); h=$(( secs / 3600 )); m=$(( secs % 3600 / 60 ))
    if [ "$h" -gt 0 ]; then el="${h}h ${m}m"; else el="${m}m"; fi
  fi
  printf 'Autopilot run: %s elapsed — stopped: %s\n\nDone:\n' "$el" "$why"
  ap-done
  printf '\nNeeds your attention:\n'
  local out="" id kind reason cond ids
  while IFS=$'\t' read -r id kind reason cond _; do
    [ -n "$id" ] || continue
    out="${out}- Held ($kind): $(_ap_label "$id") — ${reason}; releases on ${cond}"$'\n'
  done < <(ap-holds)
  ids=$(ap-holds | cut -f1)
  if [ "$(jq -r '.last_outcome // empty' "$f")" = stuck ]; then
    id=$(jq -r '.last_task // empty' "$f"); reason=$(jq -r '.last_stuck_reason // "stuck"' "$f")
    if [ -n "$id" ] && ! printf '%s\n' "$ids" | grep -qxF "$id"; then
      out="${out}- Stuck: $(_ap_label "$id") — ${reason}"$'\n'
    elif [ -z "$id" ]; then
      out="${out}- Stuck — ${reason}"$'\n'
    fi
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; else echo "- Nothing outstanding"; fi
}

# Config settings: key<TAB>default<TAB>min<TAB>max. The only source of the valid keys and ranges.
_ap_config_spec() {
  printf '%s\t%s\t%s\t%s\n' daily_cycle_cap 64 1 1000 daily_merge_cap 64 1 1000 \
    idle_retry_minutes 32 30 60 max_dop 3 3 16 reserved_slots 2 0 8
}

# The raw override for a key ("" when absent or not a positive integer).
_ap_config_raw() {
  local f v=""; f=$(ap-config-file)
  [ -f "$f" ] && v=$(jq -r --arg k "$1" '.[$k] // empty' "$f" 2>/dev/null || true)
  if [[ "$v" =~ ^[0-9]+$ ]] && { [ "$v" -gt 0 ] || [ "$1" = reserved_slots ]; }; then printf '%s' "$v"; fi
}

ap-config-show() {
  local json=0 f key def min max raw val src rows=""
  case "${1:-}" in --json) json=1 ;; "") ;; *) echo "config-show [--json]" >&2; return 2 ;; esac
  f=$(ap-config-file)
  while IFS=$'\t' read -r key def min max; do
    raw=$(_ap_config_raw "$key")
    case "$key" in max_dop) val=$(ap-max-dop) ;; reserved_slots) val=$(ap-reserved-slots) ;; *) val=$(ap-config "$key" "$def") ;; esac
    if [ -n "$raw" ] && [ "$raw" = "$val" ]; then src=override; else src=default; fi
    rows="${rows}${key}"$'\t'"${val}"$'\t'"${src}"$'\t'"${def}"$'\t'"${min}-${max}"$'\n'
  done < <(_ap_config_spec)
  if [ "$json" = 1 ]; then
    printf '%s' "$rows" | jq -Rn --arg file "$f" --argjson notices "$(ap-config-notices | jq -R . | jq -sc .)" '{file: $file, settings: ([inputs | split("\t") |
      {key: .[0], value: {value: (.[1] | tonumber), source: .[2], default: (.[3] | tonumber), range: .[4]}}] | from_entries), notices: $notices}'
    return 0
  fi
  printf '%-20s %6s  %-8s %s\n' setting value source "default (range)"
  while IFS=$'\t' read -r key val src def min; do
    [ -n "$key" ] || continue
    printf '%-20s %6s  %-8s %s (%s)\n' "$key" "$val" "$src" "$def" "$min"
  done <<< "$rows"
  if [ -f "$f" ]; then echo "config file: $f"; else echo "config file: $f (absent: all defaults)"; fi
  ap-config-notices
}

# Atomic config write: jq filter (args like _ap_update) over the file's object, temp file + mv, mode 600.
_ap_config_write() {
  local f tmp cur; f=$(ap-config-file); tmp="$f.tmp.$$"
  mkdir -p "$(dirname "$f")"
  cur='{}'
  if [ -f "$f" ]; then
    cur=$(cat "$f")
    printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || { echo "config: $f is not a JSON object; fix or move it first" >&2; return 2; }
  fi
  ( umask 077; printf '%s' "$cur" | jq "$@" > "$tmp" ) || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv "$tmp" "$f"
}

ap-config-set() {
  local key="${1:-}" val="${2:-}" k def min max found=""
  [ $# -eq 2 ] || { echo "config-set <key> <value>" >&2; return 2; }
  while IFS=$'\t' read -r k def min max; do
    [ "$k" = "$key" ] && { found=1; break; }
  done < <(_ap_config_spec)
  [ -n "$found" ] || { echo "config: unknown key '$key' (valid: $(_ap_config_spec | cut -f1 | paste -sd' ' -))" >&2; return 2; }
  [[ "$val" =~ ^(0|[1-9][0-9]{0,5})$ ]] \
    || { echo "config: $key must be a $([ "$min" = 0 ] && echo non-negative || echo positive) integer, got '$val'" >&2; return 2; }
  if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ]; then
    if [ "$key" = max_dop ]; then
      echo "config: max_dop must be between $min and $max, got $val (2 slots are always reserved for urgent tier 1/2 work, so at least 3)" >&2
    else
      echo "config: $key must be between $min and $max, got $val" >&2
    fi
    return 2
  fi
  # Cross-key rule: at least one routine slot (reserved_slots is at most max_dop minus 1).
  if [ "$key" = reserved_slots ] && [ "$val" -gt $(( $(ap-max-dop) - 1 )) ]; then
    echo "config: reserved_slots $val leaves no routine slot with max_dop $(ap-max-dop); at most $(( $(ap-max-dop) - 1 )) (raise max_dop first)" >&2; return 2
  fi
  if [ "$key" = max_dop ] && [ "$(_ap_config_raw reserved_slots)" -gt $(( val - 1 )) ] 2>/dev/null; then
    echo "config: max_dop $val is too low for the stored reserved_slots $(_ap_config_raw reserved_slots) (needs max_dop above it); lower reserved_slots first" >&2; return 2
  fi
  _ap_config_write --arg k "$key" --argjson v "$val" '.[$k] = $v' || return $?
  echo "set $key=$val ($(ap-config-file))"
}

ap-config-reset() {
  local key="${1:-}" f k found=""; f=$(ap-config-file)
  [ $# -le 1 ] || { echo "config-reset [<key>]" >&2; return 2; }
  if [ -n "$key" ]; then
    while IFS=$'\t' read -r k _; do [ "$k" = "$key" ] && found=1; done < <(_ap_config_spec)
    [ -n "$found" ] || { echo "config: unknown key '$key' (valid: $(_ap_config_spec | cut -f1 | paste -sd' ' -))" >&2; return 2; }
  fi
  [ -f "$f" ] || { echo "noop: no config file, nothing to reset"; return 0; }
  _ap_config_write --argjson ks "$(_ap_config_spec | cut -f1 | jq -R . | jq -sc --arg k "$key" 'if $k == "" then . else [$k] end')" \
    'delpaths($ks | map([.]))' || return $?
  if [ -n "$key" ]; then echo "reset $key"; else echo "reset all overrides"; fi
}

autopilot-state() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status) ap-status ;; report) ap-report ;; start) ap-start ;; pause) ap-pause ;; resume) ap-resume ;;
    off) ap-off ;; busy) ap-busy "$@" ;; cap) ap-cap ;; record) ap-record "$@" ;; stats) ap-stats "$@" ;; delay) ap-delay "$@" ;;
    remaining) ap-remaining ;; overdue) ap-overdue "$@" ;; eligible) ap-eligible "$@" ;; pickable) ap-pickable "$@" ;;
    slots) ap-slots "$@" ;; routine-free) ap-routine-free ;; guard) ap-guard ;; hold) ap-hold "$@" ;; wake) ap-wake "$@" ;; set-clone) ap-set-clone "$@" ;;
    top) ap-top "$@" ;; plan) ap-plan "$@" ;; prune) ap-prune "$@" ;; 
    hold-add) ap-hold-add "$@" ;; hold-report) ap-hold-report "$@" ;; holds) ap-holds "$@" ;; release) ap-release "$@" ;; holds-check) ap-holds-check "$@" ;;
    notify) ap-notify "$@" ;;
    classify) ap-classify "$@" ;; attention) ap-attention "$@" ;; clone-path) ap-clone-path "$@" ;;
    config-show) ap-config-show "$@" ;; config-set) ap-config-set "$@" ;; config-reset) ap-config-reset "$@" ;;
    done) ap-done ;; final-report) ap-final-report "$@" ;;
    *) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  autopilot-state "$@"
fi
