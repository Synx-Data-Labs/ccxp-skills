#!/usr/bin/env bats
# Tests for the nightly strip and red-day count of the ccxp-hud data helper (hud/scripts/hud-nightly.sh).
# A fake `gh` on PATH answers from a fixture file and logs its argv; nothing here talks to the
# network or the developer's real state.

load test_helper
NIGHTLY="$REPO_ROOT/hud/scripts/hud-nightly.sh"
# 2026-11-05 12:00:00 UTC
NOW=1793880000

setup() {
  export HUD_NIGHTLY_STATE_DIR="$BATS_TEST_TMPDIR/hud-nightly" HUD_NIGHTLY_SYNC=1 HUD_NIGHTLY_NOW="$NOW"
  unset HUD_NIGHTLY_OFF HUD_NIGHTLY_TTL
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_FIXTURE="$BATS_TEST_TMPDIR/runs.json"
  cat > "$BATS_TEST_TMPDIR/fakebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
cat "$GH_FIXTURE"
GH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

# $1 date (YYYY-MM-DD) $2 conclusion [$3 minute] [$4 status] [$5 event] -> one run object
_run() { printf '{"createdAt":"%sT05:%s:00Z","conclusion":"%s","status":"%s","event":"%s"}' "$1" "${3:-01}" "$2" "${4:-completed}" "${5:-schedule}"; }
_count() { bash -c "source '$NIGHTLY'; sl-nightly-count $NOW"; }

@test "count: red days over 30 days; the strip is the last 7 UTC days, oldest to newest" {
  run _count <<<"[$(_run 2026-11-05 failure),$(_run 2026-11-04 success),$(_run 2026-11-03 success),$(_run 2026-10-20 failure),$(_run 2026-10-19 success)]"
  [ "$status" -eq 0 ]
  [ "$output" = '{"red":2,"strip":"....++-"}' ]
}

@test "count: a missing day shows as a dot inside the strip" {
  run _count <<<"[$(_run 2026-11-05 success),$(_run 2026-11-04 failure),$(_run 2026-11-02 success),$(_run 2026-11-01 success),$(_run 2026-10-30 success)]"
  [ "$output" = '{"red":1,"strip":"+.++.-+"}' ]
}

@test "count: strip order is oldest first, newest last" {
  run _count <<<"[$(_run 2026-10-30 failure),$(_run 2026-10-31 success),$(_run 2026-11-05 success)]"
  [ "$output" = '{"red":1,"strip":"-+....+"}' ]
}

@test "count: failure then success on the same day is red (the day was red at some moment)" {
  run _count <<<"[$(_run 2026-11-05 failure 00),$(_run 2026-11-05 success 30),$(_run 2026-11-04 success)]"
  [ "$output" = '{"red":1,"strip":".....+-"}' ]
}

@test "count: only the red count is reported (no green count); several successes in a day are one green day; timed_out is red" {
  run _count <<<"[$(_run 2026-11-04 success 00),$(_run 2026-11-04 success 30),$(_run 2026-11-03 timed_out)]"
  [ "$output" = '{"red":1,"strip":"....-+."}' ]
  [[ "$output" != *green* ]]
}

@test "count: cancelled, skipped, in-progress and non-scheduled runs are not counted" {
  run _count <<<"[$(_run 2026-11-04 cancelled),$(_run 2026-11-03 '' 01 in_progress),$(_run 2026-11-02 skipped),$(_run 2026-11-01 failure 01 completed workflow_dispatch),$(_run 2026-10-31 success)]"
  [ "$output" = '{"red":0,"strip":".+....."}' ]
}

@test "count: only cancelled runs, an empty list or garbage prints nothing" {
  run _count <<<"[$(_run 2026-11-04 cancelled)]"
  [ -z "$output" ]
  run _count <<<'[]'
  [ -z "$output" ]
  run _count <<<'not json'
  [ -z "$output" ]
}

@test "count: the 30-day window is today plus the 29 days before (UTC); older and future runs are left out" {
  run _count <<<"[$(_run 2026-10-07 failure),$(_run 2026-10-06 failure),$(_run 2026-11-06 failure),$(_run 2026-11-05 success)]"
  [ "$output" = '{"red":1,"strip":"......+"}' ]
}

@test "json: a refresh asks gh for the orchestrator's scheduled runs, caches the counts, and the cell is silent when off" {
  printf '[%s,%s]' "$(_run 2026-11-05 failure)" "$(_run 2026-11-04 success)" > "$GH_FIXTURE"
  run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = '{"red":1,"strip":".....+-"}' ]
  grep -q -- '--repo Synx-Data-Labs/synxdb-build-pipeline --workflow Nightly Orchestrator --event schedule' "$GH_LOG"
  HUD_NIGHTLY_OFF=1 run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = 'null' ]
}

@test "json: cache hit inside the TTL makes no gh call; after the TTL it refreshes" {
  printf '[%s]' "$(_run 2026-11-05 success)" > "$GH_FIXTURE"
  bash -c "source '$NIGHTLY'; hud-nightly-json" >/dev/null
  bash -c "source '$NIGHTLY'; hud-nightly-json" >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 1 ]
  HUD_NIGHTLY_NOW=$((NOW + 1000)) bash -c "source '$NIGHTLY'; hud-nightly-json" >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 1 ]
  HUD_NIGHTLY_NOW=$((NOW + 1900)) bash -c "source '$NIGHTLY'; hud-nightly-json" >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 2 ]
}

@test "json: gh failing keeps the old answer and is not retried every poll; no cache means null; no gh means null" {
  GH_FAIL=1 run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$status" -eq 0 ]
  [ "$output" = 'null' ]
  printf '[%s]' "$(_run 2026-11-05 success)" > "$GH_FIXTURE"
  HUD_NIGHTLY_NOW=$((NOW + 4000)) run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = '{"red":0,"strip":"......+"}' ]
  GH_FAIL=1 HUD_NIGHTLY_NOW=$((NOW + 8000)) run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = '{"red":0,"strip":"......+"}' ]
  # no gh on PATH: a bin dir with only the tools the helper needs (gh may live in /usr/bin)
  mkdir -p "$BATS_TEST_TMPDIR/nogh"
  for t in jq date cksum cut dirname mkdir find head cat mktemp mv rm printf rmdir; do ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/nogh/$t" 2>/dev/null || true; done
  HUD_NIGHTLY_STATE_DIR="$BATS_TEST_TMPDIR/other" PATH="$BATS_TEST_TMPDIR/nogh" run "$BASH" -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = 'null' ]
}

@test "json: an unreadable cache file is replaced, not retried on every poll" {
  mkdir -p "$HUD_NIGHTLY_STATE_DIR"
  f=$(bash -c "source '$NIGHTLY'; printf '%s' \"\$(hni-state-dir)/\$(printf '%s|%s' \"\$HNI_REPO_DEFAULT\" \"\$HNI_WORKFLOW_DEFAULT\" | cksum | cut -d' ' -f1).json\""
  )
  printf 'garbage' > "$f"
  GH_FAIL=1 run bash -c "source '$NIGHTLY'; hud-nightly-json"
  [ "$output" = 'null' ]
  jq -e '.fetched > 0' "$f"
  bash -c "source '$NIGHTLY'; hud-nightly-json" >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 1 ]
}

@test "json: reaches hud-data.sh as .nightly" {
  printf '[%s]' "$(_run 2026-11-05 success)" > "$GH_FIXTURE"
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_HWM_SYNC=1 HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci" HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version" HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/none" CCXP_HUD_CACHE_DIR="$BATS_TEST_TMPDIR/hud-cache" LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/li" CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  run bash -c "echo '{\"cwd\":\"$BATS_TEST_TMPDIR\"}' | bash '$REPO_ROOT/hud/scripts/hud-data.sh' | jq -c .nightly"
  [ "$output" = '{"red":0,"strip":"......+"}' ]
}
