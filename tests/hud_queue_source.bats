#!/usr/bin/env bats
# Tests for the queue source (T20261104-420419): hud-lib.sh sl-queue-json / sl-default-branch /
# sl-queue-fetch and the hud-data.sh `queue_source` stdin key. "origin" is a local bare repo; nothing
# here touches the network or the developer's state.

load test_helper
LIB="$REPO_ROOT/hud/scripts/hud-lib.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"

setup() {
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/no-such-remote"
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue"
  export HUD_QUEUE_FETCH_SYNC=1
  export GIT_TERMINAL_PROMPT=0
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  SEED="$BATS_TEST_TMPDIR/seed"
  ME="$BATS_TEST_TMPDIR/me"
}

_q() { bash -c "source '$LIB'; sl-queue-json '$1' '${2:-}'"; }

# $1 id suffix, $2 status, $3 optional claimed_by -> a task file body
_task() {
  printf -- '---\nstatus: %s\n' "$2"
  [ -z "${3:-}" ] || printf 'claimed_by: %s\n' "$3"
  printf -- '---\n\n# T20260101-00000%s: task %s\n' "$1" "$1"
}

# A bare origin whose default branch is $1 (default main), a seed clone, and `me` cloned from it, all with two ready tasks.
_world() {
  local br="${1:-main}"
  git init -q --bare -b "$br" "$ORIGIN"
  git clone -q "$ORIGIN" "$SEED" 2>/dev/null
  git_identity "$SEED"
  mkdir -p "$SEED/dev/TODO"
  printf '# Q\n\n- [T20260101-000001](T20260101-000001-a.md): a\n- [T20260101-000002](T20260101-000002-b.md): b\n' > "$SEED/dev/TODO/queue.md"
  _task 1 Open > "$SEED/dev/TODO/T20260101-000001-a.md"
  _task 2 Open > "$SEED/dev/TODO/T20260101-000002-b.md"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m seed && git -C "$SEED" push -q origin "HEAD:$br"
  git clone -q "$ORIGIN" "$ME" 2>/dev/null
  git_identity "$ME"
}

# origin gets newer: a third task, task 2 claimed by another clone, task 1 blocked
_origin_moves_on() {
  printf -- '- [T20260101-000003](T20260101-000003-c.md): c\n' >> "$SEED/dev/TODO/queue.md"
  _task 3 Open > "$SEED/dev/TODO/T20260101-000003-c.md"
  _task 2 Open "someone-else:abc" > "$SEED/dev/TODO/T20260101-000002-b.md"
  _task 1 "BLOCKED" > "$SEED/dev/TODO/T20260101-000001-a.md"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m more && git -C "$SEED" push -q origin HEAD:"${1:-main}"
}

@test "working-tree mode is the default and ignores origin: stale clone shows its own numbers, no extra keys" {
  _world; _origin_moves_on
  run _q "$ME"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":2,"ready":2,"held":0,"epic":0,"claimed":0,"revisited":0,"autoparked":0}' ] || { echo "$output"; false; }
  run _q "$ME" working-tree
  [ "$output" = '{"total":2,"ready":2,"held":0,"epic":0,"claimed":0,"revisited":0,"autoparked":0}' ]
}

@test "default-branch mode reads origin/<default> after the fetch: newer queue, same bucketing, labelled with the branch" {
  _world; _origin_moves_on
  run _q "$ME" default-branch
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"total":3,"ready":1,"held":1,"epic":0,"claimed":1,"revisited":0,"autoparked":0,"source":"default-branch","branch":"main"}' ] || { echo "$output"; false; }
}

@test "default-branch mode uses the real default branch name from origin/HEAD (trunk), not main" {
  _world trunk; _origin_moves_on trunk
  [ "$(git -C "$ME" symbolic-ref refs/remotes/origin/HEAD)" = "refs/remotes/origin/trunk" ]
  run _q "$ME" default-branch
  [ "$(jq -r '.branch + " " + (.total | tostring)' <<<"$output")" = "trunk 3" ] || { echo "$output"; false; }
}

@test "default-branch mode: a claim by THIS clone is not 'claimed by someone else'" {
  _world
  local me; me=$(bash -c "source '$LIB'; sl-clone-id '$ME'")
  _task 2 Open "$me" > "$SEED/dev/TODO/T20260101-000002-b.md"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m mine && git -C "$SEED" push -q origin HEAD:main
  run _q "$ME" default-branch
  [ "$(jq -r .claimed <<<"$output")" = "0" ] || { echo "$output"; false; }
  [ "$(jq -r .ready <<<"$output")" = "2" ]
}

@test "default-branch mode never touches the working tree, the index, HEAD or the branch" {
  _world; _origin_moves_on
  printf 'local edit\n' >> "$ME/dev/TODO/queue.md"
  local head before after
  head=$(git -C "$ME" rev-parse HEAD)
  before=$(cd "$ME" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum | shasum)
  run _q "$ME" default-branch
  after=$(cd "$ME" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum | shasum)
  [ "$before" = "$after" ]
  [ "$(git -C "$ME" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$ME" status --porcelain)" = " M dev/TODO/queue.md" ]
  [ "$(git -C "$ME" symbolic-ref --short HEAD)" = "main" ]
  # no temp dir left behind
  [ -z "$(ls -d "${TMPDIR:-/tmp}"/hud-queue.* 2>/dev/null)" ]
}

@test "no origin: default-branch falls back to the working tree and says so" {
  git init -q -b main "$ME"; git_identity "$ME"
  mkdir -p "$ME/dev/TODO"
  printf -- '- [T20260101-000001](T20260101-000001-a.md): a\n' > "$ME/dev/TODO/queue.md"
  run _q "$ME" default-branch
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.total, .source, .fallback, .branch]' <<<"$output")" = '[1,"working-tree",true,null]' ] || { echo "$output"; false; }
}

@test "origin with no usable default branch ref falls back to the working tree and says so" {
  _world
  git -C "$ME" update-ref -d refs/remotes/origin/main
  git -C "$ME" symbolic-ref -d refs/remotes/origin/HEAD
  git -C "$ME" remote set-url origin "$BATS_TEST_TMPDIR/gone.git"
  run _q "$ME" default-branch
  [ "$(jq -c '[.total, .source, .fallback]' <<<"$output")" = '[2,"working-tree",true]' ] || { echo "$output"; false; }
}

@test "sl-default-branch: origin/HEAD, then main, then master; nothing otherwise" {
  _world
  [ "$(bash -c "source '$LIB'; sl-default-branch '$ME'")" = "main" ]
  git -C "$ME" symbolic-ref -d refs/remotes/origin/HEAD
  [ "$(bash -c "source '$LIB'; sl-default-branch '$ME'")" = "main" ]
  git -C "$ME" update-ref refs/remotes/origin/master "$(git -C "$ME" rev-parse HEAD)"
  git -C "$ME" update-ref -d refs/remotes/origin/main
  [ "$(bash -c "source '$LIB'; sl-default-branch '$ME'")" = "master" ]
  git -C "$ME" update-ref -d refs/remotes/origin/master
  [ -z "$(bash -c "source '$LIB'; sl-default-branch '$ME'")" ]
}

@test "offline origin: the fetch fails silently and the last known origin/<default> is used" {
  _world
  git -C "$ME" remote set-url origin "$BATS_TEST_TMPDIR/unreachable.git"
  run _q "$ME" default-branch
  [ "$status" -eq 0 ]
  [ "$(jq -r '.total, .source' <<<"$output" | paste -sd' ')" = "2 default-branch" ] || { echo "$output"; false; }
}

@test "the fetch is rate limited: a second poll inside the window does not fetch, after it does" {
  _world
  export HUD_QUEUE_FETCH_TTL=120
  run _q "$ME" default-branch
  [ "$(jq -r .total <<<"$output")" = "2" ]
  _origin_moves_on
  run _q "$ME" default-branch
  [ "$(jq -r .total <<<"$output")" = "2" ] || { echo "fetched inside the window: $output"; false; }
  # age the stamp past the window
  local stamp; stamp=$(ls "$HUD_QUEUE_STATE_DIR"/fetch-*)
  touch -t 202001010000 "$stamp"
  run _q "$ME" default-branch
  [ "$(jq -r .total <<<"$output")" = "3" ] || { echo "no fetch after the window: $output"; false; }
}

@test "the fetch never blocks: without SYNC the poll answers at once from the current origin ref" {
  _world; _origin_moves_on
  unset HUD_QUEUE_FETCH_SYNC
  run _q "$ME" default-branch
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "default-branch" ]
  [ -f "$(ls "$HUD_QUEUE_STATE_DIR"/fetch-*)" ]
}

@test "default branch without dev/TODO falls back (marked); with dev/TODO but no queue.md it is null, not an error" {
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$ME" 2>/dev/null; git_identity "$ME"
  mkdir -p "$ME/dev/TODO"; printf -- '- [T20260101-000001](T20260101-000001-a.md): a\n' > "$ME/dev/TODO/queue.md"
  printf 'x\n' > "$ME/README"; git -C "$ME" add README; git -C "$ME" commit -q -m init; git -C "$ME" push -q origin HEAD:main
  run _q "$ME" default-branch
  [ "$(jq -c '[.total, .source, .fallback]' <<<"$output")" = '[1,"working-tree",true]' ] || { echo "$output"; false; }
  printf 'notes\n' > "$ME/dev/TODO/NOTES.md"; git -C "$ME" add dev/TODO/NOTES.md; git -C "$ME" commit -q -m notes; git -C "$ME" push -q origin HEAD:main
  run _q "$ME" default-branch
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hud-data --json: queue_source in stdin picks the source; absent or unknown means the working tree" {
  _world; _origin_moves_on
  run bash -c "printf '%s' '{\"cwd\":\"$ME\",\"queue_source\":\"default-branch\"}' | bash '$HUD' --json"
  [ "$(jq -r '.queue | [.total, .source, .branch] | @csv' <<<"$output")" = '3,"default-branch","main"' ] || { echo "$output"; false; }
  run bash -c "printf '%s' '{\"cwd\":\"$ME\"}' | bash '$HUD' --json"
  [ "$(jq -c '.queue | [.total, has("source")]' <<<"$output")" = '[2,false]' ]
  run bash -c "printf '%s' '{\"cwd\":\"$ME\",\"queue_source\":\"bogus\"}' | bash '$HUD' --json"
  [ "$(jq -c '.queue | [.total, has("source")]' <<<"$output")" = '[2,false]' ]
}
