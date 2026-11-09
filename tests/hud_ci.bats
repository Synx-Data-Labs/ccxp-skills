#!/usr/bin/env bats
# Tests for the CI segment of the ccxp-hud data helper (hud/scripts/hud-ci.sh,
# reached through hud-data.sh --json). A fake `gh` on PATH answers from a fixture file and
# logs its argv; nothing here talks to the network or the developer's real state.

load test_helper
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
CI="$REPO_ROOT/hud/scripts/hud-ci.sh"

setup() {
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_HWM_SYNC=1 HUD_NIGHTLY_OFF=1 # fetch stamps and the queue watermark never touch ~/.claude
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  # Version segment: no real network, no writes under the developer's home.
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/no-such-remote"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
}

_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  printf '%s' "$dir"
}

# $1 = what the fake gh prints for `run list` ("FAIL" makes every call exit 1)
_fake_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"; : > "$GH_LOG"
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/gh.out"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$(cat "$(dirname "$0")/../gh.out")" != FAIL ] || exit 1
case "$1 $2" in
  "repo view") echo trunk ;;
  "run list") cat "$(dirname "$0")/../gh.out" ;;
esac
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

_run_json() { # $1 = full stdin JSON; foreground refresh
  printf '%s' "$1" | CCXP_HUD_CI_SYNC=1 bash "$HUD" --json
}
_hud_ci() { # $1 repo, $2 ci config json
  _run_json "$(printf '{"cwd":"%s","session_id":"sess1","ci":%s,"ci_ttl":15}' "$1" "$2")"
}

OK_RUN='[{"status":"completed","conclusion":"success","createdAt":"2026-10-26T03:00:00Z"}]'

@test "no network tools or URLs in the helpers; only hud-ci.sh runs gh" {
  ! grep -nE 'curl|wget|https?://' "$HUD" "$CI"
  ! grep -nE '\bgh ' "$HUD"
}

@test "ci is null and gh is never run when no ci is configured" {
  local repo; repo=$(_make_repo r-none)
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" null
  [ "$(jq -r .ci <<<"$output")" = "null" ]
  [ ! -s "$GH_LOG" ]
}

@test "a configured workflow maps run results to passing/failing/running/unknown" {
  local repo; repo=$(_make_repo r-states)
  local row st concl want n=0
  while IFS='|' read -r st concl want; do
    n=$((n + 1))
    export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/ci-$n"
    _fake_gh "[{\"status\":\"$st\",\"conclusion\":\"$concl\",\"createdAt\":\"2026-10-26T03:00:00Z\"}]"
    run _hud_ci "$repo" '{"workflow":"nightly.yml"}'
    [ "$(jq -r .ci.state <<<"$output")" = "$want" ]
    [ "$(jq -r '.ci.at > 1700000000' <<<"$output")" = "true" ]
  done <<'EOT'
completed|success|passing
completed|failure|failing
completed|timed_out|failing
in_progress||running
queued||running
completed|cancelled|unknown
EOT
}

@test "workflow, branch and repo reach gh as separate arguments; the default branch is asked of gh" {
  local repo; repo=$(_make_repo r-args)
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/a1"
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" '{"workflow":"w.yml","repo":"acme/widgets"}'
  grep -qF 'run list --workflow w.yml --branch trunk --repo acme/widgets --limit 20 --json status,conclusion,createdAt,startedAt,updatedAt,event' "$GH_LOG"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/a2"
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" '{"workflow":"w.yml","branch":"release/4.8"}'
  grep -qF 'run list --workflow w.yml --branch release/4.8 --limit 20' "$GH_LOG"
}

@test "a bad ci config (metacharacters, spaces, bad repo, wrong types) is ignored; gh never runs" {
  local repo bad; repo=$(_make_repo r-bad)
  _fake_gh "$OK_RUN"
  for bad in '{"workflow":"a b.yml"}' '{"workflow":"x;touch pwn"}' '{"workflow":"$(id)"}' '{"workflow":"w.yml","repo":"no-slash"}' '{"workflow":"w.yml","branch":"-x"}' '{"workflow":"w.yml","repo":"--web/x"}' '{"workflow":"w.yml","repo":"a/-x"}' '{"workflow":5}' '"str"' '[]'; do
    run _hud_ci "$repo" "$bad"
    [ "$status" -eq 0 ]
    [ "$(jq -r .ci <<<"$output")" = "null" ]
  done
  [ ! -s "$GH_LOG" ]
  [ ! -e "$repo/pwn" ]
}

@test "gh failing, no runs or garbage output gives ci null (or the old answer), exit 0, nothing from gh printed" {
  local repo out n=0; repo=$(_make_repo r-fail)
  for out in FAIL '[]' 'not json' '[{"status":{"x":1}}]'; do
    n=$((n + 1))
    export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/f$n"
    _fake_gh "$out"
    run _hud_ci "$repo" '{"workflow":"w.yml"}'
    [ "$status" -eq 0 ]
    jq -e . <<<"$output" >/dev/null
    [[ "$output" != *"not json"* ]]
    [ "$(jq -r '.ci.state // "null"' <<<"$output")" != "passing" ]
  done
}

@test "gh missing from PATH gives ci null" {
  local repo; repo=$(_make_repo r-nogh)
  run bash -c "printf '{\"cwd\":\"%s\",\"ci\":{\"workflow\":\"w.yml\"}}' '$repo' | PATH=/usr/bin:/bin CCXP_HUD_CI_SYNC=1 bash '$HUD' --json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ci <<<"$output")" = "null" ]
}

@test "a fresh cache is served without calling gh; an old one is refreshed once" {
  local repo; repo=$(_make_repo r-cache)
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = "passing" ]
  local calls; calls=$(wc -l < "$GH_LOG")
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = "passing" ]
  [ "$(wc -l < "$GH_LOG")" -eq "$calls" ]
  local f; f=$(ls "$HUD_CI_STATE_DIR"/*.json)
  jq '.fetched = 1' "$f" > "$f.t" && mv "$f.t" "$f"
  _fake_gh '[{"status":"completed","conclusion":"failure","createdAt":"2026-10-27T03:00:00Z"}]'
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = "failing" ]
  [ "$(wc -l < "$GH_LOG")" -eq 2 ]
}

@test "a dead (old) lock is cleared so the refresh runs again; a fresh lock blocks it" {
  local repo; repo=$(_make_repo r-lock)
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  local f; f=$(ls "$HUD_CI_STATE_DIR"/*.json)
  jq '.fetched = 1' "$f" > "$f.t" && mv "$f.t" "$f"
  mkdir "${f%.json}.lock"
  _fake_gh '[{"status":"completed","conclusion":"failure","createdAt":"2026-10-27T03:00:00Z"}]'
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = "passing" ]
  [ ! -s "$GH_LOG" ]
  touch -t 202001010000 "${f%.json}.lock"
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = "failing" ]
}

@test "the default path never waits for gh: it answers ci null at once and fills the cache in the background" {
  local repo; repo=$(_make_repo r-async)
  _fake_gh "$OK_RUN"
  run bash -c "printf '{\"cwd\":\"%s\",\"ci\":{\"workflow\":\"w.yml\"}}' '$repo' | bash '$HUD' --json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ci <<<"$output")" = "null" ]
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ls "$HUD_CI_STATE_DIR"/*.json >/dev/null 2>&1 && break
    sleep 0.25
  done
  ls "$HUD_CI_STATE_DIR"/*.json >/dev/null
}

@test "repo is origin's name, else the folder name" {
  local repo; repo=$(_make_repo r-name)
  run _run_json "{\"cwd\":\"$repo\"}"
  [ "$(jq -r .repo <<<"$output")" = "r-name" ]
  git -C "$repo" remote add origin git@github.com:acme/widgets.git
  run _run_json "{\"cwd\":\"$repo\"}"
  [ "$(jq -r .repo <<<"$output")" = "widgets" ]
}

# ---- ETA (running run + history of completed successful runs) -----------------------------------

# $1 start, $2 end (ISO), $3 event -> one completed successful run
_ok() { printf '{"status":"completed","conclusion":"success","event":"%s","createdAt":"%s","startedAt":"%s","updatedAt":"%s"}' "$3" "$1" "$1" "$2"; }
_running() { printf '{"status":"in_progress","conclusion":null,"event":"%s","createdAt":"%s","startedAt":"%s","updatedAt":"%s"}' "$1" "$2" "$2" "$2"; }

_eta_of() { # $1 = JSON array for gh, $2 = ci config; prints .ci as JSON
  local repo; repo=$(_make_repo "r-eta-$RANDOM")
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/eta-$RANDOM"
  _fake_gh "$1"
  local cfg='{"workflow":"w.yml"}'
  _hud_ci "$repo" "${2:-$cfg}" | jq -c .ci
}

@test "eta: median of the last completed successful runs of the same event; fields are numbers" {
  local h="$(_running schedule 2026-10-26T03:00:00Z),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T05:00:00Z schedule),$(_ok 2026-10-23T03:00:00Z 2026-10-23T04:30:00Z schedule)"
  run _eta_of "[$h]"
  [ "$(jq -r .state <<<"$output")" = running ]
  # durations 3600, 7200, 5400 -> median 5400
  [ "$(jq -c '.eta | [.typ, .min, .max, .n]' <<<"$output")" = "[5400,3600,7200,3]" ]
  [ "$(jq -r '.eta.start' <<<"$output")" = "$(date -u -d 2026-10-26T03:00:00Z +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-10-26T03:00:00Z +%s)" ]
}

@test "eta: an even number of runs averages the two middle durations; only the 7 newest history runs count" {
  local h="$(_running schedule 2026-10-26T03:00:00Z)" d
  for d in 25 24 23 22 21 20 19; do h="$h,$(_ok 2026-10-${d}T03:00:00Z 2026-10-${d}T04:00:00Z schedule)"; done
  for d in 18 17 16; do h="$h,$(_ok 2026-10-${d}T03:00:00Z 2026-10-${d}T13:00:00Z schedule)"; done
  run _eta_of "[$h]"
  [ "$(jq -c '.eta | [.typ, .max, .n]' <<<"$output")" = "[3600,3600,7]" ]
  h="$(_running schedule 2026-10-26T03:00:00Z),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T05:00:00Z schedule),$(_ok 2026-10-23T03:00:00Z 2026-10-23T05:00:00Z schedule),$(_ok 2026-10-22T03:00:00Z 2026-10-22T06:00:00Z schedule)"
  run _eta_of "[$h]"
  [ "$(jq -r .eta.typ <<<"$output")" = 7200 ]
}

@test "eta: failed, cancelled and other in-progress runs are not history; fewer than 3 good runs means no eta" {
  local bad='{"status":"completed","conclusion":"failure","event":"schedule","createdAt":"2026-10-22T03:00:00Z","startedAt":"2026-10-22T03:00:00Z","updatedAt":"2026-10-22T09:00:00Z"}'
  local h="$(_running schedule 2026-10-26T03:00:00Z),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T04:00:00Z schedule),$bad,$(_running schedule 2026-10-21T03:00:00Z)"
  run _eta_of "[$h]"
  [ "$(jq -r .state <<<"$output")" = running ]
  [ "$(jq -r 'has("eta")' <<<"$output")" = false ]
}

@test "eta: no history at all (a lone running run) has no eta key" {
  run _eta_of "[$(_running schedule 2026-10-26T03:00:00Z)]"
  [ "$(jq -c . <<<"$output" | jq -r 'keys | join(",")')" = "at,state" ]
}

@test "eta: same event is preferred when it has >= 3 runs, else any event is used" {
  local h="$(_running schedule 2026-10-26T03:00:00Z)" d
  for d in 25 24 23; do h="$h,$(_ok 2026-10-${d}T03:00:00Z 2026-10-${d}T04:00:00Z schedule)"; done
  for d in 22 21 20; do h="$h,$(_ok 2026-10-${d}T03:00:00Z 2026-10-${d}T08:00:00Z workflow_dispatch)"; done
  run _eta_of "[$h]"
  [ "$(jq -c '.eta | [.typ, .n]' <<<"$output")" = "[3600,3]" ]
  # only two scheduled runs: falls back to every event (2 schedule + 3 dispatch)
  h="$(_running schedule 2026-10-26T03:00:00Z),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T04:00:00Z schedule)"
  for d in 22 21 20; do h="$h,$(_ok 2026-10-${d}T03:00:00Z 2026-10-${d}T08:00:00Z workflow_dispatch)"; done
  run _eta_of "[$h]"
  [ "$(jq -c '.eta | [.typ, .n]' <<<"$output")" = "[18000,5]" ]
}

@test "eta: only an in_progress newest run gets one (queued and passing runs do not)" {
  local hist="$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T04:00:00Z schedule),$(_ok 2026-10-23T03:00:00Z 2026-10-23T04:00:00Z schedule)"
  local newest
  for newest in '{"status":"queued","conclusion":null,"event":"schedule","createdAt":"2026-10-26T03:00:00Z","startedAt":"2026-10-26T03:00:00Z","updatedAt":"2026-10-26T03:00:00Z"}' "$(_ok 2026-10-26T03:00:00Z 2026-10-26T04:00:00Z schedule)"; do
    run _eta_of "[$newest,$hist]"
    [ "$(jq -r 'has("eta")' <<<"$output")" = false ]
  done
}

@test "eta: ci.eta false drops it from the output (the cache is shared); the ci block rejects nothing else" {
  local h="$(_running schedule 2026-10-26T03:00:00Z),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z schedule),$(_ok 2026-10-24T03:00:00Z 2026-10-24T04:00:00Z schedule),$(_ok 2026-10-23T03:00:00Z 2026-10-23T04:00:00Z schedule)"
  run _eta_of "[$h]" '{"workflow":"w.yml","eta":false}'
  [ "$(jq -r .state <<<"$output")" = running ]
  [ "$(jq -r 'has("eta")' <<<"$output")" = false ]
}

@test "eta: runs without startedAt or with garbage timestamps never produce an eta or an error" {
  run _eta_of '[{"status":"in_progress","event":"schedule","createdAt":"2026-10-26T03:00:00Z"},{"status":"completed","conclusion":"success","createdAt":"x","startedAt":"nope","updatedAt":5}]'
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = running ]
  [ "$(jq -r 'has("eta")' <<<"$output")" = false ]
}

@test "eta: an old cache file without an eta key still answers; a failed refresh drops a cached eta but keeps the state" {
  local repo; repo=$(_make_repo r-oldcache)
  _fake_gh "[$(_running schedule 2026-10-26T03:00:00Z)]"
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = running ]
  local f; f=$(ls "$HUD_CI_STATE_DIR"/*.json)
  jq 'has("eta")' "$f" | grep -q false
  # a cached eta, then a refresh that fails: state stays, eta goes
  jq '.fetched = 1 | .eta = {start: 1, typ: 2, min: 1, max: 3, n: 3}' "$f" > "$f.t" && mv "$f.t" "$f"
  _fake_gh FAIL
  run _hud_ci "$repo" '{"workflow":"w.yml"}'
  [ "$(jq -r .ci.state <<<"$output")" = running ]
  [ "$(jq -r '.ci | has("eta")' <<<"$output")" = false ]
}

@test "eta: runs with no event at all still count as the same event (null matches null)" {
  local h="$(_running schedule 2026-10-26T03:00:00Z | jq -c 'del(.event)'),$(_ok 2026-10-25T03:00:00Z 2026-10-25T04:00:00Z x | jq -c 'del(.event)'),$(_ok 2026-10-24T03:00:00Z 2026-10-24T04:00:00Z x | jq -c 'del(.event)'),$(_ok 2026-10-23T03:00:00Z 2026-10-23T04:00:00Z x | jq -c 'del(.event)')"
  run _eta_of "[$h]"
  [ "$(jq -c '.eta | [.typ, .n]' <<<"$output")" = "[3600,3]" ]
}
