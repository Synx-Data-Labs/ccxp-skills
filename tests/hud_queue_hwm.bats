#!/usr/bin/env bats
# Tests for the queue high watermark (hud/scripts/hud-queue-hwm.sh): the git-history backfill, the
# local sample log (cap/rotation), the window maxima (180d / 30d / 7d) and the hud-data.sh `queue.hwm` key. "origin" is a
# local bare repo; nothing here touches the network or the developer's state.

load test_helper
HWM="$REPO_ROOT/hud/scripts/hud-queue-hwm.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
DAY=86400

setup() {
  isolate_claimant_state
  export HUD_NIGHTLY_OFF=1 # no real gh lookup or state under ~/.claude
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

@test "window maxima from git history: 180d, 30d and 7d from the first run, carrying the value in force at the window start" {
  _commit 250 70   # older than 180 days: outside every window
  _commit 200 10   # in force when the 180d window opens
  _commit 150 40   # 180d peak
  _commit 80 12
  _commit 40 20    # 40 days ago: 20 until the next commit
  _commit 3 15     # last week: the 20 stayed in force until here, so it still counts for 7d
  _commit 1 9
  run _hwm 9
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"d180":40,"d30":20,"d7":20}' ]
}

@test "a value that was in force when the 180d window opened counts for the whole window" {
  _commit 300 50
  _commit 1 5
  run _hwm 5
  [ "$(jq -c . <<<"$output")" = '{"d180":50,"d30":50,"d7":50}' ]
  _commit 0 4
  HUD_HWM_NOW=$((NOW + 4000)) run _hwm 4
  [ "$(jq .d180 <<<"$output")" -eq 50 ]
}

@test "there is no lifetime maximum: a peak older than 180 days is forgotten, and no max file is written" {
  _commit 400 99
  _commit 200 8
  run _hwm 8
  [ "$(jq -c . <<<"$output")" = '{"d180":8,"d30":8,"d7":8}' ]
  [ -z "$(ls "$HUD_QUEUE_STATE_DIR"/max-* 2>/dev/null)" ]
}

@test "current length counts in every window" {
  _commit 5 8
  run _hwm 30
  [ "$(jq -c . <<<"$output")" = '{"d180":30,"d30":30,"d7":30}' ]
  # a later poll with a lower value keeps the peak (live sample)
  run _hwm 6
  [ "$(jq -c . <<<"$output")" = '{"d180":30,"d30":30,"d7":30}' ]
}

@test "samples between commits are caught: a peak that never reached a commit stays in the windows" {
  _commit 20 5
  HUD_HWM_NOW=$((NOW - 2 * DAY)) run _hwm 25
  HUD_HWM_NOW=$((NOW - 1 * DAY)) run _hwm 5
  run _hwm 5
  [ "$(jq -c . <<<"$output")" = '{"d180":25,"d30":25,"d7":25}' ]
  HUD_HWM_NOW=$((NOW + 6 * DAY + DAY / 2)) run _hwm 5   # the 25 is now 8.5 days old: out of 7d, still in 30d
  [ "$(jq -c . <<<"$output")" = '{"d180":25,"d30":25,"d7":5}' ]
  HUD_HWM_NOW=$((NOW + 40 * DAY)) run _hwm 5            # 42 days old: out of 30d, still in 180d
  [ "$(jq -c . <<<"$output")" = '{"d180":25,"d30":5,"d7":5}' ]
  HUD_HWM_NOW=$((NOW + 200 * DAY)) run _hwm 5           # out of every window
  [ "$(jq -c . <<<"$output")" = '{"d180":5,"d30":5,"d7":5}' ]
}

@test "no history and no samples yet: only the current length" {
  _commit 1 3
  rm -rf "$R/.git"; git init -q -b main "$R"   # no commits at all
  run _hwm 4
  [ "$(jq -c . <<<"$output")" = '{"d180":4,"d30":4,"d7":4}' ]
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
  [ "$(jq -c . <<<"$output")" = '{"d180":6,"d30":6,"d7":6}' ]
}

@test "incremental backfill picks up new commits; a rebuilt history after a force-push replaces the old series" {
  _commit 50 30
  _commit 40 5
  run _hwm 5
  [ "$(jq .d180 <<<"$output")" -eq 30 ]
  _commit 2 12
  HUD_HWM_NOW=$((NOW + 4000)) run _hwm 12   # past the TTL: the stamp allows a new pass
  [ "$(jq -c . <<<"$output")" = '{"d180":30,"d30":12,"d7":12}' ]
  # rewrite history: the old tip is no longer an ancestor, full rebuild
  git -C "$R" reset -q --hard HEAD~2
  _commit 1 7
  HUD_HWM_NOW=$((NOW + 9000)) run _hwm 7
  [ "$(jq .d180 <<<"$output")" -eq 30 ]
  ! grep -q '	12$' "$HUD_QUEUE_STATE_DIR"/hist-[0-9]*   # the rebuilt series no longer has the dropped commit
}

@test "state is keyed by repo root: two repos do not share a series" {
  _commit 3 18
  local R2="$BATS_TEST_TMPDIR/repo2"
  git init -q -b main "$R2"; git_identity "$R2"
  mkdir -p "$R2/dev/TODO"; printf -- '- [T20260101-000001](a.md): a\n' > "$R2/dev/TODO/queue.md"
  git -C "$R2" add -A; git -C "$R2" commit -q -m a
  run _hwm 18
  [ "$(jq .d180 <<<"$output")" -eq 18 ]
  run bash -c "source '$HWM'; sl-queue-hwm '$R2' 1"
  [ "$(jq -c . <<<"$output")" = '{"d180":1,"d30":1,"d7":1}' ]
}

@test "hud-data.sh adds queue.hwm next to the breakdown and keeps its own keys" {
  _commit 3 4
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.queue | {total, hwm}'"
  [ "$(jq -r .total <<<"$output")" -eq 4 ]
  [ "$(jq -c .hwm <<<"$output")" = '{"d180":4,"d30":4,"d7":4}' ]
}

@test "the render path never fetches or blocks: with HUD_HWM_SYNC unset the backfill is detached and the call returns at once" {
  _commit 3 4
  unset HUD_HWM_SYNC
  run bash -c "source '$HWM'; sl-queue-hwm '$R' 4"
  [ "$status" -eq 0 ]
  [ "$(jq .d180 <<<"$output")" -eq 4 ]
}
