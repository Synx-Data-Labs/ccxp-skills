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
#   busy on [<task-id>]|off     mark a dispatched cycle running (optionally which
#                               task it drives, T<yyyymmdd>-<6 digits>; an invalid
#                               id is ignored; the HUD shows "loop on T<id>") / finished
#   cap                         print ok | capped:<cycles|merges>  (rolls the day)
#   record <outcome> [merged] [task-id] [reason]
#                               outcome: progress|idle|stuck|waiting|capped;
#                               updates counters + next_wake_at, prints the
#                               notice kind to send (idle|resumed|stuck|waiting|
#                               capped) or "none"
#   delay <outcome>             seconds until the next wake
#   remaining                   seconds until next_wake_at (0 when due)
#   eligible <task-file>        exit 0 when the status line allows auto-driving
#   skip <task-id> [reason] [--kind blocked|decision|external|epic]
#                               needs-attention list (kind: what the HUD queue
#                               breakdown counts it as; `epic` is legacy, task size
#                               is never a reason to skip); prints "attention" when new
#   unskip <task-id>|--all      remove the id (or every id) from skip_ids and
#                               needs_attention; prints "unskipped <id>" (or
#                               "unskipped all") or "noop" when nothing was listed
#   notify <kind> <text>        Slack (--channel dev) when possible, else record
#                               in the state file; always exit 0
#   classify <file|->           parse a /drive sub-agent's final report (the
#                               MERGED:/STUCK:/NEEDS-ATTENTION:/WAITING: lines)
#                               -> "<outcome> <merged> <task-id|-> <reason>",
#                               outcome progress|waiting|stuck|idle, ready for
#                               `record`; exit 2 (and a stuck line) when no
#                               report line is recognized
#   attention <file|->          one "<task-id><TAB><reason>" line per
#                               NEEDS-ATTENTION entry of a report (for `skip`)
#   clone-path [repo-root]      deterministic dispatch-clone path for a repo
#   done                        "- Merged T<id> (<slug>)[ — PR #<n>]" per journal
#                               file added since started_at ("- No tasks merged
#                               this run" when none); needs a git repo
#   final-report [--stopped <why>]
#                               the Phase 5 bullet report (elapsed, Done,
#                               Needs your attention) from the state file
# Env (tests): AUTOPILOT_STATE_FILE, AUTOPILOT_CONFIG_FILE, AUTOPILOT_NOW,
#   AUTOPILOT_TODAY, AUTOPILOT_SLACK_SEND.

set -euo pipefail

_ap_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
_ap_dir() { dirname "${BASH_SOURCE[0]}"; }
ap-state-file() { printf '%s' "${AUTOPILOT_STATE_FILE:-$(_ap_root)/dev/.autopilot-state.json}"; }
ap-config-file() { printf '%s' "${AUTOPILOT_CONFIG_FILE:-$(_ap_root)/dev/.autopilot-config.json}"; }
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
_ap_update() {
  local f tmp; f=$(ap-state-file); tmp="$f.tmp.$$"
  jq "$@" "$f" > "$tmp" && mv "$tmp" "$f"
}

_ap_fresh() {
  local f; f=$(ap-state-file); mkdir -p "$(dirname "$f")"
  jq -n --arg now "$(ap-now)" --arg day "$(ap-today)" '{
    schema: 2, status: "on", started_at: $now, paused_at: null,
    cycle_count: 0, merged_count: 0, stuck_count: 0, waiting_count: 0,
    last_cycle_at: null, last_outcome: null, last_task: null, last_stuck_reason: null,
    dispatch_clone_path: null, idle_notified: false, stuck_notified: false,
    waiting_notified: false, capped_notified: false, skip_ids: [], needs_attention: [],
    day: $day, cycles_today: 0, merges_today: 0, notices: [],
    next_wake_at: null, busy_since: null, current_task: null}' > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# 0 when a cycle is marked busy and the mark is under 3 h old (else crashed/stale).
_ap_is_busy() {
  local f b be now; f=$(ap-state-file)
  b=$(jq -r '.busy_since // empty' "$f" 2>/dev/null || true)
  [ -n "$b" ] || return 1
  be=$(_ap_epoch "$b"); now=$(_ap_epoch "$(ap-now)")
  [ -n "$be" ] && [ -n "$now" ] && [ $(( now - be )) -lt 10800 ]
}

ap-remaining() {
  local f w we now; f=$(ap-state-file)
  w=$(jq -r '.next_wake_at // empty' "$f" 2>/dev/null || true)
  [ -n "$w" ] || { echo 0; return 0; }
  we=$(_ap_epoch "$w"); now=$(_ap_epoch "$(ap-now)")
  if [ -n "$we" ] && [ -n "$now" ] && [ "$we" -gt "$now" ]; then echo $(( we - now )); else echo 0; fi
}

# Shared by start (when on) and resume: dispatch only if due and not busy.
_ap_due() {
  if _ap_is_busy; then echo already-on; return 0; fi
  if [ "$(ap-remaining)" -gt 30 ]; then echo already-on; else echo dispatch; fi  # 30 s tolerance: a wake may fire slightly early
}

ap-start() {
  case "$(ap-status)" in
    on) _ap_due ;;
    paused) echo paused ;;
    off)
      local busy="" ctask=""
      if [ -f "$(ap-state-file)" ] && _ap_is_busy; then
        busy=$(jq -r '.busy_since' "$(ap-state-file)"); ctask=$(jq -r '.current_task // empty' "$(ap-state-file)")
      fi
      _ap_fresh
      if [ -n "$busy" ]; then _ap_update --arg b "$busy" --arg t "$ctask" '.busy_since = $b | .current_task = (if $t == "" then null else $t end)'; echo busy; else echo started; fi ;;
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
  if _ap_is_busy; then echo busy; else echo dispatch; fi
}

# Prints the dispatch clone path for the caller to remove, and clears the state's copy.
ap-off() {
  local f clone=""; f=$(ap-state-file)
  [ "$(ap-status)" = off ] && { echo noop; return 0; }
  clone=$(jq -r '.dispatch_clone_path // empty' "$f" 2>/dev/null || true)
  _ap_update '.status = "off" | .paused_at = null | .dispatch_clone_path = null | .next_wake_at = null | .skip_ids = []'
  printf 'off %s\n' "$clone"
}

ap-busy() {
  [ -f "$(ap-state-file)" ] || return 0
  case "${1:-}" in
    on)
      # An id that is not a task id is ignored (the cycle is still marked busy), never an error.
      local t="${2:-}"; [[ "$t" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || t=""
      [ "$(ap-status)" = off ] || _ap_update --arg now "$(ap-now)" --arg t "$t" '.busy_since = $now | .current_task = (if $t == "" then null else $t end)' ;;
    off) _ap_update '.busy_since = null | .current_task = null' ;;
    *) echo "busy on [<task-id>]|off" >&2; return 2 ;;
  esac
}

_ap_roll_day() {
  _ap_update --arg d "$(ap-today)" 'if .day != $d then .day = $d | .cycles_today = 0 | .merges_today = 0 | .capped_notified = false | .skip_ids = [] else . end'
}

ap-cap() {
  [ "$(ap-status)" = on ] || { echo ok; return 0; }
  _ap_roll_day
  local f cc mc; f=$(ap-state-file)
  cc=$(jq -r '.cycles_today // 0' "$f"); mc=$(jq -r '.merges_today // 0' "$f")
  if [ "$cc" -ge "$(ap-config daily_cycle_cap 24)" ]; then echo capped:cycles
  elif [ "$mc" -ge "$(ap-config daily_merge_cap 12)" ]; then echo capped:merges
  else echo ok; fi
}

ap-delay() {
  local outcome="${1:?outcome}" f n d key; f=$(ap-state-file)
  case "$outcome" in
    progress) echo 60 ;;
    idle) echo $(( $(ap-config idle_retry_minutes 45) * 60 )) ;;
    capped) echo 3600 ;;
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

# record <outcome> [merged] [task-id] [reason] -> notice kind (or none)
ap-record() {
  local outcome="${1:?outcome}" merged="${2:-0}" task="${3:-}" reason="${4:-}" f notice=none
  case "$outcome" in progress|idle|stuck|waiting|capped) ;; *) echo "bad outcome: $outcome" >&2; return 1 ;; esac
  [[ "$merged" =~ ^[0-9]+$ ]] || merged=0
  [ "$(ap-status)" = on ] || { echo none; return 0; }
  f=$(ap-state-file)
  _ap_roll_day
  local was_idle was_stuck was_wait was_capped cycle=1 d nw
  was_idle=$(jq -r '.idle_notified' "$f"); was_stuck=$(jq -r '.stuck_notified' "$f")
  was_wait=$(jq -r '.waiting_notified' "$f"); was_capped=$(jq -r '.capped_notified' "$f")
  [ "$outcome" = capped ] && cycle=0   # a capped tick dispatched nothing
  _ap_update --arg o "$outcome" --arg now "$(ap-now)" --arg t "$task" --arg r "$reason" --argjson m "$merged" --argjson c "$cycle" '
    .cycle_count += $c | .cycles_today += $c | .merged_count += $m | .merges_today += $m
    | .last_cycle_at = (if $c == 1 then $now else .last_cycle_at end) | .last_outcome = $o
    | .last_task = (if $t == "" then null else $t end)
    | .last_stuck_reason = (if $o == "stuck" and $r != "" then $r else null end)
    | .stuck_count = (if $o == "stuck" then .stuck_count + 1 elif $o == "waiting" then .stuck_count else 0 end)
    | .waiting_count = (if $o == "waiting" then .waiting_count + 1 else 0 end)
    | .busy_since = null | .current_task = null'
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
  esac
  d=$(ap-delay "$outcome"); nw=$(( $(_ap_epoch "$(ap-now)") + d ))
  _ap_update --arg w "$(_ap_iso "$nw")" '.next_wake_at = $w'
  echo "$notice"
}

# Status-line markers that need a human (or are blocked): not auto-driven.
ap-eligible() {
  local file="${1:?task file}" line
  [ -f "$file" ] || return 1
  line=$(awk 'NR==1&&$0!="---"{exit} /^---$/{n++; if(n==2)exit} n==1&&/^status:/{print; exit}' "$file")
  if printf '%s' "$line" | grep -qiE 'SUPERVISED|BLOCKED|needs a human|needs manual|sign-off'; then return 1; fi
  return 0
}

ap-skip() {
  local id="" reason="" kind="" f; f=$(ap-state-file)
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; [ $# -ge 2 ] && shift; shift || true ;;
      --kind=*) kind="${1#--kind=}"; shift ;;
      *) if [ -z "$id" ]; then id="$1"; elif [ -z "$reason" ]; then reason="$1"; fi; shift ;;
    esac
  done
  [ -n "$id" ] || { echo "skip <task-id> [reason] [--kind blocked|decision|external|epic]" >&2; return 2; }
  case "$kind" in ''|blocked|decision|external|epic) ;; *) echo "bad kind: $kind (blocked|decision|external|epic)" >&2; return 2 ;; esac
  [ -n "$reason" ] || reason="needs attention"
  [ "$(ap-status)" = off ] && return 0
  if jq -e --arg id "$id" '.skip_ids // [] | index($id)' "$f" >/dev/null 2>&1; then
    # Already skipped: stay quiet, but a kind given now is stored (the HUD reads it).
    [ -z "$kind" ] || _ap_update --arg id "$id" --arg k "$kind" '.needs_attention = ((.needs_attention // []) | map(if .id == $id then . + {kind: $k} else . end))'
    echo none; return 0
  fi
  _ap_update --arg id "$id" --arg r "$reason" --arg k "$kind" '
    .skip_ids = ((.skip_ids // []) + [$id])
    | .needs_attention = ((.needs_attention // []) | map(select(.id != $id)) + [{id: $id, reason: $r} + (if $k == "" then {} else {kind: $k} end)])'
  echo attention
}

ap-unskip() {
  local id="${1:-}" f; f=$(ap-state-file)
  [ -n "$id" ] || { echo "unskip <task-id>|--all" >&2; return 2; }
  [ -f "$f" ] || { echo noop; return 0; }
  if [ "$id" = --all ]; then
    if jq -e '((.skip_ids // []) | length) + ((.needs_attention // []) | length) > 0' "$f" >/dev/null 2>&1; then
      _ap_update '.skip_ids = [] | .needs_attention = []'
      echo "unskipped all"
    else echo noop; fi
    return 0
  fi
  if jq -e --arg id "$id" '((.skip_ids // []) | index($id)) != null or ((.needs_attention // []) | any(.id == $id))' "$f" >/dev/null 2>&1; then
    _ap_update --arg id "$id" '
      .skip_ids = ((.skip_ids // []) | map(select(. != $id)))
      | .needs_attention = ((.needs_attention // []) | map(select(.id != $id)))'
    echo "unskipped $id"
  else echo noop; fi
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
         (.needs_attention[]? | "needs attention: \(.id) — \(.reason)"),
         (.notices[-3:][]? | "notice [\(.via)] \(.kind): \(.text)")' "$f"
  if [ "$st" = on ] && ! _ap_is_busy; then
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

_ap_strip_runs() { sed -E 's/[[:space:]]*;[[:space:]]*runs:.*$//; s/[[:space:]]+$//'; }

ap-classify() {
  local src="${1:-}" line rest id reason lines
  [ -n "$src" ] || { echo "classify <file|->" >&2; return 2; }
  lines=$(_ap_report_lines "$src") || { echo "classify: no such file: $src" >&2; return 2; }
  local merged=0 merged_id="" stuck=0 stuck_id="" stuck_reason="" waiting=0 wait_reason="" attn=0
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
      NEEDS-ATTENTION:*)
        rest=$(printf '%s' "${line#NEEDS-ATTENTION:}" | sed -E 's/^[[:space:]]+//')
        if [[ "$rest" =~ $re_id ]]; then attn=$(( attn + 1 )); fi ;;
    esac
  done <<EOF_LINES
$lines
EOF_LINES
  # Precedence follows autopilot/SKILL.md Phase 4: progress (merged, nothing
  # stuck), waiting (nothing merged), stuck, then a lone NEEDS-ATTENTION = idle.
  if [ "$merged" -gt 0 ] && [ "$stuck" = 0 ]; then
    printf 'progress %s %s -\n' "$merged" "${merged_id:--}"
  elif [ "$merged" = 0 ] && [ "$waiting" = 1 ]; then
    printf 'waiting 0 - %s\n' "$wait_reason"
  elif [ "$stuck" = 1 ]; then
    [ -n "$stuck_id" ] || stuck_id="${merged_id:--}"
    printf 'stuck %s %s %s\n' "$merged" "$stuck_id" "${stuck_reason:-stuck}"
  elif [ "$attn" -gt 0 ]; then
    printf 'idle 0 - only needs-attention tasks reported\n'
  else
    printf 'stuck 0 - dispatch failed or report unparseable\n'
    return 2
  fi
}

ap-attention() {
  local src="${1:-}" line rest
  [ -n "$src" ] || { echo "attention <file|->" >&2; return 2; }
  local lines; lines=$(_ap_report_lines "$src") || { echo "attention: no such file: $src" >&2; return 2; }
  local re='^(T[0-9]+(-[0-9]+)?)[[:space:]]*(—|-)[[:space:]]*(.*)$' re_id='^(T[0-9]+(-[0-9]+)?)'
  while IFS= read -r line; do
    case "$line" in NEEDS-ATTENTION:*) ;; *) continue ;; esac
    rest=$(printf '%s' "${line#NEEDS-ATTENTION:}" | sed -E 's/^[[:space:]]+//' | _ap_strip_runs)
    if [[ "$rest" =~ $re ]]; then printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]:-needs attention}"
    elif [[ "$rest" =~ $re_id ]]; then printf '%s\tneeds attention\n' "${BASH_REMATCH[1]}"; fi
  done <<EOF_LINES
$lines
EOF_LINES
}

# --- dispatch clone path ------------------------------------------------------

_ap_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum
  else openssl dgst -sha256 | sed 's/^.* //'; fi
}

ap-clone-path() {
  local root="${1:-}" hash
  [ -n "$root" ] || root=$(_ap_root)
  hash=$(printf '%s' "$root" | _ap_sha256 | cut -c1-8)
  printf '/tmp/autopilot-clone-%s-%s\n' "$(basename "$root")" "$hash"
}

# --- final report -------------------------------------------------------------

# "T<id> (<slug>)" from the task's file name under dev/{TODO,PARKING,JOURNAL}; bare id when not found.
_ap_label() {
  local id="$1" root f b slug; root=$(_ap_root)
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
  started=$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)
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
  local out="" id reason ids
  while IFS=$'\t' read -r id reason; do
    [ -n "$id" ] || continue
    out="${out}- $(_ap_label "$id") — ${reason}"$'\n'
  done < <(jq -r '.needs_attention[]? | [.id, .reason] | @tsv' "$f")
  ids=$(jq -r '.needs_attention[]?.id' "$f")
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

autopilot-state() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status) ap-status ;; report) ap-report ;; start) ap-start ;; pause) ap-pause ;; resume) ap-resume ;;
    off) ap-off ;; busy) ap-busy "$@" ;; cap) ap-cap ;; record) ap-record "$@" ;; delay) ap-delay "$@" ;;
    remaining) ap-remaining ;; eligible) ap-eligible "$@" ;; skip) ap-skip "$@" ;; unskip) ap-unskip "$@" ;; notify) ap-notify "$@" ;;
    classify) ap-classify "$@" ;; attention) ap-attention "$@" ;; clone-path) ap-clone-path "$@" ;;
    done) ap-done ;; final-report) ap-final-report "$@" ;;
    *) sed -n '2,50p' "${BASH_SOURCE[0]}" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  autopilot-state "$@"
fi
