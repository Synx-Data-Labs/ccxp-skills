#!/usr/bin/env bats
# Tests for slack/scripts/slack-send.sh — canonical single implementation.
#
# Covers plain-text mode (jq encoding regression) and build notification mode
# (--product/--version/--status). Migrated build-mode tests from
# build-pipeline-repo/tests/slack-notify.bats when the vendored copy was
# removed and the build mode was folded into the canonical script.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SLACK_SEND="$REPO_ROOT/slack/scripts/slack-send.sh"
SLACK_NOTIFY="$REPO_ROOT/slack/scripts/slack-notify.sh"

setup() {
  export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/TEST"
  export PAYLOAD_FILE="$BATS_TEST_TMPDIR/payload.json"
  # Mock curl: capture the -d payload, report HTTP 200 like a real webhook.
  curl() {
    local payload=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) payload="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    printf '200'
  }
  export -f curl
}

# --- plain-text mode ---

@test "plain-text: emits valid JSON for a single-line message" {
  run bash "$SLACK_SEND" "hello world"
  [ "$status" -eq 0 ]
  run jq -e . "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$PAYLOAD_FILE")" = "hello world" ]
}

@test "plain-text: preserves newlines as valid JSON (multi-line message)" {
  run bash "$SLACK_SEND" "$(printf 'line one\nline two\nline three')"
  [ "$status" -eq 0 ]
  run jq -e . "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$PAYLOAD_FILE")" = "$(printf 'line one\nline two\nline three')" ]
}

@test "plain-text: JSON-escapes embedded double quotes" {
  run bash "$SLACK_SEND" 'say "hi" now'
  [ "$status" -eq 0 ]
  run jq -e . "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$PAYLOAD_FILE")" = 'say "hi" now' ]
}

@test "plain-text: JSON-escapes embedded backslashes" {
  run bash "$SLACK_SEND" 'path C:\temp\x'
  [ "$status" -eq 0 ]
  run jq -e . "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$PAYLOAD_FILE")" = 'path C:\temp\x' ]
}

@test "plain-text: fails clearly when jq is unavailable" {
  local tmp_bin="$BATS_TEST_TMPDIR/no-jq-bin"
  mkdir -p "$tmp_bin"
  ln -s /usr/bin/dirname "$tmp_bin/dirname"
  run env PATH="$tmp_bin" /bin/bash "$SLACK_SEND" "hello world"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: jq is required but not installed."* ]]
}

@test "plain-text: shows usage when no arguments given" {
  run bash "$SLACK_SEND"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "plain-text: fails when SLACK_WEBHOOK_URL not set" {
  run env -u SLACK_WEBHOOK_URL bash "$SLACK_SEND" "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SLACK_WEBHOOK_URL is not set"* ]]
}

# --- build notification mode (--product) ---

@test "build mode: emits valid JSON attachments payload" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success
  [ "$status" -eq 0 ]
  run jq -e '.attachments[0]' "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
}

@test "build mode: success attachment has green color" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success
  [ "$status" -eq 0 ]
  [ "$(jq -r '.attachments[0].color' "$PAYLOAD_FILE")" = "#36a64f" ]
}

@test "build mode: failure attachment has red color" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status failure
  [ "$status" -eq 0 ]
  [ "$(jq -r '.attachments[0].color' "$PAYLOAD_FILE")" = "#cc0000" ]
}

@test "build mode: product and version appear in fields" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.attachments[0].fields[] | select(.title=="Product") | .value' "$PAYLOAD_FILE")" == "AcmeWidget4" ]]
  [[ "$(jq -r '.attachments[0].fields[] | select(.title=="Version") | .value' "$PAYLOAD_FILE")" == "4.4.0" ]]
}

@test "build mode: details field included when provided" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success --details "8 RPMs built"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.attachments[0].fields[] | select(.title=="Details") | .value' "$PAYLOAD_FILE")" == "8 RPMs built" ]]
}

@test "build mode: details with newlines encode as valid JSON" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success \
    --details "$(printf 'step 1 OK\nstep 2 OK')"
  [ "$status" -eq 0 ]
  run jq -e . "$PAYLOAD_FILE"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.attachments[0].fields[] | select(.title=="Details") | .value' "$PAYLOAD_FILE")" \
    == "$(printf 'step 1 OK\nstep 2 OK')" ]]
}

@test "build mode: duration field included when provided" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0" --status success --duration "42m 17s"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.attachments[0].fields[] | select(.title=="Duration") | .value' "$PAYLOAD_FILE")" == "42m 17s" ]]
}

@test "build mode: fails when --product given without --status" {
  run bash "$SLACK_SEND" --product "AcmeWidget4" --version "4.4.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--product, --version, and --status are required"* ]]
}

# --- slack-notify unit tests ---

@test "slack-notify: warns on HTTP error but does not fail" {
  # shellcheck disable=SC1090
  source "$SLACK_NOTIFY"
  curl() { echo "403"; }
  export -f curl
  export SLACK_WEBHOOK_URL="https://hooks.slack.com/test"
  run slack-notify '{"text":"test"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Slack notification failed (HTTP 403)"* ]]
}

@test "slack-notify: skips silently when SLACK_WEBHOOK_URL is unset" {
  # shellcheck disable=SC1090
  source "$SLACK_NOTIFY"
  run env -u SLACK_WEBHOOK_URL bash -c "
    source '$SLACK_NOTIFY'
    slack-notify '{\"text\":\"hi\"}'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SLACK_WEBHOOK_URL not set"* ]]
}
