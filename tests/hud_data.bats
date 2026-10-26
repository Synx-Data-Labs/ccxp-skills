#!/usr/bin/env bats
# Tests for statusline-setup/scripts/hud-data.sh (the ccxp-hud mod's JSON data
# helper, T20261022-345549) and the heartbeat-driven minimal statusline in
# statusline-command.sh. Fixture repos only; never the developer's real state.

load test_helper
HUD="$REPO_ROOT/statusline-setup/scripts/hud-data.sh"
SCRIPT="$REPO_ROOT/statusline-setup/scripts/statusline-command.sh"

setup() {
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_ACTIVE_DIR="$BATS_TEST_TMPDIR/hud-active"
}

# Resolve symlinks (macOS /var -> /private/var) the way the helper does, via
# git's toplevel, or the id would not match the helper's.
_clone_id() { bash -c "source '$SCRIPT'; sl-clone-id \"\$(git -C '$1' rev-parse --show-toplevel)\""; }

_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/dev/TODO"
  git -C "$dir" init -q -b main
  printf '%s' "$dir"
}

# $1 repo, $2 json state body (written verbatim)
_state() { printf '%s' "$2" > "$1/dev/.autopilot-state.json"; }

_iso_ago() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
_iso_ahead() { date -u -v+"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }

_hud() { # $1 repo, rest = helper args
  local repo="$1"; shift
  printf '{"cwd":"%s","session_id":"sess1"}' "$repo" | bash "$HUD" "$@"
}

@test "hud-data.sh is executable and sourceable without running main" {
  [ -x "$HUD" ]
  run bash -c "source '$HUD'; type hud-data >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "--json: no task, no autopilot, branch from the repo" {
  local repo; repo=$(_make_repo r-plain)
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .task_id <<<"$output")" = "" ]
  [ "$(jq -r .branch <<<"$output")" = "main" ]
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
}

@test "--json: claimed task id and title, never the claimed_by value" {
  local repo cid; repo=$(_make_repo r-claimed); cid=$(_clone_id "$repo")
  cat > "$repo/dev/TODO/T20260427-242654-x.md" <<EOT
---
claimed_by: ${cid}
---
# T20260427-242654: Fix the thing
EOT
  run _hud "$repo" --json
  [ "$(jq -r .task_id <<<"$output")" = "T20260427-242654" ]
  [ "$(jq -r .task_title <<<"$output")" = "Fix the thing" ]
  [[ "$output" != *"$cid"* ]]
}

@test "--json: a task claimed by another clone is not shown" {
  local repo; repo=$(_make_repo r-other)
  printf -- '---\nclaimed_by: otherhost:/other\n---\n# T20260427-242654: Not mine\n' > "$repo/dev/TODO/T20260427-242654-x.md"
  run _hud "$repo" --json
  [ "$(jq -r .task_id <<<"$output")" = "" ]
}

@test "--json: autopilot running normally" {
  local repo; repo=$(_make_repo r-run)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 90)\",\"end_time\":\"$(_iso_ahead 210)\",\"stuck_count\":3,\"cycle_count\":10,\"last_task\":{\"id\":\"T1-2\",\"slug\":\"s\"}}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.status <<<"$output")" = "running" ]
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[r]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "2" ]
  [ "$(jq -r .autopilot.requested_hr <<<"$output")" = "5" ]
  [ "$(jq -r .autopilot.stuck <<<"$output")" = "3" ]
  [ "$(jq -r .autopilot.cycle <<<"$output")" = "10" ]
  [ "$(jq -r .autopilot.last_task <<<"$output")" = "T1-2" ]
}

@test "--json: autopilot backing off is [b]" {
  local repo; repo=$(_make_repo r-backoff)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":2,\"cycle_count\":4,\"last_outcome\":\"stuck\",\"last_stuck_reason\":\"ci red\"}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[b]" ]
  [ "$(jq -r .autopilot.last_outcome <<<"$output")" = "stuck" ]
  [ "$(jq -r .autopilot.stuck_reason <<<"$output")" = "ci red" ]
}

@test "--json: autopilot stopped is [s] with the stop reason" {
  local repo; repo=$(_make_repo r-stop)
  _state "$repo" '{"status":"stopped","started_at":"2026-01-01T00:00:00Z","end_time":"2026-01-01T05:00:00Z","stuck_count":1,"cycle_count":3,"last_cycle_at":"2026-01-01T02:00:00Z","stop_reason":"window closed"}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[s]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "2" ]
  [ "$(jq -r .autopilot.stop_reason <<<"$output")" = "window closed" ]
}

@test "--json: autopilot paused is [p], frozen at paused_at" {
  local repo; repo=$(_make_repo r-pause)
  _state "$repo" '{"status":"paused","started_at":"2026-01-01T00:00:00Z","end_time":"2026-01-01T05:00:00Z","paused_at":"2026-01-01T01:00:00Z","stuck_count":0,"cycle_count":2}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.status <<<"$output")" = "paused" ]
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[p]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "1" ]
}

@test "the text statusline still hides a paused autopilot (behaviour unchanged)" {
  local repo; repo=$(_make_repo r-pause-text)
  _state "$repo" '{"status":"paused","started_at":"2026-01-01T00:00:00Z","end_time":"2026-01-01T05:00:00Z","paused_at":"2026-01-01T01:00:00Z","stuck_count":0,"cycle_count":2}'
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ -z "$output" ]
}

@test "--json: missing, malformed or garbage state gives autopilot null, exit 0" {
  local repo; repo=$(_make_repo r-bad)
  _state "$repo" '{not json'
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
  _state "$repo" '{"status":"running","started_at":"not-a-date","end_time":"also-not","stuck_count":1,"cycle_count":1}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
}

@test "--json: detached HEAD gives an empty branch" {
  local repo; repo=$(_make_repo r-detached)
  git_identity "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" checkout -q --detach
  run _hud "$repo" --json
  [ "$(jq -r .branch <<<"$output")" = "" ]
}

@test "--json: a git worktree reports its own branch" {
  local repo; repo=$(_make_repo r-wt)
  git_identity "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" worktree add -q -b wt-branch "$BATS_TEST_TMPDIR/wt"
  run _hud "$BATS_TEST_TMPDIR/wt" --json
  [ "$(jq -r .branch <<<"$output")" = "wt-branch" ]
  [ "$(jq -r .worktree <<<"$output")" = "wt" ]
}

@test "--json: the main checkout has an empty worktree name" {
  local repo; repo=$(_make_repo r-main-wt)
  run _hud "$repo" --json
  [ "$(jq -r .worktree <<<"$output")" = "" ]
}

@test "--json: has no last_input text key, and --with-last-input is ignored" {
  local repo; repo=$(_make_repo r-last)
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf 'hello there' > "$LAST_INPUT_STATE_DIR/sess1"
  run _hud "$repo" --json --with-last-input
  [ "$(jq -r 'has("last_input")' <<<"$output")" = "false" ]
  [[ "$output" != *"hello there"* ]]
}

@test "unparseable stdin or a non-repo cwd still prints valid JSON and exits 0" {
  run bash -c "echo garbage | bash '$HUD' --json"
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  run bash -c "echo '{\"cwd\":\"/nonexistent/dir\"}' | bash '$HUD' --json"
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
}

@test "the helper makes no network call and writes nothing" {
  ! grep -nE 'curl|wget|https?://|> *"?\$HOME|~/\.claude' "$HUD"
}

# --- heartbeat-driven minimal statusline ---------------------------------

_line() { # $1 repo
  printf '{"cwd":"%s","session_id":"sess1","context_window":{"remaining_percentage":64}}' "$1" | bash "$SCRIPT"
}

@test "heartbeat 'on' and fresh: statusline shrinks to ctx | branch" {
  local repo; repo=$(_make_repo r-hb-on)
  mkdir -p "$HUD_ACTIVE_DIR"; printf 'on\n' > "$HUD_ACTIVE_DIR/sess1"
  run _line "$repo"
  [ "$output" = "ctx: 64% left | branch: main" ]
}

@test "no heartbeat: statusline prints in full" {
  local repo; repo=$(_make_repo r-hb-none)
  run _line "$repo"
  [[ "$output" == *"no claimed task"* ]]
}

@test "heartbeat 'off': statusline prints in full" {
  local repo; repo=$(_make_repo r-hb-off)
  mkdir -p "$HUD_ACTIVE_DIR"; printf 'off\n' > "$HUD_ACTIVE_DIR/sess1"
  run _line "$repo"
  [[ "$output" == *"no claimed task"* ]]
}

@test "stale heartbeat (older than the max age): statusline prints in full" {
  local repo; repo=$(_make_repo r-hb-stale)
  mkdir -p "$HUD_ACTIVE_DIR"; printf 'on\n' > "$HUD_ACTIVE_DIR/sess1"
  touch -t 202001010000 "$HUD_ACTIVE_DIR/sess1"
  run _line "$repo"
  [[ "$output" == *"no claimed task"* ]]
}

@test "heartbeat for another session does not shrink this one" {
  local repo; repo=$(_make_repo r-hb-other)
  mkdir -p "$HUD_ACTIVE_DIR"; printf 'on\n' > "$HUD_ACTIVE_DIR/other"
  run _line "$repo"
  [[ "$output" == *"no claimed task"* ]]
}

@test "a path-like session id never reads outside the heartbeat dir" {
  run bash -c "source '$SCRIPT'; sl-hud-active '$HUD_ACTIVE_DIR' '../x'"
  [ "$status" -ne 0 ]
}

@test "--json: merged_count is surfaced, a missing one is 0, ledger is null without a file" {
  local repo; repo=$(_make_repo r-merged)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":0,\"cycle_count\":4,\"merged_count\":3}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.merged <<<"$output")" = "3" ]
  [ "$(jq -r .ledger <<<"$output")" = "null" ]
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":0,\"cycle_count\":4}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.merged <<<"$output")" = "0" ]
}

@test "--json: ledger written by ledger.sh is passed through; corrupt ledger is null" {
  local repo; repo=$(_make_repo r-ledger)
  bash "$REPO_ROOT/statusline-setup/scripts/ledger.sh" start 230 "do it"
  bash "$REPO_ROOT/statusline-setup/scripts/ledger.sh" park k5
  run _hud "$repo" --json
  [ "$(jq -r .ledger.lifetime_jobs <<<"$output")" = "230" ]
  [ "$(jq -r '.ledger.running[0].title' <<<"$output")" = "do it" ]
  [ "$(jq -r .ledger.parked <<<"$output")" = "1" ]
  echo 'garbage' > "$CCXP_LEDGER_FILE"
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .ledger <<<"$output")" = "null" ]
}

@test "--json: last_input_at is the cache file mtime, 0 when there is none" {
  local repo; repo=$(_make_repo r-lastat)
  run _hud "$repo" --json
  [ "$(jq -r .last_input_at <<<"$output")" = "0" ]
  mkdir -p "$LAST_INPUT_STATE_DIR"; : > "$LAST_INPUT_STATE_DIR/sess1"
  touch -t 202601010000 "$LAST_INPUT_STATE_DIR/sess1"
  run _hud "$repo" --json
  [ "$(jq -r '.last_input_at > 1700000000' <<<"$output")" = "true" ]
}
