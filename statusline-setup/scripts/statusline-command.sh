#!/usr/bin/env bash
# Claude Code statusLine command — surfaces the task claimed by THIS clone.
#
# Repo root, TODO dir, and clone-id are all derived from the SESSION cwd, so the
# same global (~/.claude/settings.json) statusLine works across every
# clone/session regardless of which folder Claude was launched in.
#
# The clone-id is NOT reimplemented here. It used to be (`$(hostname):$root`),
# coupled to task_claim.sh by nothing but a comment, which meant a format change
# there left this silently matching nothing — and `sl-claimed-task-label` prints
# nothing on a miss, so a stale copy renders exactly like "no task claimed"
# (T20260911-698434). It now sources the single definition instead.
#
# _session/_lib.sh is deliberately NOT sourced: it runs `set -uo pipefail` and
# loads ~/.claude/.env at source time, and this runs on every prompt render.
# claimant-id.sh is side-effect-free for exactly this caller.

# Last-user-input cache dir, written by last-input-hook.sh's UserPromptSubmit
# hook (T20260924-366770). Mirrors claimant-id.sh's CLAIMANT_STATE_DIR
# override convention so BATS can isolate reads under $BATS_TEST_TMPDIR.
LAST_INPUT_STATE_DIR="${LAST_INPUT_STATE_DIR:-${HOME}/.claude/state/last-input}"

# ccxp-hud heartbeat dir (T20261022-345549): the hud mod writes "on" to
# <dir>/<session_id> every poll while it draws the band for that session, so
# this line can shrink to ctx | branch instead of showing everything twice.
# Honours CLAUDE_CONFIG_DIR like the other state roots; BATS overrides it.
HUD_ACTIVE_DIR="${HUD_ACTIVE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/state/hud-active}"
HUD_ACTIVE_MAX_AGE="${HUD_ACTIVE_MAX_AGE:-120}"

_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _sl_cand in "$_SL_DIR/../../_session/claimant-id.sh" \
                "$HOME/.claude/skills/_session/claimant-id.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_sl_cand" ] && { . "$_sl_cand"; break; }
done
unset _sl_cand

# Resolve the repo root from a session cwd (fall back to cwd if not a git repo).
sl-repo-root() {
  local cwd="$1"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd"
}

sl-clone-id() {
  # Must equal `_tc_claimant_id` for this clone or the statusline silently shows
  # no task; tests/statusline_setup.bats pins that equality directly.
  local repo_root="$1"
  if declare -F claimant_id >/dev/null 2>&1; then
    claimant_id "$repo_root"
  else
    # Lib not found (unusual install layout). Emit nothing rather than a
    # wrong-format guess: a guess would match no task anyway, and the statusline
    # must never fail the prompt.
    printf ''
  fi
}

# Current git branch for repo_root, or empty (detached HEAD / not a repo).
# symbolic-ref (not `branch --show-current`) so this also works pre-first-commit,
# when HEAD is an unborn symbolic ref with no commit behind it yet.
sl-branch-name() {
  local repo_root="$1"
  git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true
}

# Find the task file whose frontmatter `claimed_by:` matches this clone-id and
# print "<task-id>: <title>" (or just "<task-id>" if no title), else nothing.
sl-claimed-task-label() {
  local todo_dir="$1" clone_id="$2"
  [ -d "$todo_dir" ] || return 0

  # Escape regex-special chars in the id (realistically just '.') and anchor
  # the tail so a longer sibling path can't match as a prefix.
  local esc_id="${clone_id//\\/\\\\}"
  esc_id="${esc_id//./\\.}"
  local claimed_file
  claimed_file=$(grep -rlE "^claimed_by:[[:space:]]+${esc_id}([[:space:]]|$)" "$todo_dir" 2>/dev/null | head -1)
  [ -n "$claimed_file" ] || return 0

  # Task ID from the filename (e.g. T20260427-242654).
  local task_id task_title
  task_id=$(basename "$claimed_file" .md | grep -oE 'T[0-9]+-[0-9]+')
  # Title from the first "# T<id>: Title" / "# T<id> Title" heading — strip the
  # leading "# T<id>" + optional ": "/" " so we don't double the ID below.
  task_title=$(grep -m1 '^# T' "$claimed_file" 2>/dev/null | sed -E 's/^# T[0-9]+-[0-9]+:? +//; s/^# //')

  if [ -n "$task_id" ] && [ -n "$task_title" ]; then
    printf '%s: %s' "$task_id" "$task_title"
  elif [ -n "$task_id" ]; then
    printf '%s' "$task_id"
  fi
}

# $1 ISO-8601 UTC -> epoch seconds, or empty. GNU date then BSD date — same
# two-line fallback shape as ccxp/scripts/epic-status.sh's _epic_iso_to_epoch.
sl-iso-to-epoch() {
  local iso="$1" e
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  printf ''
}

# $1 repo_root -> one record (fields joined by the ASCII unit separator, 0x1f,
# so an empty field survives `read`):
#   <status> <prefix> <elapsed_hr> <requested_hr> <stuck> <cycle> <last_outcome>
#   <last_task_id> <stuck_reason> <stop_reason> <merged_count>
# when /autopilot's dev/.autopilot-state.json exists and status is "running",
# "paused" or "stopped", else nothing. prefix: [r] running normally, [p] paused
# (clock frozen at paused_at), [b] running but
# backing off (last_outcome == "stuck"), [s] stopped — [s] lingers with no
# dismiss/expiry, same as the state file itself (autopilot/SKILL.md Phase 5
# never deletes it). Never fails the prompt: any missing/malformed field
# just degrades to printing nothing (same convention as every other sl-
# helper). The ONE place the state file is parsed: sl-autopilot-part (text
# line) and hud-data.sh (--json) both render from this record.
sl-autopilot-fields() {
  local repo_root="$1" state_file line
  state_file="$repo_root/dev/.autopilot-state.json"
  [ -f "$state_file" ] || return 0

  # One jq call for all fields (not several separate ones) — avoids a TOCTOU
  # gap where /autopilot could rewrite the file between separate reads.
  line=$(jq -r '[.status, .started_at, .end_time, .stuck_count, .cycle_count, .last_outcome, .last_cycle_at, .paused_at, (.last_task | if type == "object" then .id else . end), .last_stuck_reason, .stop_reason, .merged_count] | map(. // "" | tostring) | join("\u001f")' \
    "$state_file" 2>/dev/null) || return 0

  local ap_status started_at end_time stuck_count cycle_count last_outcome last_cycle_at paused_at last_task stuck_reason stop_reason merged_count
  IFS=$'\x1f' read -r ap_status started_at end_time stuck_count cycle_count last_outcome last_cycle_at paused_at last_task stuck_reason stop_reason merged_count <<<"$line"
  case "$ap_status" in running|paused|stopped) ;; *) return 0 ;; esac

  # stuck_count/cycle_count must be non-negative integers — a missing,
  # negative, or non-numeric value degrades to nothing rather than a
  # garbled segment (e.g. "ap:[r] 2/5hr /" or "ap:[r] 2/5hr abc/3").
  [[ "$stuck_count" =~ ^[0-9]+$ ]] || return 0
  [[ "$cycle_count" =~ ^[0-9]+$ ]] || return 0
  # merged_count is newer than the state file format: missing/invalid means 0.
  [[ "$merged_count" =~ ^[0-9]+$ ]] || merged_count=0

  local started_epoch end_epoch now_epoch
  started_epoch=$(sl-iso-to-epoch "$started_at")
  end_epoch=$(sl-iso-to-epoch "$end_time")
  [ -n "$started_epoch" ] && [ -n "$end_epoch" ] || return 0
  [ "$end_epoch" -gt "$started_epoch" ] || return 0
  now_epoch=$(date +%s)
  [ "$started_epoch" -le "$now_epoch" ] || return 0

  local prefix elapsed_secs
  if [ "$ap_status" = "paused" ]; then
    # Pausing stops the clock: elapsed is frozen at paused_at (autopilot/SKILL.md
    # Phase 0), not live. A missing/unparseable paused_at degrades to nothing.
    local paused_epoch
    paused_epoch=$(sl-iso-to-epoch "$paused_at")
    [ -n "$paused_epoch" ] && [ "$paused_epoch" -ge "$started_epoch" ] || return 0
    prefix='[p]'
    elapsed_secs=$(( paused_epoch - started_epoch ))
  elif [ "$ap_status" = "stopped" ]; then
    prefix='[s]'
    # Elapsed for a stopped run is last_cycle_at - started_at (or 0 if no
    # cycle ever ran), not now - started_at — the run is long over, so
    # "now" would give an ever-growing, meaningless elapsed. Mirrors
    # autopilot/SKILL.md Phase 0's own status-report elapsed rule.
    if [ -n "$last_cycle_at" ]; then
      local last_cycle_epoch
      last_cycle_epoch=$(sl-iso-to-epoch "$last_cycle_at")
      if [ -n "$last_cycle_epoch" ] && [ "$last_cycle_epoch" -ge "$started_epoch" ]; then
        elapsed_secs=$(( last_cycle_epoch - started_epoch ))
      else
        elapsed_secs=0
      fi
    else
      elapsed_secs=0
    fi
  else
    if [ "$last_outcome" = "stuck" ]; then prefix='[b]'; else prefix='[r]'; fi
    elapsed_secs=$(( now_epoch - started_epoch ))
  fi

  local requested_secs elapsed_hr requested_hr sep=$'\x1f'
  requested_secs=$(( end_epoch - started_epoch ))
  elapsed_hr=$(awk -v s="$elapsed_secs" 'BEGIN{printf "%.0f", s/3600}')
  requested_hr=$(awk -v s="$requested_secs" 'BEGIN{printf "%.0f", s/3600}')

  printf '%s' "${ap_status}${sep}${prefix}${sep}${elapsed_hr}${sep}${requested_hr}${sep}${stuck_count}${sep}${cycle_count}${sep}${last_outcome}${sep}${last_task}${sep}${stuck_reason}${sep}${stop_reason}${sep}${merged_count}"
}

# $1 repo_root -> "ap:[r]/[b]/[s] <elapsed>/<requested>hr [⚠<stuck>] loops <cycle> ✓<merged>"
# (the text statusline segment; ⚠ only when stuck > 0), or nothing; rendered
# from sl-autopilot-fields.
sl-autopilot-part() {
  local rec ap_status prefix elapsed_hr requested_hr stuck cycle last_outcome last_task stuck_reason stop_reason merged
  rec=$(sl-autopilot-fields "$1")
  [ -n "$rec" ] || return 0
  IFS=$'\x1f' read -r ap_status prefix elapsed_hr requested_hr stuck cycle last_outcome last_task stuck_reason stop_reason merged <<<"$rec"
  # The text statusline has never shown a paused run; keep it that way.
  [ "$ap_status" = "paused" ] && return 0
  local warn=""
  [ "$stuck" -gt 0 ] && warn=" ⚠${stuck}"
  printf 'ap:%s %s/%shr%s loops %s ✓%s' "$prefix" "$elapsed_hr" "$requested_hr" "$warn" "$cycle" "${merged:-0}"
}

# Job ledger (written by ledger.sh). Same default path convention as the other
# state files: CLAUDE_CONFIG_DIR, else ~/.claude. CCXP_LEDGER_FILE overrides.
sl-ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/ccxp-ledger.json}"
}

# -> one normalized compact JSON object, or nothing when the ledger is
# missing/unreadable/not an object (callers hide the section or show a dash).
sl-ledger-json() {
  local f; f=$(sl-ledger-file)
  [ -f "$f" ] || return 0
  jq -c 'select(type == "object") | {
      updated_at: (.updated_at | strings // ""),
      next_job: (.next_job | numbers // 0),
      lifetime_jobs: (.lifetime_jobs | numbers // 0),
      parked: (.parked | numbers // 0),
      parked_ids: [(.parked_ids // [])[] | strings],
      running: [(.running // [])[] | select(type == "object")
                | {job: (.job | numbers // 0), title: (.title | strings // "")}]}' "$f" 2>/dev/null || true
}

# -> "jobs run <R> · total <L> · parked <P>", or nothing without a ledger.
sl-ledger-part() {
  local j; j=$(sl-ledger-json)
  [ -n "$j" ] || return 0
  jq -r '"jobs run \(.running | length) · total \(.lifetime_jobs) · parked \(.parked)"' <<<"$j" 2>/dev/null || true
}

# $1 last-input state dir, $2 session_id -> "last: <cached text>", or
# nothing when no cache file exists yet for this session (degrade-to-empty,
# same convention as every other sl-* helper here).
sl-last-input-part() {
  local dir="$1" session_id="$2" file text
  [ -n "$session_id" ] || return 0
  # Reject anything that isn't a safe bare filename (path separator, or
  # exactly "." / "..") — mirrors last-input-hook.sh's li-safe-session-id so
  # a crafted session_id can't read an arbitrary file outside $dir.
  case "$session_id" in
    */*|.|..) return 0 ;;
  esac
  file="$dir/$session_id"
  [ -r "$file" ] || return 0
  text="$(cat "$file" 2>/dev/null)"
  [ -n "$text" ] || return 0
  printf 'last: %s' "$text"
}

# $1 heartbeat dir, $2 session_id -> exit 0 when the hud mod is actively drawing
# its band for this session: the file holds "on" and was touched within
# HUD_ACTIVE_MAX_AGE seconds. Anything else (no file, "off", stale, unsafe id)
# is "not active", so the classic full line prints.
sl-hud-active() {
  local dir="$1" session_id="$2" file mtime now
  [ -n "$session_id" ] || return 1
  case "$session_id" in
    */*|.|..) return 1 ;;
  esac
  file="$dir/$session_id"
  [ -r "$file" ] || return 1
  [ "$(head -n1 "$file" 2>/dev/null)" = "on" ] || return 1
  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ $(( now - mtime )) -le "$HUD_ACTIVE_MAX_AGE" ]
}

# Join non-empty parts with " | " (array-expansion IFS only uses its first
# char, so build the separator explicitly).
sl-join() {
  local out="" p
  for p in "$@"; do
    [ -z "$p" ] && continue
    if [ -z "$out" ]; then out="$p"; else out="$out | $p"; fi
  done
  printf '%s' "$out"
}

statusline-command() {
  local input cwd remaining session_id
  input=$(cat)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // ""')
  remaining=$(printf '%s' "$input" | jq -r '.context_window.remaining_percentage // 100')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -n "$cwd" ] || cwd="$PWD"

  local repo_root clone_id todo_dir task_label
  repo_root=$(sl-repo-root "$cwd")
  clone_id=$(sl-clone-id "$repo_root")
  todo_dir="$repo_root/dev/TODO"
  task_label=$(sl-claimed-task-label "$todo_dir" "$clone_id")

  local ap_part="" ctx_part="" branch_part="" task_part branch_name last_input_part=""
  ap_part=$(sl-autopilot-part "$repo_root")
  if [ -n "$remaining" ]; then
    ctx_part="ctx: $(printf '%.0f' "$remaining")% left"
  fi
  branch_name=$(sl-branch-name "$repo_root")
  if [ -n "$branch_name" ]; then
    branch_part="branch: $branch_name"
  fi
  if [ -n "$task_label" ]; then
    task_part="TASK: $task_label"
  else
    task_part="no claimed task"
  fi
  last_input_part=$(sl-last-input-part "$LAST_INPUT_STATE_DIR" "$session_id")
  local jobs_part; jobs_part=$(sl-ledger-part)

  # The hud band already shows autopilot, task and last input: keep only the
  # always-useful ctx | branch while it is live.
  if sl-hud-active "$HUD_ACTIVE_DIR" "$session_id"; then
    sl-join "$ctx_part" "$branch_part"
    return 0
  fi

  sl-join "$ap_part" "$ctx_part" "$branch_part" "$task_part" "$jobs_part" "$last_input_part"
}

# Run only when executed directly (not when sourced), matching the
# quality-probe/scripts/probe.sh convention so BATS can source this file and
# unit-test the helper functions without invoking the stdin-reading main.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  statusline-command
fi
