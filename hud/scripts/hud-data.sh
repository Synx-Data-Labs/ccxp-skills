#!/usr/bin/env bash
# JSON data helper for the ccxp-hud mod (T20261022-345549).
#
# Reads a statusLine-shaped JSON object on stdin ({cwd, session_id, ...}) and
# prints ONE JSON object built from the SAME sl-* functions (hud-lib.sh)
# so there is a single source of truth and the claimant secret never
# leaves bash (the mod only ever sees task id/title, never the claimed_by value):
#
#   {"task_id","task_title","branch","worktree",
#    "autopilot": null | {"status","prefix","elapsed_hr","requested_hr",
#                         "stuck","cycle","last_outcome","last_task",
#                         "stuck_reason","stop_reason","merged"},
#    "ledger": null | {"running":[{"job","title"}],"lifetime_jobs","parked",
#                      "parked_ids","next_job","updated_at"},   # ledger.sh file
#    "last_input_at": 0}        # epoch secs of this session's last prompt (0 = unknown)
#
# Never exits non-zero: any failure prints "{}" so the mod keeps its last good
# snapshot. No network, no writes.

_HD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-lib.sh
. "$_HD_DIR/hud-lib.sh"

hud-data() {
  local input cwd session_id
  input=$(cat)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null) || cwd=""
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
  [ -n "$cwd" ] || cwd="$PWD"

  local repo_root clone_id label task_id="" task_title="" branch rec
  repo_root=$(sl-repo-root "$cwd")
  clone_id=$(sl-clone-id "$repo_root")
  label=$(sl-claimed-task-label "$repo_root/dev/TODO" "$clone_id")
  if [ -n "$label" ]; then
    task_id="${label%%:*}"
    [ "$label" = "$task_id" ] || task_title="${label#*: }"
  fi
  branch=$(sl-branch-name "$repo_root")
  # Linked worktree name ("" in the main checkout): git-dir differs from the
  # shared common dir only inside `git worktree add` checkouts.
  local worktree="" gd cd_
  gd=$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  cd_=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cd_=""
  if [ -n "$gd" ] && [ -n "$cd_" ] && [ "$gd" != "$cd_" ]; then worktree=$(basename "$repo_root"); fi
  rec=$(sl-autopilot-fields "$repo_root")

  local ledger; ledger=$(sl-ledger-json)
  [ -n "$ledger" ] || ledger="null"

  local last_input_at
  last_input_at=$(sl-last-input-epoch "$LAST_INPUT_STATE_DIR" "$session_id")
  [[ "$last_input_at" =~ ^[0-9]+$ ]] || last_input_at=0

  jq -n -c \
    --arg task_id "$task_id" --arg task_title "$task_title" \
    --arg branch "$branch" --arg worktree "$worktree" --arg rec "$rec" --argjson ledger "$ledger" --argjson last_input_at "$last_input_at" '
    ($rec | split("\u001f")) as $f
    | {task_id: $task_id, task_title: $task_title, branch: $branch, worktree: $worktree,
       autopilot: (if $rec == "" then null else {
         status: $f[0], prefix: $f[1],
         elapsed_hr: ($f[2] | tonumber), requested_hr: ($f[3] | tonumber),
         stuck: ($f[4] | tonumber), cycle: ($f[5] | tonumber),
         last_outcome: $f[6], last_task: $f[7],
         stuck_reason: $f[8], stop_reason: $f[9], merged: (($f[10] // "0") | tonumber? // 0)} end),
       ledger: $ledger,
       last_input_at: $last_input_at}'
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _hd_out=$(hud-data "$@" 2>/dev/null) || _hd_out=""
  # Never fail the mod's call: empty/failed output becomes an empty object.
  if [ -n "$_hd_out" ]; then printf '%s\n' "$_hd_out"; else printf '{}\n'; fi
  exit 0
fi
