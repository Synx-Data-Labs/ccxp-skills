#!/usr/bin/env bats
# Tests for hud/scripts/hud-behind.sh (commits behind / ahead of the remote, for the HUD repo cell).
# Every repo is a temp clone of a bare temp origin; nothing talks to the network or the developer's state.

load test_helper
BEHIND="$REPO_ROOT/hud/scripts/hud-behind.sh"

setup() {
  export HUD_BEHIND_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export CCXP_HUD_BEHIND_SYNC=1
  export GIT_TERMINAL_PROMPT=0
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"; WORK="$BATS_TEST_TMPDIR/work"; PEER="$BATS_TEST_TMPDIR/peer"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$WORK" 2>/dev/null; git_identity "$WORK"
  git -C "$WORK" checkout -q -b main 2>/dev/null || true
  _commit "$WORK" base; git -C "$WORK" push -q -u origin main
  git clone -q "$ORIGIN" "$PEER"; git_identity "$PEER"
}

# $1 repo $2 message
_commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
# $1 count: new commits on origin/main made from the peer clone
_origin_adds() { local i; for i in $(seq 1 "$1"); do _commit "$PEER" "origin $i"; done; git -C "$PEER" push -q origin main; }
_run() { run bash "$BEHIND" "$WORK"; }

@test "up to date: silent" {
  _run
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "behind N: counted after the foreground fetch" {
  _origin_adds 3
  _run
  [ "$output" = '{"behind":3,"ahead":0,"base":"upstream"}' ]
}

@test "ahead M only" {
  _commit "$WORK" a1; _commit "$WORK" a2
  _run
  [ "$output" = '{"behind":0,"ahead":2,"base":"upstream"}' ]
}

@test "both ahead and behind" {
  _origin_adds 4; _commit "$WORK" a1
  _run
  [ "$output" = '{"behind":4,"ahead":1,"base":"upstream"}' ]
}

@test "no upstream: falls back to origin/<default branch>" {
  _origin_adds 2
  git -C "$WORK" checkout -q -b feature
  git -C "$WORK" fetch -q origin
  git -C "$WORK" remote set-head origin main
  _run
  [ "$output" = '{"behind":2,"ahead":0,"base":"origin"}' ]
}

@test "no upstream and no origin default branch: silent" {
  git -C "$WORK" checkout -q -b feature
  git -C "$WORK" remote remove origin
  _run
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "detached HEAD: silent" {
  _origin_adds 2
  git -C "$WORK" checkout -q --detach
  _run
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "not a git repo: silent, and no state is written" {
  mkdir "$BATS_TEST_TMPDIR/plain"
  run bash "$BEHIND" "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -e "$HUD_BEHIND_STATE_DIR" ]
}

@test "the fetch writes only remote-tracking refs: branch, working tree and HEAD stay put" {
  _origin_adds 2
  local head; head=$(git -C "$WORK" rev-parse HEAD)
  _run
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "rate limit: a second call inside the TTL does not fetch again" {
  _run
  _origin_adds 2
  _run
  [ -z "$output" ]                      # still the old refs: no second fetch
  rm -rf "$HUD_BEHIND_STATE_DIR"; _run  # cache gone: fetches
  [ "$output" = '{"behind":2,"ahead":0,"base":"upstream"}' ]
}

@test "rate limit: an old attempt is retried after the TTL" {
  _run
  _origin_adds 1
  local f; f=$(ls "$HUD_BEHIND_STATE_DIR"/*.json)
  jq -c '.tried = 1' "$f" > "$f.new" && mv "$f.new" "$f"
  _run
  [ "$output" = '{"behind":1,"ahead":0,"base":"upstream"}' ]
}

@test "a failed fetch keeps the last answer and is cached (no retry storm)" {
  _origin_adds 2
  _run
  [ "$output" = '{"behind":2,"ahead":0,"base":"upstream"}' ]
  git -C "$WORK" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
  local f; f=$(ls "$HUD_BEHIND_STATE_DIR"/*.json)
  jq -c '.tried = 1' "$f" > "$f.new" && mv "$f.new" "$f"
  _run
  [ "$output" = '{"behind":2,"ahead":0,"base":"upstream"}' ]
  [ "$(jq -r .ok "$f")" = false ]
  [ "$(jq -r '.tried > 1' "$f")" = true ]
}

@test "a held lock (fetch in flight) skips the refresh" {
  _origin_adds 2
  mkdir -p "$HUD_BEHIND_STATE_DIR"
  mkdir "$HUD_BEHIND_STATE_DIR/$(source "$BEHIND"; hb-key "$WORK").json.lock"
  _run
  [ -z "$output" ]
}

@test "default mode detaches the fetch: it still completes and caches in the background" {
  _origin_adds 1
  run env -u CCXP_HUD_BEHIND_SYNC bash "$BEHIND" "$WORK"
  [ "$status" -eq 0 ]
  local i; for i in $(seq 1 50); do ls "$HUD_BEHIND_STATE_DIR"/*.json >/dev/null 2>&1 && break; sleep 0.1; done
  [ "$(jq -r .ok "$HUD_BEHIND_STATE_DIR"/*.json)" = true ]
  _run
  [ "$output" = '{"behind":1,"ahead":0,"base":"upstream"}' ]
}

@test "hud-data.sh: the behind key carries the counts, and is null when level" {
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_HWM_SYNC=1 HUD_NIGHTLY_OFF=1 HUD_NO_NETWORK=1
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json" LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version" HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/none" HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/ci"
  export CCXP_HUD_CACHE_DIR="$BATS_TEST_TMPDIR/hud-cache"
  run jq -c .behind < <(bash "$REPO_ROOT/hud/scripts/hud-data.sh" <<<"{\"cwd\":\"$WORK\"}")
  [ "$output" = null ]
  _origin_adds 5; _commit "$WORK" a1; export HUD_BEHIND_TTL=0 # the first call used the rate limit
  run jq -c .behind < <(bash "$REPO_ROOT/hud/scripts/hud-data.sh" <<<"{\"cwd\":\"$WORK\"}")
  [ "$output" = '{"behind":5,"ahead":1,"base":"upstream"}' ]
}
