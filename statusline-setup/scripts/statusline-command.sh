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

# $1 repo_root -> "ap:[r]/[b]/[s] <elapsed>/<requested>hr <stuck>/<cycle>"
# when /autopilot's dev/.autopilot-state.json exists and status is "running"
# or "stopped", else nothing. [r] running normally, [b] running but backing
# off (last_outcome == "stuck"), [s] stopped — [s] lingers with no
# dismiss/expiry, same as the state file itself (autopilot/SKILL.md Phase 5
# never deletes it). Never fails the prompt: any missing/malformed field
# just degrades to printing nothing (same convention as every other sl-
# helper).
sl-autopilot-part() {
  local repo_root="$1" state_file line
  state_file="$repo_root/dev/.autopilot-state.json"
  [ -f "$state_file" ] || return 0

  # One jq call for all fields (not several separate ones) — avoids a TOCTOU
  # gap where /autopilot could rewrite the file between separate reads.
  line=$(jq -r '[.status, .started_at, .end_time, .stuck_count, .cycle_count, .last_outcome, .last_cycle_at] | map(. // "") | @tsv' \
    "$state_file" 2>/dev/null) || return 0

  local ap_status started_at end_time stuck_count cycle_count last_outcome last_cycle_at
  IFS=$'\t' read -r ap_status started_at end_time stuck_count cycle_count last_outcome last_cycle_at <<<"$line"
  [ "$ap_status" = "running" ] || [ "$ap_status" = "stopped" ] || return 0

  # stuck_count/cycle_count must be non-negative integers — a missing,
  # negative, or non-numeric value degrades to nothing rather than a
  # garbled segment (e.g. "ap:[r] 2/5hr /" or "ap:[r] 2/5hr abc/3").
  [[ "$stuck_count" =~ ^[0-9]+$ ]] || return 0
  [[ "$cycle_count" =~ ^[0-9]+$ ]] || return 0

  local started_epoch end_epoch now_epoch
  started_epoch=$(sl-iso-to-epoch "$started_at")
  end_epoch=$(sl-iso-to-epoch "$end_time")
  [ -n "$started_epoch" ] && [ -n "$end_epoch" ] || return 0
  [ "$end_epoch" -gt "$started_epoch" ] || return 0
  now_epoch=$(date +%s)
  [ "$started_epoch" -le "$now_epoch" ] || return 0

  local prefix elapsed_secs
  if [ "$ap_status" = "stopped" ]; then
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

  local requested_secs elapsed_hr requested_hr
  requested_secs=$(( end_epoch - started_epoch ))
  elapsed_hr=$(awk -v s="$elapsed_secs" 'BEGIN{printf "%.0f", s/3600}')
  requested_hr=$(awk -v s="$requested_secs" 'BEGIN{printf "%.0f", s/3600}')

  printf 'ap:%s %s/%shr %s/%s' "$prefix" "$elapsed_hr" "$requested_hr" "$stuck_count" "$cycle_count"
}

# $1 last-input state dir, $2 session_id -> "last: <cached text>", or
# nothing when no cache file exists yet for this session (degrade-to-empty,
# same convention as every other sl-* helper here).
sl-last-input-part() {
  local dir="$1" session_id="$2" file text
  [ -n "$session_id" ] || return 0
  file="$dir/$session_id"
  [ -r "$file" ] || return 0
  text="$(cat "$file" 2>/dev/null)"
  [ -n "$text" ] || return 0
  printf 'last: %s' "$text"
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

  sl-join "$ap_part" "$ctx_part" "$branch_part" "$task_part" "$last_input_part"
}

# Run only when executed directly (not when sourced), matching the
# quality-probe/scripts/probe.sh convention so BATS can source this file and
# unit-test the helper functions without invoking the stdin-reading main.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  statusline-command
fi
