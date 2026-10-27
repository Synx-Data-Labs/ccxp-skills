#!/usr/bin/env bats
# Tests for the CI segment of the ccxp-hud data helper (hud/scripts/hud-ci.sh,
# reached through hud-data.sh --json). A fake `gh` on PATH answers from a fixture file and
# logs its argv; nothing here talks to the network or the developer's real state.

load test_helper
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
CI="$REPO_ROOT/hud/scripts/hud-ci.sh"

setup() {
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
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
  grep -qF 'run list --workflow w.yml --branch trunk --repo acme/widgets --limit 1 --json status,conclusion,createdAt' "$GH_LOG"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/a2"
  _fake_gh "$OK_RUN"
  run _hud_ci "$repo" '{"workflow":"w.yml","branch":"release/4.8"}'
  grep -qF 'run list --workflow w.yml --branch release/4.8 --limit 1' "$GH_LOG"
}

@test "a bad ci config (metacharacters, spaces, bad repo, wrong types) is ignored; gh never runs" {
  local repo bad; repo=$(_make_repo r-bad)
  _fake_gh "$OK_RUN"
  for bad in '{"workflow":"a b.yml"}' '{"workflow":"x;touch pwn"}' '{"workflow":"$(id)"}' '{"workflow":"w.yml","repo":"no-slash"}' '{"workflow":"w.yml","branch":"-x"}' '{"workflow":5}' '"str"' '[]'; do
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
