#!/usr/bin/env bats
# Tests for the weekly trend one-liners (hud/scripts/hud-trend.sh, T20261126-122285): Monday-aligned UTC buckets, the queue
# series from git history of dev/TODO/queue.md, the support series from issue JSON fixtures, the autopilot series from a
# history jsonl, the weekly holds snapshot, the three views, the cached HUD answer and the hud-data.sh `trend` key.
# A fake `gh` on PATH logs its argv; nothing here talks to the network or the developer's real state.
#
# Fixed clock: Thursday 2026-11-26 12:00 UTC. Buckets (Monday 00:00 UTC): 10-19 10-26 11-02 11-09 11-16 and the current
# partial week 11-23.

load test_helper
TREND="$REPO_ROOT/hud/scripts/hud-trend.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
NOW=1795694400
MON_1123=1795392000
DAY=86400

setup() {
  export HUD_BEHIND_STATE_DIR="$BATS_TEST_TMPDIR/hud-behind"
  isolate_claimant_state
  export HUD_NIGHTLY_OFF=1 HUD_ISSUES_TTL=999999
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/no-such-remote"
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_QUEUE_FETCH_SYNC=1 HUD_HWM_SYNC=1 HUD_HWM_NOW=$NOW
  export HUD_TREND_STATE_DIR="$BATS_TEST_TMPDIR/hud-trend" HUD_TREND_NOW=$NOW HUD_TREND_SYNC=1
  export GIT_TERMINAL_PROMPT=0 CCXP_PROFILE_DIR="$BATS_TEST_TMPDIR/profile"
  unset HUD_TREND_OFF HUD_TREND_TTL HUD_TREND_SUPPORT_FILE HUD_TREND_SUPPORT_REPO HUD_TREND_SNAPSHOT AUTOPILOT_HISTORY_FILE
  R="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$R"
  git_identity "$R"
  mkdir -p "$BATS_TEST_TMPDIR/fakebin" "$R/dev"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_FIXTURE="$BATS_TEST_TMPDIR/issues.json"
  cat > "$BATS_TEST_TMPDIR/fakebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
cat "$GH_FIXTURE"
GH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

# $1 epoch, $2 number of tasks (ids 1..n, in order) -> a commit of dev/TODO/queue.md at that instant
_commit() {
  local i
  mkdir -p "$R/dev/TODO"
  { echo "# Q"; for ((i = 1; i <= $2; i++)); do printf -- '- [T20260101-%06d](T20260101-%06d-x.md): t%d\n' "$i" "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
  git -C "$R" add -A
  GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" git -C "$R" commit -q -m "q$2"
}

# The queue fixture: 10 tasks in week 10-19, 14 in 10-26, a reorder only in 11-02, back to 11 in 11-09, nothing in 11-16, 15 now.
_queue_history() {
  _commit $((MON_1123 - 34 * DAY + DAY)) 10 # 10-20
  _commit $((MON_1123 - 24 * DAY)) 14 # 10-30
  # a reorder: the same 14 ids, reversed: nets to zero added and zero closed
  { echo "# Q"; for ((i = 14; i >= 1; i--)); do printf -- '- [T20260101-%06d](T20260101-%06d-x.md): t%d\n' "$i" "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
  git -C "$R" add -A
  GIT_AUTHOR_DATE="$((MON_1123 - 21 * DAY + 2 * DAY)) +0000" GIT_COMMITTER_DATE="$((MON_1123 - 21 * DAY + 2 * DAY)) +0000" git -C "$R" commit -q -m reorder # 11-04
  _commit $((MON_1123 - 14 * DAY + DAY)) 11 # 11-10
  _commit $((MON_1123 + DAY)) 15 # 11-24
}

_support_fixture() {
  cat > "$GH_FIXTURE" <<'JSON'
[{"createdAt":"2026-10-15T09:00:00Z","closedAt":"2026-11-03T09:00:00Z"},
 {"createdAt":"2026-10-22T09:00:00Z","closedAt":null},
 {"createdAt":"2026-11-10T09:00:00Z","closedAt":"2026-11-24T09:00:00Z"},
 {"createdAt":"2026-11-24T10:00:00Z","closedAt":null}]
JSON
}

_ap_history() {
  cat > "$R/dev/.autopilot-history.jsonl" <<'JSONL'
{"ts":"2026-10-28T10:00:00Z","outcome":"progress","merged":2,"task":"T1"}
{"ts":"2026-11-24T10:00:00Z","outcome":"progress","merged":1,"task":"T2"}
{"ts":"2026-11-25T10:00:00Z","outcome":"progress","merged":2,"task":"T3"}
{"ts":"2026-11-25T11:00:00Z","outcome":"capped","merged":0}
{"ts":"2026-11-25T12:00:00Z","outcome":"visit","merged":0}
not json at all
JSONL
  echo '{"holds":{"T1":{},"T2":{}}}' > "$R/dev/.autopilot-state.json"
}

_data() { bash -c "source '$TREND'; ht-data '$R' 'acme/support' ''"; }
_cli() { bash "$TREND" --root "$R" --support acme/support "$@"; }

# ---- buckets ----

@test "bounds: six Mondays, the last one is this week's, from a Thursday" {
  run bash -c "source '$TREND'; ht-bounds $NOW"
  [ "$status" -eq 0 ]
  [ "$output" = "1792368000 1792972800 1793577600 1794182400 1794787200 1795392000" ]
}

@test "bounds: Monday 00:00 sharp and Sunday 23:59:59 land in the right week" {
  run bash -c "source '$TREND'; ht-bounds $MON_1123 1"
  [ "$output" = "1794787200 1795392000" ]
  run bash -c "source '$TREND'; ht-bounds $((MON_1123 - 1)) 1"
  [ "$output" = "1794182400 1794787200" ]
}

# ---- queue ----

@test "queue: stock at each Monday and flow per week from git history; a reorder nets to zero" {
  _queue_history
  run bash -c "source '$TREND'; ht-queue-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -eq 0 ]
  [ "$output" = '{"stock":[10,14,14,11,11,15],"in":[10,4,0,0,0,4],"out":[0,0,0,3,0,0]}' ] || { echo "got: $output"; false; }
}

@test "queue: commits after the clock are ignored" {
  _queue_history
  _commit $((NOW + 3 * DAY)) 99
  run bash -c "source '$TREND'; ht-queue-series '$R' $NOW \"\$(ht-bounds $NOW)\" | jq -c '.stock[5]'"
  [ "$output" = "15" ]
}

@test "queue: a queue file with no tasks reads as zeros, not as missing" {
  _commit $((MON_1123 - 3 * DAY)) 0
  run bash -c "source '$TREND'; ht-queue-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -eq 0 ]
  [ "$output" = '{"stock":[0,0,0,0,0,0],"in":[0,0,0,0,0,0],"out":[0,0,0,0,0,0]}' ]
}

@test "queue: no queue file in history is a failure, not a crash" {
  echo x > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m init
  run bash -c "source '$TREND'; ht-queue-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---- support ----

@test "support: open at each Monday, opened and closed per week" {
  _support_fixture
  run bash -c "source '$TREND'; ht-support-series $NOW \"\$(ht-bounds $NOW)\" < '$GH_FIXTURE'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"stock":[2,2,1,2,2,2],"opened":[1,0,0,1,0,1],"delivered":[0,0,1,0,0,1]}' ]
}

@test "support: an empty issue list is zeros; malformed input prints nothing" {
  run bash -c "source '$TREND'; echo '[]' | ht-support-series $NOW \"\$(ht-bounds $NOW)\""
  [ "$output" = '{"stock":[0,0,0,0,0,0],"opened":[0,0,0,0,0,0],"delivered":[0,0,0,0,0,0]}' ]
  run bash -c "source '$TREND'; echo '{\"message\":\"Not Found\"}' | ht-support-series $NOW \"\$(ht-bounds $NOW)\""
  [ -z "$output" ]
  run bash -c "source '$TREND'; echo 'garbage' | ht-support-series $NOW \"\$(ht-bounds $NOW)\""
  [ -z "$output" ]
}

# ---- autopilot ----

@test "ap: merged and cycles per week; capped ticks, visit lines and junk are not cycles" {
  _ap_history
  run bash -c "source '$TREND'; ht-ap-series '$R/dev/.autopilot-history.jsonl' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -eq 0 ]
  [ "$output" = '{"merged":[0,2,0,0,0,3],"cycles":[0,1,0,0,0,2]}' ]
}

@test "ap: a missing history file is a failure" {
  run bash -c "source '$TREND'; ht-ap-series '$R/nope.jsonl' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -ne 0 ]
}

@test "holds: the weekly snapshot is appended once per week, the current week shows the live count" {
  _ap_history
  mkdir -p "$HUD_TREND_STATE_DIR"
  key=$(printf '%s' "$R" | cksum | cut -d' ' -f1)
  printf '{"week":"2026-11-16","holds":1}\n' > "$HUD_TREND_STATE_DIR/holds-$key.jsonl"
  run bash -c "source '$TREND'; ht-holds-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$output" = '{"live":2,"series":[null,null,null,null,1,2]}' ]
  run bash -c "source '$TREND'; ht-holds-series '$R' $NOW \"\$(ht-bounds $NOW)\" >/dev/null; ht-holds-series '$R' $NOW \"\$(ht-bounds $NOW)\" >/dev/null"
  [ "$(grep -c '2026-11-23' "$HUD_TREND_STATE_DIR/holds-$key.jsonl")" -eq 1 ]
  [ "$(wc -l < "$HUD_TREND_STATE_DIR/holds-$key.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "holds: HUD_TREND_SNAPSHOT=0 writes nothing" {
  _ap_history
  HUD_TREND_SNAPSHOT=0 run bash -c "source '$TREND'; ht-holds-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$output" = '{"live":2,"series":[null,null,null,null,null,2]}' ]
  [ -z "$(ls "$HUD_TREND_STATE_DIR" 2>/dev/null)" ]
}

@test "holds: no state file means no holds series" {
  run bash -c "source '$TREND'; ht-holds-series '$R' $NOW \"\$(ht-bounds $NOW)\""
  [ "$status" -ne 0 ]
}

# ---- the views ----

@test "line: all three domains, the stock plus flow, the sparkline scaled per line, the partial week marked" {
  _queue_history; _support_fixture; _ap_history
  key=$(printf '%s' "$R" | cksum | cut -d' ' -f1)
  mkdir -p "$HUD_TREND_STATE_DIR"
  printf '{"week":"2026-11-16","holds":1}\n' > "$HUD_TREND_STATE_DIR/holds-$key.jsonl"
  HUD_TREND_SUPPORT_FILE="$GH_FIXTURE" run _cli
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Queue     15 ▆██▆▆█*  +4 vs last wk   (in 4 / out 0)" ] || { echo "got: ${lines[0]}"; false; }
  [ "${lines[1]}" = "Support    2 ██▅███*  ±0 vs last wk   (opened 1 / delivered 1)" ] || { echo "got: ${lines[1]}"; false; }
  [ "${lines[2]}" = "AP         3 ▁▆▁▁▁█*  merged/wk       (holds 2 ····▅█* up)" ] || { echo "got: ${lines[2]}"; false; }
  [ "${#lines[@]}" -eq 3 ]
}

@test "line: a missing source prints a dash for that domain only" {
  _queue_history
  run _cli
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Queue "* ]]
  [ "${lines[1]}" = "Support    -  (no data)" ]
  [ "${lines[2]}" = "AP         -  (no data)" ]
}

@test "line: nothing at all prints three dashes and still succeeds" {
  echo x > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m init
  run _cli
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Queue      -  (no data)" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "line: gh failing leaves support as a dash and the rest intact" {
  _queue_history; _ap_history
  GH_FAIL=1 run _cli
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "Support    -  (no data)" ]
  [[ "${lines[0]}" == "Queue "* ]]
  [[ "${lines[2]}" == "AP "* ]]
}

@test "table: a header, one row per week, the current week marked with *" {
  _queue_history; _support_fixture; _ap_history
  HUD_TREND_SUPPORT_FILE="$GH_FIXTURE" run _cli --table
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 7 ]
  [[ "${lines[0]}" == week*queue*support*"ap merged"*holds ]]
  [[ "${lines[1]}" == 10-19* ]]
  [[ "${lines[6]}" == 11-23\** ]]
  [[ "${lines[4]}" =~ 11-09[[:space:]]+11[[:space:]]+0[[:space:]]+3 ]]
}

@test "hist: bars scaled per series, a zero week has no bar" {
  _queue_history
  run _cli --hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"Queue: tasks at the end of each week"* ]]
  [[ "$output" == *"11-23* "*" 15"* ]]
  [[ "$output" == *"Support: no data"* ]]
  [[ "$output" == *"AP: no data"* ]]
  closed_block=$(printf '%s\n' "$output" | sed -n '/Queue: closed per week/,/Support:/p')
  [[ "$closed_block" == *"  10-19   0"* ]]
}

@test "json: the data object parses and carries the weeks" {
  _queue_history
  run _cli --json
  [ "$status" -eq 0 ]
  [ "$(jq -c '.weeks' <<<"$output")" = '["10-19","10-26","11-02","11-09","11-16","11-23"]' ]
  [ "$(jq -c '.support' <<<"$output")" = "null" ]
}

@test "cli: bad arguments exit 2" {
  run bash "$TREND" --nope
  [ "$status" -eq 2 ]
  run bash "$TREND" --weeks 0
  [ "$status" -eq 2 ]
}

@test "support repo: taken from the project HUD config when no flag is given" {
  _queue_history; _support_fixture
  mkdir -p "$R/.claude"
  echo '{"issues":{"repo":"acme/from-config"}}' > "$R/.claude/ccxp-hud.json"
  run bash "$TREND" --root "$R" --line
  [ "$status" -eq 0 ]
  grep -q -- '--repo acme/from-config' "$GH_LOG"
  [[ "${lines[1]}" == "Support "* ]] && [[ "${lines[1]}" != *"no data"* ]]
}

# ---- the cached HUD answer ----

@test "hud-trend-json: sync refresh answers with the rows; a second call inside the TTL does not call gh again" {
  _queue_history; _support_fixture; _ap_history
  run bash -c "source '$TREND'; hud-trend-json '$R' acme/support"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.rows | map(.key) | join(",")' <<<"$output")" = "queue,support,ap" ]
  [[ "$(jq -r '.rows[0].short' <<<"$output")" == "Queue 15 "* ]]
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" -eq 1 ]
  run bash -c "source '$TREND'; hud-trend-json '$R' acme/support >/dev/null"
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" -eq 1 ]
}

@test "hud-trend-json: after the TTL it refreshes once more" {
  _queue_history; _support_fixture
  run bash -c "source '$TREND'; hud-trend-json '$R' acme/support >/dev/null; HUD_TREND_NOW=$((NOW + 700)) hud-trend-json '$R' acme/support >/dev/null"
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" -eq 2 ]
}

@test "hud-trend-json: without the sync hook the first call returns at once (null) and the refresh runs detached" {
  _queue_history
  unset HUD_TREND_SYNC
  run bash -c "source '$TREND'; hud-trend-json '$R'"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    out=$(bash -c "source '$TREND'; hud-trend-json '$R'")
    [ "$out" != "null" ] && break
    sleep 0.5
  done
  [[ "$out" == *'"key":"queue"'* ]]
}

@test "hud-trend-json: HUD_TREND_OFF=1 is null and touches nothing" {
  _queue_history
  HUD_TREND_OFF=1 run bash -c "source '$TREND'; hud-trend-json '$R'"
  [ "$output" = "null" ]
  [ ! -e "$HUD_TREND_STATE_DIR" ]
}

@test "hud-trend-json: a repo with no source at all is null (the band draws nothing)" {
  echo x > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m init
  run bash -c "source '$TREND'; hud-trend-json '$R'"
  [ "$output" = "null" ]
}

@test "hud-trend-json: a tampered cache cannot inject keys or long text" {
  _queue_history
  bash -c "source '$TREND'; hud-trend-json '$R' >/dev/null"
  f=$(ls "$HUD_TREND_STATE_DIR"/*.json)
  long=$(printf 'x%.0s' $(seq 1 300))
  jq -c --arg long "$long" '.rows += [{key:"evil",short:"a",full:"b"},{key:"ap",short:$long,full:"c"}] | .rows[0].extra = "zzz"' "$f" > "$f.new" && mv "$f.new" "$f"
  run bash -c "source '$TREND'; hud-trend-json '$R'"
  [ "$(jq -c '[.rows[].key]' <<<"$output")" = '["queue","ap"]' ]
  [ "$(jq '.rows[0] | keys | length' <<<"$output")" -eq 4 ]
  [ "$(jq '.rows[1].short | length' <<<"$output")" -le 80 ]
}

# ---- hud-data.sh ----

@test "hud-data: the trend key carries the rows; show_trend false switches it off" {
  _queue_history
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.trend.rows | map(.key)'"
  [ "$output" = '["queue"]' ]
  run bash -c "echo '{\"cwd\":\"$R\",\"show_trend\":false}' | bash '$HUD' | jq -c '.trend'"
  [ "$output" = "null" ]
}

@test "hud-data: the issues repo of the HUD config feeds the support line" {
  _queue_history; _support_fixture
  run bash -c "echo '{\"cwd\":\"$R\",\"issues\":{\"repo\":\"acme/support\"}}' | bash '$HUD' | jq -r '.trend.rows | map(.key) | join(\",\")'"
  [ "$output" = "queue,support" ]
}

@test "hud-data: a repo with no queue, support or autopilot history has trend null" {
  echo x > "$R/f"; git -C "$R" add -A; git -C "$R" commit -q -m init
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.trend'"
  [ "$output" = "null" ]
}
