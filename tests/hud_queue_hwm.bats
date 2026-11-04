#!/usr/bin/env bats
# Tests for the queue high watermark (hud/scripts/hud-queue-hwm.sh): the git-history backfill, the
# local sample log (cap/rotation), the window maxima and the hud-data.sh `queue.hwm` key. "origin" is a
# local bare repo; nothing here touches the network or the developer's state.

load test_helper
HWM="$REPO_ROOT/hud/scripts/hud-queue-hwm.sh"
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
DAY=86400

setup() {
  isolate_claimant_state
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

@test "window maxima from git history: lifetime, 30d and 7d, carrying the value in force at the window start" {
  _commit 100 10   # lifetime peak, long ago
  _commit 90 40
  _commit 80 12
  _commit 40 20    # 40 days ago: 20 until the next commit
  _commit 3 15     # last week: the 20 stayed in force until here, so it still counts for 7d
  _commit 1 9
  run _hwm 9
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"life":40,"d30":20,"d7":20}' ]
}

@test "current length counts in every window and raises the lifetime maximum" {
  _commit 5 8
  run _hwm 30
  [ "$(jq -c . <<<"$output")" = '{"life":30,"d30":30,"d7":30}' ]
  # a later poll with a lower value keeps the peak (live sample + .max file)
  run _hwm 6
  [ "$(jq -c . <<<"$output")" = '{"life":30,"d30":30,"d7":30}' ]
}

@test "samples between commits are caught: a peak that never reached a commit stays in the windows" {
  _commit 20 5
  HUD_HWM_NOW=$((NOW - 2 * DAY)) run _hwm 25
  HUD_HWM_NOW=$((NOW - 1 * DAY)) run _hwm 5
  run _hwm 5
  [ "$(jq -c . <<<"$output")" = '{"life":25,"d30":25,"d7":25}' ]
  HUD_HWM_NOW=$((NOW + 6 * DAY + DAY / 2)) run _hwm 5   # the 25 is now 8.5 days old: out of 7d, still in 30d
  [ "$(jq -c . <<<"$output")" = '{"life":25,"d30":25,"d7":5}' ]
}

@test "no history and no samples yet: only the current length" {
  _commit 1 3
  rm -rf "$R/.git"; git init -q -b main "$R"   # no commits at all
  run _hwm 4
  [ "$(jq -c . <<<"$output")" = '{"life":4,"d30":4,"d7":4}' ]
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

@test "sample log: only changes are appended, and it rotates at the cap keeping the newest half and the lifetime max" {
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
  # the 100 rotated away from the sample file but the lifetime maximum survives
  ! grep -q '	100$' "$f"
  [ "$(jq .life <<<"$(_hwm 3)")" -eq 100 ]
}

@test "incremental backfill picks up new commits; a rebuilt history after a force-push never lowers the lifetime max" {
  _commit 50 30
  _commit 40 5
  run _hwm 5
  [ "$(jq .life <<<"$output")" -eq 30 ]
  _commit 2 12
  HUD_HWM_NOW=$((NOW + 4000)) run _hwm 12   # past the TTL: the stamp allows a new pass
  [ "$(jq -c . <<<"$output")" = '{"life":30,"d30":12,"d7":12}' ]
  # rewrite history: the old tip is no longer an ancestor, full rebuild
  git -C "$R" reset -q --hard HEAD~2
  _commit 1 7
  HUD_HWM_NOW=$((NOW + 9000)) run _hwm 7
  [ "$(jq .life <<<"$output")" -eq 30 ]
}

@test "state is keyed by repo root: two repos do not share a series" {
  _commit 3 18
  local R2="$BATS_TEST_TMPDIR/repo2"
  git init -q -b main "$R2"; git_identity "$R2"
  mkdir -p "$R2/dev/TODO"; printf -- '- [T20260101-000001](a.md): a\n' > "$R2/dev/TODO/queue.md"
  git -C "$R2" add -A; git -C "$R2" commit -q -m a
  run _hwm 18
  [ "$(jq .life <<<"$output")" -eq 18 ]
  run bash -c "source '$HWM'; sl-queue-hwm '$R2' 1"
  [ "$(jq -c . <<<"$output")" = '{"life":1,"d30":1,"d7":1}' ]
}

@test "hud-data.sh adds queue.hwm next to the breakdown and keeps its own keys" {
  _commit 3 4
  run bash -c "echo '{\"cwd\":\"$R\"}' | bash '$HUD' | jq -c '.queue | {total, hwm}'"
  [ "$(jq -r .total <<<"$output")" -eq 4 ]
  [ "$(jq -c .hwm <<<"$output")" = '{"life":4,"d30":4,"d7":4}' ]
}

@test "the render path never fetches or blocks: with HUD_HWM_SYNC unset the backfill is detached and the call returns at once" {
  _commit 3 4
  unset HUD_HWM_SYNC
  run bash -c "source '$HWM'; sl-queue-hwm '$R' 4"
  [ "$status" -eq 0 ]
  [ "$(jq .life <<<"$output")" -eq 4 ]
}
