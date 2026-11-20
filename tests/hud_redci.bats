#!/usr/bin/env bats
# Tests for the unhandled-red-CI cell of the ccxp-hud data helper (hud/scripts/hud-redci.sh, also reached
# through hud-data.sh --json). A fake `gh` on PATH answers from fixture files and logs its argv; nothing
# here talks to the network or the developer's real state.

load test_helper
REDCI="$REPO_ROOT/hud/scripts/hud-redci.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"

setup() {
  export HUD_REDCI_STATE_DIR="$BATS_TEST_TMPDIR/redci"
  export HUD_REDCI_CONTEXT_DIR="$BATS_TEST_TMPDIR/ctx"
  export HUD_REDCI_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export CCXP_HUD_REDCI_SYNC=1
  mkdir -p "$HUD_REDCI_CONTEXT_DIR" "$BATS_TEST_TMPDIR/todo" "$BATS_TEST_TMPDIR/bin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"; : > "$GH_LOG"
  echo '[]' > "$BATS_TEST_TMPDIR/fail.json"; echo '[]' > "$BATS_TEST_TMPDIR/succ.json"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
d="$(dirname "$0")/.."
[ ! -e "$d/gh.fail" ] || exit 1
case "$1 $2" in
  "repo view") echo trunk ;;
  "run list")
    case "$*" in
      *"--status failure"*) cat "$d/fail.json" ;;
      *"--status success"*) cat "$d/succ.json" ;;
      *"--status timed_out"*) if [ -e "$d/timed.json" ]; then cat "$d/timed.json"; else echo '[]'; fi ;;
      *"--status startup_failure"*) echo '[]' ;;
    esac ;;
esac
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_iso() { # $1 = seconds ago
  local t=$(( $(date +%s) - $1 ))
  date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ
}

# $1 id, $2 workflow, $3 branch, $4 event, $5 seconds ago -> one run object
_run() { printf '{"databaseId":%s,"workflowName":"%s","headBranch":"%s","event":"%s","createdAt":"%s"}' "$1" "$2" "$3" "$4" "$(_iso "$5")"; }

_redci() { # $1 repos json
  ( source "$REDCI"; hud-redci-json "$1" 15 "$BATS_TEST_TMPDIR/todo" )
}

@test "no repos, an empty list or invalid names print null and never run gh" {
  run _redci '[]'; [ "$output" = null ]
  run _redci 'null'; [ "$output" = null ]
  run _redci '["not a repo","a/b;ls","../x/y"]'; [ "$output" = null ]
  [ ! -s "$GH_LOG" ]
}

@test "any workflow failing on the default branch counts (Upstream Sync, Tests too); a PR branch does not" {
  printf '[%s,%s,%s]' "$(_run 11111111 'Upstream Sync' trunk workflow_dispatch 3600)" \
    "$(_run 22222222 Tests trunk push 7200)" "$(_run 33333333 Tests feature-x pull_request 100)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 2 ]
  [ "$(jq -r '.items[0].wf' <<<"$output")" = "Upstream Sync" ]
  [ "$(jq -r '.items[0].repo' <<<"$output")" = widgets ]
}

@test "a failed scheduled run counts even off the default branch" {
  printf '[%s]' "$(_run 44444444 Nightly nightly-branch schedule 600)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
}

@test "a later success of the same workflow and branch supersedes the failure; another workflow does not" {
  printf '[%s,%s]' "$(_run 55555555 Nightly trunk schedule 7200)" "$(_run 66666666 Tests trunk push 7200)" > "$BATS_TEST_TMPDIR/fail.json"
  printf '[{"workflowName":"Nightly","headBranch":"trunk","createdAt":"%s"}]' "$(_iso 3600)" > "$BATS_TEST_TMPDIR/succ.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
  [ "$(jq -r '.items[0].wf' <<<"$output")" = Tests ]
}

@test "an earlier success does not supersede a later failure" {
  printf '[%s]' "$(_run 77777777 Nightly trunk schedule 3600)" > "$BATS_TEST_TMPDIR/fail.json"
  printf '[{"workflowName":"Nightly","headBranch":"trunk","createdAt":"%s"}]' "$(_iso 7200)" > "$BATS_TEST_TMPDIR/succ.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
}

@test "a run id found in a context file, the ledger or a TODO file is handled" {
  printf '[%s,%s,%s,%s]' "$(_run 88000001 A trunk push 600)" "$(_run 88000002 B trunk push 600)" \
    "$(_run 88000003 C trunk push 600)" "$(_run 88000004 D trunk push 600)" > "$BATS_TEST_TMPDIR/fail.json"
  echo 'RCA of run 88000001 done' > "$HUD_REDCI_CONTEXT_DIR/j1.md"
  echo '{"jobs":[{"title":"rca 88000002"}]}' > "$HUD_REDCI_LEDGER_FILE"
  echo 'see run 88000003' > "$BATS_TEST_TMPDIR/todo/T1-x.md"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
  [ "$(jq -r '.items[0].wf' <<<"$output")" = D ]
}

@test "a failure older than 7 days is dropped" {
  printf '[%s]' "$(_run 99000001 Old trunk push 700000)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/widgets"]'
  [ "$output" = '{"n":0,"items":[]}' ]
}

@test "no failures: answered n=0 with three cheap list calls and nothing else" {
  run _redci '["acme/widgets"]'
  [ "$output" = '{"n":0,"items":[]}' ]
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 3 ] # failure, timed_out, startup_failure: one call each
  grep -q -- '--status failure' "$GH_LOG"
}

@test "gh failing with no cache prints null; a cached answer is kept when a later refresh fails" {
  touch "$BATS_TEST_TMPDIR/gh.fail"
  run _redci '["acme/widgets"]'; [ "$output" = null ]
  rm "$BATS_TEST_TMPDIR/gh.fail" "$HUD_REDCI_STATE_DIR"/*.json
  printf '[%s]' "$(_run 12000001 Tests trunk push 600)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/widgets"]'; [ "$(jq -r .n <<<"$output")" = 1 ]
  touch "$BATS_TEST_TMPDIR/gh.fail"
  local f
  for f in "$HUD_REDCI_STATE_DIR"/*.json; do jq -c --argjson d "$(( $(date +%s) - 400 ))" '.attempted = 1 | .fetched = $d' "$f" > "$f.t" && mv "$f.t" "$f"; done
  run _redci '["acme/widgets"]'; [ "$(jq -r .n <<<"$output")" = 1 ]
  # the data time did not move, only the attempt time
  [ "$(jq -r '.attempted - .fetched' "$HUD_REDCI_STATE_DIR"/*.json)" -ge 399 ]
}

@test "data older than 6 hours is not shown when refreshes keep failing (the repo counts as unknown)" {
  printf '[%s]' "$(_run 12100001 Tests trunk push 600)" > "$BATS_TEST_TMPDIR/fail.json"
  _redci '["acme/widgets"]' >/dev/null
  touch "$BATS_TEST_TMPDIR/gh.fail"
  local f
  for f in "$HUD_REDCI_STATE_DIR"/*.json; do jq -c --argjson d "$(( $(date +%s) - 30000 ))" '.attempted = 1 | .fetched = $d' "$f" > "$f.t" && mv "$f.t" "$f"; done
  run _redci '["acme/widgets"]'; [ "$output" = null ]
}

@test "a timed_out run counts too (gh lists it under its own status)" {
  printf '[%s]' "$(_run 12200001 Nightly trunk schedule 600)" > "$BATS_TEST_TMPDIR/timed.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
  grep -q -- '--status timed_out' "$GH_LOG"
}

@test "within the TTL the cache answers and gh is not called again" {
  printf '[%s]' "$(_run 13000001 Tests trunk push 600)" > "$BATS_TEST_TMPDIR/fail.json"
  _redci '["acme/widgets"]' >/dev/null
  : > "$GH_LOG"
  run _redci '["acme/widgets"]'
  [ "$(jq -r .n <<<"$output")" = 1 ]
  [ ! -s "$GH_LOG" ]
}

@test "two repos are summed, newest first, at most 3 items listed" {
  printf '[%s,%s]' "$(_run 14000001 A trunk push 3000)" "$(_run 14000002 B trunk push 2000)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/one","acme/two"]'
  [ "$(jq -r .n <<<"$output")" = 4 ]
  [ "$(jq -r '.items | length' <<<"$output")" = 3 ]
  [ "$(jq -r '.items[0].wf' <<<"$output")" = B ]
}

@test "untrusted workflow names are printable and truncated" {
  printf '[{"databaseId":15000001,"workflowName":"Evil\\u001b[31m%s","headBranch":"trunk","event":"push","createdAt":"%s"}]' "$(printf 'x%.0s' $(seq 1 80))" "$(_iso 600)" > "$BATS_TEST_TMPDIR/fail.json"
  run _redci '["acme/widgets"]'
  [ "$(jq -r '.items[0].wf | length' <<<"$output")" -le 40 ]
  ! jq -r '.items[0].wf' <<<"$output" | grep -q $'\033'
}

@test "hud-data.sh: redci is null without a list and never runs gh; with a list it carries the count" {
  local repo="$BATS_TEST_TMPDIR/r"; mkdir -p "$repo"; git -C "$repo" init -q -b trunk
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hq" HUD_HWM_SYNC=1 HUD_NIGHTLY_OFF=1 HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hv" HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/none"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/li" CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/l.json"
  run bash -c "printf '%s' '{\"cwd\":\"$repo\"}' | bash '$HUD' --json"
  [ "$(jq -r .redci <<<"$output")" = null ]
  [ ! -s "$GH_LOG" ]
  printf '[%s]' "$(_run 16000001 Tests trunk push 600)" > "$BATS_TEST_TMPDIR/fail.json"
  run bash -c "printf '%s' '{\"cwd\":\"$repo\",\"redci\":[\"acme/widgets\"]}' | bash '$HUD' --json"
  [ "$(jq -r .redci.n <<<"$output")" = 1 ]
}

@test "the session repo is never watched: hud-redci.sh takes only the passed list" {
  ! grep -nE 'remote get-url|rev-parse|origin' "$REDCI"
}

@test "hud-data.sh runs no gh; hud-redci.sh has no curl, wget or URLs" {
  ! grep -nE '\bgh ' "$HUD"
  ! grep -nE 'curl|wget|https?://' "$REDCI"
}
