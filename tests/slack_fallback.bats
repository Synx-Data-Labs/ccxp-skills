#!/usr/bin/env bats
# Tests for slack/scripts/slack-fallback.sh — uses a stubbed slack-send, never posts.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
FALLBACK="$REPO_ROOT/slack/scripts/slack-fallback.sh"

stub() { # stub <stdout> <stderr> <exit>
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" > \"$BATS_TEST_TMPDIR/args\""
    [[ -z "$1" ]] || echo "echo '$1'"
    [[ -z "$2" ]] || echo "echo '$2' >&2"
    echo "exit $3"
  } > "$BATS_TEST_TMPDIR/send.sh"
  export SLACK_SEND_CMD="$BATS_TEST_TMPDIR/send.sh"
}

@test "success: reports webhook fallback, routes to dev channel, exit 0" {
  stub "Slack notification sent successfully" "" 0
  run bash "$FALLBACK" "hello"
  [ "$status" -eq 0 ]
  [[ "$output" == "Slack post: Posted via webhook fallback"* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/args")" == "--channel dev hello" ]]
}

@test "HTTP 404 (slack-send exits 0 but warns): FAILED, exit 1" {
  stub "" "Warning: Slack notification failed (HTTP 404)" 0
  run bash "$FALLBACK" "hello"
  [ "$status" -eq 1 ]
  [ "$output" = "Slack post FAILED: Slack notification failed (HTTP 404)" ]
}

@test "missing URL (slack-send exits 1): FAILED with reason" {
  stub "" "Error: SLACK_WEBHOOK_URL_DEV is not set (needed for --channel dev)." 1
  run bash "$FALLBACK" "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == "Slack post FAILED: SLACK_WEBHOOK_URL_DEV is not set"* ]]
}

@test "webhook URLs are scrubbed from the reason" {
  stub "" "curl: failed https://hooks.slack.com/services/T0/B0/SECRET" 1
  run bash "$FALLBACK" "hello"
  [ "$status" -eq 1 ]
  [[ "$output" != *SECRET* && "$output" != *hooks.slack.com* ]]
}

@test "--journal appends the line on success and failure" {
  J="$BATS_TEST_TMPDIR/j.md"; : > "$J"
  stub "" "Warning: Slack notification failed (HTTP 404)" 0
  run bash "$FALLBACK" --journal "$J" "hello"
  [ "$status" -eq 1 ]
  stub "Slack notification sent successfully" "" 0
  run bash "$FALLBACK" --journal "$J" "hello"
  [ "$(wc -l < "$J")" -eq 2 ]
  grep -q '^- Slack post FAILED: ' "$J"
  grep -q '^- Slack post: Posted via webhook fallback' "$J"
}

@test "empty message: FAILED, nothing sent" {
  stub "Slack notification sent successfully" "" 0
  run bash "$FALLBACK" ""
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/args" ]
}
