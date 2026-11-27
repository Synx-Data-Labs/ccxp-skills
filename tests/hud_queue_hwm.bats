#!/usr/bin/env bats
# Tests for the queue high watermark (hud/scripts/hud-queue-hwm.sh): the git-history backfill, the
# local sample log (cap/rotation), the rolling window maxima (last month = 14 to 42 days ago, last week = 7 to 14 days ago, this week = the last 7 days, adjacent and never overlapping) and the hud-data.sh `queue.hwm` key. "origin" is a
# local bare repo; nothing here touches the network or the developer's state.

load test_helper
HWM="$REPO_ROOT/hud/scripts/hud-queue-hwm.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
DAY=86400

setup() {
  export HUD_BEHIND_STATE_DIR="$BATS_TEST_TMPDIR/hud-behind" # the behind fetch never touches ~/.claude
  isolate_claimant_state
  export HUD_NIGHTLY_OFF=1 HUD_TREND_OFF=1 # no real gh lookup or state under ~/.claude
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/no-such-remote"
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue"
  export HUD_QUEUE_FETCH_SYNC=1 HUD_HWM_SYNC=1
  export GIT_TERMINAL_PROMPT=0
  NOW=1800000000
  export HUD_HWM_NOW=$NOW
  R="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$R"
  git_identity "$R"
}

# $1 days ago, $2 number of queue lines -> a commit of dev/TODO/queue.md with that many tasks
_commit() {
  local ts=$((NOW - $1 * DAY)) n="$2" i
  mkdir -p "$R/dev/TODO"
  { echo "# Q"; for ((i = 1; i <= n; i++)); do printf -- '- [T20260101-%06d](T20260101-%06d-x.md): t%d\n' "$i" "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
  git -C "$R" add -A
  GIT_AUTHOR_DATE="$ts +0000" GIT_COMMITTER_DATE="$ts +0000" git -C "$R" commit -q -m "q$n"
}

_hwm() { bash -c "source '$HWM'; sl-queue-hwm '$R' '$1'"; }

# $1 seconds ago, $2 queue length -> a commit at that exact instant
_commit_s() {
  local ts=$((NOW - $1)) n="$2" i
  mkdir -p "$R/dev/TODO"
  { echo "# Q"; for ((i = 1; i <= n; i++)); do printf -- '- [T20260101-%06d](T20260101-%06d-x.md): t%d\n' "$i" "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
  git -C "$R" add -A
  GIT_AUTHOR_DATE="$ts +0000" GIT_COMMITTER_DATE="$ts +0000" git -C "$R" commit -q -m "q$n"
}

# $1 expected JSON, $2 current length: the three windows as compact JSON
_is() { run _hwm "$2"; [ "$status" -eq 0 ]; [ "$(jq -c . <<<"$output")" = "$1" ] || { echo "got: $output"; false; }; }

@test "a growing queue: the three numbers differ and rise (last month < last week < this week)" {
  _commit 40 10
  _commit 20 20
  _commit 10 30
  _commit 2 40
  _is '{"lm":20,"lw":30,"tw":40}' 40
}

@test "a shrinking queue: the three numbers fall (last month > last week > this week)" {
  _commit 40 50
  _commit 20 30
  _commit 10 20
  _commit 2 5
  _is '{"lm":50,"lw":30,"tw":20}' 5
}

@test "a flat queue: all three equal" {
  _commit 40 12
  _is '{"lm":12,"lw":12,"tw":12}' 12
}

@test "a window with no changes carries the length in force at its start" {
  _commit 50 10   # in force through days 42..14 and on to 3 days ago
  _commit 3 30
  _is '{"lm":10,"lw":10,"tw":30}' 30
}

@test "no history and no samples: this week is the current length, the older windows are null (shown as -)" {
  rm -rf "$R/.git"; git init -q -b main "$R"
  _is '{"lm":null,"lw":null,"tw":4}' 4
}

@test "first days of history: windows older than the first sample are null, a partly covered one shows what is known" {
  _commit 3 7
  _is '{"lm":null,"lw":null,"tw":7}' 7
  _commit 10 9   # an older commit: now last week has data, last month still none
  HUD_HWM_NOW=$((NOW + 1)) HUD_HWM_TTL=0 _is '{"lm":null,"lw":9,"tw":9}' 7
}

@test "this week edge: a sample exactly 7 days old is in force at the window start and counts for this week, not last week" {
  _commit_s $((20 * DAY)) 5
  _commit_s $((7 * DAY)) 90
  _commit_s $((7 * DAY - 1)) 10
  _is '{"lm":5,"lw":5,"tw":90}' 10
}

@test "this week edge: a peak one second older than 7 days, replaced exactly 7 days ago, belongs to last week only" {
  _commit_s $((7 * DAY + 1)) 90
  _commit_s $((7 * DAY)) 10
  _is '{"lm":null,"lw":90,"tw":10}' 10
}

@test "last week edge: a sample exactly 14 days old starts last week (not last month); one second older is last month's" {
  _commit_s $((30 * DAY)) 6
  _commit_s $((14 * DAY)) 80
  _commit_s $((14 * DAY - 1)) 20
  _is '{"lm":6,"lw":80,"tw":20}' 20
  rm -rf "$R/.git" "$HUD_QUEUE_STATE_DIR"; git init -q -b main "$R"; git_identity "$R"
  _commit_s $((30 * DAY)) 6
  _commit_s $((14 * DAY + 1)) 80
  _commit_s $((14 * DAY)) 20
  _is '{"lm":80,"lw":20,"tw":20}' 20
}

@test "last month edge: a sample exactly 42 days old is in force at the window start; one second older than that is replaced by the next sample" {
  _commit_s $((42 * DAY)) 70
  _commit_s $((42 * DAY - 1)) 15
  _is '{"lm":70,"lw":15,"tw":15}' 15
  rm -rf "$R/.git" "$HUD_QUEUE_STATE_DIR"; git init -q -b main "$R"; git_identity "$R"
  _commit_s $((42 * DAY + 1)) 70   # just past 42 days: replaced exactly at the start
  _commit_s $((42 * DAY)) 15
  _is '{"lm":15,"lw":15,"tw":15}' 15
}

@test "nothing older than 42 days leaks in: a peak 43 days ago that was replaced before day 42 is ignored" {
  _commit_s $((43 * DAY)) 99
  _commit_s $((42 * DAY + 5)) 3
  _is '{"lm":3,"lw":3,"tw":3}' 3
}

@test "samples dated in the future (clock set back) are ignored" {
  _commit 3 8
  mkdir -p "$HUD_QUEUE_STATE_DIR"
  printf '%s\t%s\n' $((NOW + 5 * DAY)) 500 > "$HUD_QUEUE_STATE_DIR/samples-$(bash -c "source '$HWM'; sl-hwm-key '$R'")"
  _is '{"lm":null,"lw":null,"tw":8}' 8
}

@test "DST and time zone do not matter: windows are elapsed seconds, the result is the same in UTC and in a DST zone across a changeover" {
  local dst=1773000000   # 2026-03-08 20:00 UTC, the US spring-forward day
  NOW=$((dst + 6 * DAY)); export HUD_HWM_NOW=$NOW
  _commit_s $((42 * DAY)) 70
  _commit_s $((14 * DAY)) 50
  _commit_s $((7 * DAY)) 30
  _commit_s $((7 * DAY - 1)) 20
  local a b
  a=$(TZ=UTC _hwm 20); b=$(TZ=America/New_York _hwm 20)
  [ "$a" = "$b" ]
  [ "$(jq -c . <<<"$a")" = '{"lm":70,"lw":50,"tw":30}' ]
  # and the same for the fall-back changeover
  rm -rf "$R/.git" "$HUD_QUEUE_STATE_DIR"; git init -q -b main "$R"; git_identity "$R"
  NOW=$((1793000000 + 6 * DAY)); export HUD_HWM_NOW=$NOW   # 2026-10-26 + 6d, across 2026-11-01
  _commit_s $((42 * DAY)) 70
  _commit_s $((14 * DAY)) 50
  _commit_s $((7 * DAY)) 30
  _commit_s $((7 * DAY - 1)) 20
  a=$(TZ=UTC _hwm 20); b=$(TZ=Europe/Berlin _hwm 20)
  [ "$a" = "$b" ]
  [ "$(jq -c . <<<"$a")" = '{"lm":70,"lw":50,"tw":30}' ]
}

@test "there is no lifetime maximum: a peak older than 180 days is forgotten, and no max file is written" {
  _commit 400 99
  _commit 200 8
  run _hwm 8
  [ "$(jq -c . <<<"$output")" = '{"lm":8,"lw":8,"tw":8}' ]
  [ -z "$(ls "$HUD_QUEUE_STATE_DIR"/max-* 2>/dev/null)" ]
}

@test "current length counts for this week" {
  _commit 5 8
  run _hwm 30
  [ "$(jq -c . <<<"$output")" = '{"lm":null,"lw":null,"tw":30}' ]
  # a later poll with a lower value keeps this week's peak (live sample)
  run _hwm 6
  [ "$(jq -c . <<<"$output")" = '{"lm":null,"lw":null,"tw":30}' ]
}

@test "samples between commits are caught: a peak that never reached a commit moves from this week to last week to last month and is then forgotten" {
  _commit 20 5
  HUD_HWM_NOW=$((NOW - 2 * DAY)) run _hwm 25
  HUD_HWM_NOW=$((NOW - 1 * DAY)) run _hwm 5
  run _hwm 5
  [ "$(jq -c . <<<"$output")" = '{"lm":5,"lw":5,"tw":25}' ]
  HUD_HWM_NOW=$((NOW + 6 * DAY + DAY / 2)) run _hwm 5   # the 25 is now 8.5 days old: last week
  [ "$(jq -c . <<<"$output")" = '{"lm":5,"lw":25,"tw":5}' ]
  HUD_HWM_NOW=$((NOW + 40 * DAY)) run _hwm 5            # 42 days old: in force at the start of last month
  [ "$(jq -c . <<<"$output")" = '{"lm":25,"lw":5,"tw":5}' ]
  HUD_HWM_NOW=$((NOW + 200 * DAY)) run _hwm 5           # out of every window
  [ "$(jq -c . <<<"$output")" = '{"lm":5,"lw":5,"tw":5}' ]
}

@test "a repo without a queue file: backfill is empty, nothing is written but state, and hud-data omits the queue (no watermark)" {
  echo hi > "$R/a"; git -C "$R" add -A; git -C "$R" commit -q -m a
  run bash -c "source '$HWM'; sl-hwm-backfill '$R'"
  [ "$status" -eq 0 ]
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.queue'"
  [ "$output" = null ]
  [ -z "$(git -C "$R" status --porcelain)" ]
}

@test "non-numeric current length yields nothing and writes no sample" {
  run _hwm "abc"
  [ -z "$output" ]
  [ -z "$(ls "$HUD_QUEUE_STATE_DIR"/samples-* 2>/dev/null)" ]
}

@test "sample log: only changes are appended, and past the cap the oldest half goes when everything is inside the 180d window" {
  export HUD_HWM_SAMPLE_CAP=10
  local i
  for i in 100 1 2 3 1 2 3 1 2 3 1 2 3 1 2 3; do HUD_HWM_NOW=$((NOW + i)) _hwm "$i" >/dev/null; done
  local f; f=$(ls "$HUD_QUEUE_STATE_DIR"/samples-*)
  [ "$(wc -l < "$f")" -le 10 ]
  [ "$(wc -l < "$f")" -ge 5 ]
  # same value again: no new line
  local before; before=$(wc -l < "$f")
  _hwm 3 >/dev/null; _hwm 3 >/dev/null
  [ "$(wc -l < "$f")" -eq "$before" ]
  # the early 100 was inside the window but the burst overflowed the cap: it rotated away
  ! grep -q '	100$' "$f"
}

@test "sample log rotation drops what is older than 180 days first, keeping the value in force at the window start" {
  export HUD_HWM_SAMPLE_CAP=5
  local pair
  for pair in "300 90" "250 2" "200 3" "10 4" "9 5" "8 6"; do
    set -- $pair
    HUD_HWM_NOW=$((NOW - $1 * DAY)) _hwm "$2" >/dev/null
  done
  local f; f=$(ls "$HUD_QUEUE_STATE_DIR"/samples-*)
  [ "$(wc -l < "$f")" -eq 4 ]
  [ "$(head -n 1 "$f")" = "$((NOW - 200 * DAY))	3" ]
  ! grep -q '	90$' "$f"
  # the carried-in 3 still counts for the window start; the 6 is current
  run _hwm 6
  [ "$(jq -c . <<<"$output")" = '{"lm":3,"lw":6,"tw":6}' ]
}

@test "incremental backfill picks up new commits; a rebuilt history after a force-push replaces the old series" {
  _commit 50 30
  _commit 40 5
  run _hwm 5
  [ "$(jq .lm <<<"$output")" -eq 30 ]
  _commit 2 12
  HUD_HWM_NOW=$((NOW + 4000)) run _hwm 12   # past the TTL: the stamp allows a new pass
  [ "$(jq -c . <<<"$output")" = '{"lm":30,"lw":5,"tw":12}' ]
  # rewrite history: the old tip is no longer an ancestor, full rebuild
  git -C "$R" reset -q --hard HEAD~2
  _commit 1 7
  HUD_HWM_NOW=$((NOW + 9000)) run _hwm 7
  [ "$(jq .lm <<<"$output")" -eq 30 ]
  ! grep -q '	12$' "$HUD_QUEUE_STATE_DIR"/hist-[0-9]*   # the rebuilt series no longer has the dropped commit
}

@test "state is keyed by repo root: two repos do not share a series" {
  _commit 3 18
  local R2="$BATS_TEST_TMPDIR/repo2"
  git init -q -b main "$R2"; git_identity "$R2"
  mkdir -p "$R2/dev/TODO"; printf -- '- [T20260101-000001](a.md): a\n' > "$R2/dev/TODO/queue.md"
  git -C "$R2" add -A; git -C "$R2" commit -q -m a
  run _hwm 18
  [ "$(jq .tw <<<"$output")" -eq 18 ]
  run bash -c "source '$HWM'; sl-queue-hwm '$R2' 1"
  [ "$(jq .tw <<<"$output")" -eq 1 ]
}

@test "hud-data.sh adds queue.hwm next to the breakdown and keeps its own keys" {
  _commit 3 4
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.queue | {total, hwm}'"
  [ "$(jq -r .total <<<"$output")" -eq 4 ]
  [ "$(jq -c .hwm <<<"$output")" = '{"lm":null,"lw":null,"tw":4}' ]
}

@test "the render path never fetches or blocks: with HUD_HWM_SYNC unset the backfill is detached and the call returns at once" {
  _commit 3 4
  unset HUD_HWM_SYNC
  run bash -c "source '$HWM'; sl-queue-hwm '$R' 4"
  [ "$status" -eq 0 ]
  [ "$(jq .tw <<<"$output")" -eq 4 ]
}
