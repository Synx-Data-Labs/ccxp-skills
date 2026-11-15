#!/usr/bin/env bats
# ccxp/scripts/ritual-job.sh (Phase 0 sync gate, 1.2.2a RCA reuse, channel
# config guard) and the ccxp/SKILL.md text that wires them in. Offline: fixture
# git repos and env files under $BATS_TEST_TMPDIR, fake task ids, no Slack.

load test_helper

RJ="$REPO_ROOT/ccxp/scripts/ritual-job.sh"
LABRUN="$REPO_ROOT/labrun-rca/scripts/labrun.sh"
SKILL="$REPO_ROOT/ccxp/SKILL.md"

setup() {
  unset CCXP_CRON_MODE SLACK_STANDUP_CHANNEL CCXP_SLACK_CHANNEL SLACK_STANDUP_CHANNEL_ID SLACK_AUTOMATION_ALERTS_CHANNEL_ID
  export RITUAL_JOB_ENV_FILES=""
}

mkrepo() {
  git init -q -b main "$BATS_TEST_TMPDIR/clone"
  git_identity "$BATS_TEST_TMPDIR/clone"
  git -C "$BATS_TEST_TMPDIR/clone" commit -q --allow-empty -m init
  git -C "$BATS_TEST_TMPDIR/clone" worktree add -q "$BATS_TEST_TMPDIR/wt" -b job
}

# -- skip-sync -------------------------------------------------------------

@test "skip-sync: cron mode in a linked worktree skips" {
  mkrepo
  CCXP_CRON_MODE=1 run bash "$RJ" skip-sync --dir "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 0 ]
  [ "$output" = skip ]
}

@test "skip-sync: cron mode in the main clone still syncs" {
  mkrepo
  CCXP_CRON_MODE=1 run bash "$RJ" skip-sync --dir "$BATS_TEST_TMPDIR/clone"
  [ "$status" -eq 10 ]
  [ "$output" = sync ]
}

@test "skip-sync: a worktree without cron mode syncs" {
  mkrepo
  run bash "$RJ" skip-sync --dir "$BATS_TEST_TMPDIR/wt"
  [ "$status" -eq 10 ]
  [ "$output" = sync ]
}

@test "skip-sync: a non-repo directory syncs (never skips on doubt)" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  CCXP_CRON_MODE=1 run bash "$RJ" skip-sync --dir "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 10 ]
  [ "$output" = sync ]
}

@test "skip-sync: unknown argument is a usage error" {
  run bash "$RJ" skip-sync --bogus
  [ "$status" -eq 2 ]
}

# -- rca-reuse -------------------------------------------------------------

NOW=1800000000   # epoch used as "now"; reply timestamps below are relative to it

rca_reply() { # real labrun.sh render-reply output, newlines flattened to spaces
  bash "$LABRUN" render-reply --workflow "Nightly Build" --run-id 123456 \
    --run-url https://github.com/o/r/actions/runs/123456 --error "boom" \
    --root-cause "a cause" --classification "$1" --confidence Confirmed \
    --impact "main red" --action "$2" | tr '\n' ' '
}

reuse() { run bash "$RJ" rca-reuse --now "$NOW" "$@"; }

@test "rca-reuse: a posted RCA reply gives its classification and task id" {
  printf '%s\t%s\n' "$((NOW-5000)).1" "🔍 Running RCA on Nightly Build run 123456" > "$BATS_TEST_TMPDIR/t"
  printf '%s\t%s\n' "$((NOW-4000)).2" "$(rca_reply 'Our code' 'T20260101-123456 filed')" >> "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 0 ]
  [ "$output" = "reuse Our code T20260101-123456" ]
}

@test "rca-reuse: an RCA reply with no task gives none" {
  printf '%s\t%s\n' "$((NOW-4000)).2" "$(rca_reply Transient 'None — transient')" > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 0 ]
  [ "$output" = "reuse Transient none" ]
}

@test "rca-reuse: a literal backslash-n flattened reply and a leading mention parse" {
  printf '%s\t<@U123> *RCA — wf run 1*\\n\\n*Classification:* Upstream\\n*Confidence:* Confirmed\\n*Action:* T20260101-000001\\n\n' "$((NOW-4000)).2" > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 0 ]
  [ "$output" = "reuse Upstream T20260101-000001" ]
}

@test "rca-reuse: a continuation line is not a reply" {
  printf '%s\t%s\nplain continuation\n' "$((NOW-4000)).2" "$(rca_reply Upstream 'T20260101-000001')" > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$output" = "reuse Upstream T20260101-000001" ]
}

@test "rca-reuse: a fresh ack-only thread waits (an RCA is in flight)" {
  printf '%s\t%s\n' "$((NOW-600)).1" "🔍 Running RCA on Nightly Build run 1 — will reply with findings." > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 11 ]; [ "$output" = wait ]
}

@test "rca-reuse: a stale ack with no live job, and an empty thread, run the RCA" {
  printf '%s\t%s\n' "$((NOW-7200)).1" "🔍 Running RCA on Nightly Build run 1 — will reply with findings." > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 10 ]; [ "$output" = run-rca ]
  reuse < /dev/null
  [ "$status" -eq 10 ]; [ "$output" = run-rca ]
}

@test "rca-reuse: a live job keeps even a stale ack waiting" {
  printf '%s\t%s\n' "$((NOW-7200)).1" "🔍 Running RCA on Nightly Build run 1" > "$BATS_TEST_TMPDIR/t"
  reuse --live-job yes < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 11 ]; [ "$output" = wait ]
}

@test "rca-reuse: unrelated chatter runs the RCA; missing --now is a usage error" {
  printf '%s\t%s\n' "$((NOW-4000)).1" "someone: looking" > "$BATS_TEST_TMPDIR/t"
  reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -eq 10 ]; [ "$output" = run-rca ]
  run bash "$RJ" rca-reuse < "$BATS_TEST_TMPDIR/t"
  [ "$status" -ne 0 ]
}

# -- channel ---------------------------------------------------------------

@test "channel: unset exits 3 for every kind" {
  local k
  for k in standup standup-id alerts; do
    run bash "$RJ" channel "$k"
    [ "$status" -eq 3 ] || { echo "$k: $status"; false; }
    [[ "$output" == *"not configured"* ]]
  done
}

@test "channel: exported value wins and a leading # is dropped" {
  SLACK_STANDUP_CHANNEL='#team-standup' run bash "$RJ" channel standup
  [ "$status" -eq 0 ]; [ "$output" = team-standup ]
  SLACK_AUTOMATION_ALERTS_CHANNEL_ID=C0TESTALERT run bash "$RJ" channel alerts
  [ "$output" = C0TESTALERT ]
  SLACK_STANDUP_CHANNEL_ID=C0TESTSTAND run bash "$RJ" channel standup-id
  [ "$output" = C0TESTSTAND ]
}

@test "channel: SLACK_STANDUP_CHANNEL beats CCXP_SLACK_CHANNEL, which is the fallback" {
  CCXP_SLACK_CHANNEL=fallback-chan run bash "$RJ" channel standup
  [ "$output" = fallback-chan ]
  SLACK_STANDUP_CHANNEL=first CCXP_SLACK_CHANNEL=fallback-chan run bash "$RJ" channel standup
  [ "$output" = first ]
}

@test "channel: env files are read in order, first set value wins, never sourced" {
  printf 'CCXP_SLACK_CHANNEL=from-first\nSLACK_AUTOMATION_ALERTS_CHANNEL_ID="C0FIRST"\n' > "$BATS_TEST_TMPDIR/e1"
  printf 'touch %s/sourced\nCCXP_SLACK_CHANNEL=from-second\nSLACK_STANDUP_CHANNEL_ID=C0SECOND\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/e2"
  export RITUAL_JOB_ENV_FILES="$BATS_TEST_TMPDIR/missing:$BATS_TEST_TMPDIR/e1:$BATS_TEST_TMPDIR/e2"
  run bash "$RJ" channel standup
  [ "$output" = from-first ]
  run bash "$RJ" channel alerts
  [ "$output" = C0FIRST ]
  run bash "$RJ" channel standup-id
  [ "$output" = C0SECOND ]
  [ ! -e "$BATS_TEST_TMPDIR/sourced" ]
}

@test "channel: quoted values, trailing comments and CRLF are cleaned" {
  printf 'CCXP_SLACK_CHANNEL="quoted-chan" # why\r\nSLACK_STANDUP_CHANNEL_ID=C0PLAIN  # note\r\n' > "$BATS_TEST_TMPDIR/e"
  export RITUAL_JOB_ENV_FILES="$BATS_TEST_TMPDIR/e"
  run bash "$RJ" channel standup
  [ "$output" = quoted-chan ]
  run bash "$RJ" channel standup-id
  [ "$output" = C0PLAIN ]
}

@test "channel: with no override the default lookup reads the repo .env" {
  unset RITUAL_JOB_ENV_FILES
  mkdir -p "$BATS_TEST_TMPDIR/proj" "$BATS_TEST_TMPDIR/profile"
  printf 'SLACK_AUTOMATION_ALERTS_CHANNEL_ID=C0REPOENV\n' > "$BATS_TEST_TMPDIR/proj/.env"
  cd "$BATS_TEST_TMPDIR/proj"
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile" run bash "$RJ" channel alerts
  [ "$status" -eq 0 ]; [ "$output" = C0REPOENV ]
}

@test "channel: bad usage is exit 2" {
  run bash "$RJ" channel
  [ "$status" -eq 2 ]
  run bash "$RJ" channel nope
  [ "$status" -eq 2 ]
  run bash "$RJ" nope
  [ "$status" -eq 2 ]
}

@test "ritual-job.sh is sourceable without side effects" {
  run bash -c "source '$RJ'; type ritual_job_main >/dev/null && echo ok"
  [ "$output" = ok ]
}

# -- SKILL wiring (the text is the contract an agent follows) ---------------

@test "SKILL: Phase 0 consults skip-sync and 1.2.2a runs before the RCA" {
  grep -q 'ritual-job.sh skip-sync' "$SKILL"
  grep -q 'ritual-job.sh rca-reuse' "$SKILL"
  grep -q 'ritual-job.sh channel standup' "$SKILL"
  local a b
  a="$(grep -n 'ritual-job.sh rca-reuse' "$SKILL" | head -1 | cut -d: -f1)"
  b="$(grep -n '^##### 1.2.2 Run RCA' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

@test "SKILL: 1.2.2a has the MCP branch, unattended defaults and the release rule" {
  grep -q 'slack_read_channel' "$SKILL"
  grep -q '^#### Unattended defaults' "$SKILL"
  grep -q '^#### Ritual job bookkeeping' "$SKILL"
  grep -q 'ritual-due.sh release' "$SKILL"
}

@test "SKILL: no literal Slack channel name remains in ccxp/SKILL.md" {
  run grep -nE '(^|[ `])#[a-z][a-z0-9]*-[a-z0-9-]+' "$SKILL"
  [ "$status" -ne 0 ]
}
