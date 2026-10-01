#!/usr/bin/env bats
# Tests for _slack/webapi.sh — Slack Web API (bot token) helper, replacing
# mcp__claude_ai_Slack__* for ccxp automation (T20261001-319589).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
WEBAPI="$SCRIPT_DIR/webapi.sh"

setup() {
  export SLACK_BOT_TOKEN="xoxb-test-token"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_RESPONSE_FILE="$BATS_TEST_TMPDIR/curl-response.json"
  echo '{"ok":true}' > "$CURL_RESPONSE_FILE"
  # Mock curl: record the full invocation, print the fixture response.
  curl() {
    echo "$*" >> "$CURL_LOG"
    cat "$CURL_RESPONSE_FILE"
  }
  export -f curl
}

# --- token resolution ---

@test "dies with a clear message when SLACK_BOT_TOKEN is unset and unresolvable" {
  run env -u SLACK_BOT_TOKEN HOME="$BATS_TEST_TMPDIR/nohome" bash "$WEBAPI" post C123 "hi"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SLACK_BOT_TOKEN is not set"* ]]
}

@test "picks up SLACK_BOT_TOKEN from an already-exported env var" {
  run bash "$WEBAPI" post C123 "hi"
  [ "$status" -eq 0 ]
}

@test "does NOT fall back to \$(pwd)/.env under BATS, even if one exists with a real token" {
  # Regression guard: without the BATS_TEST_TMPDIR check in
  # _slack_api_load_token, this test's pass/fail would depend on whether a
  # real .env happens to sit in whatever directory `bats` is invoked from
  # — not on the code under test. Prove the guard directly by planting a
  # .env with a token and asserting it's still ignored.
  local fake_repo="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$fake_repo"
  echo 'SLACK_BOT_TOKEN=xoxb-from-dotenv' > "$fake_repo/.env"
  run env -u SLACK_BOT_TOKEN HOME="$BATS_TEST_TMPDIR/nohome" bash -c "cd '$fake_repo' && bash '$WEBAPI' post C123 hi"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SLACK_BOT_TOKEN is not set"* ]]
}

# --- post ---

@test "post: calls chat.postMessage with channel and text" {
  run bash "$WEBAPI" post C123 "hello world"
  [ "$status" -eq 0 ]
  grep -q "chat.postMessage" "$CURL_LOG"
  grep -q "channel=C123" "$CURL_LOG"
  grep -q "text=hello world" "$CURL_LOG"
}

@test "post: includes thread_ts when given a third argument" {
  run bash "$WEBAPI" post C123 "a reply" "1234567890.000100"
  [ "$status" -eq 0 ]
  grep -q "thread_ts=1234567890.000100" "$CURL_LOG"
}

@test "post: omits thread_ts when not given (top-level message)" {
  run bash "$WEBAPI" post C123 "top level"
  [ "$status" -eq 0 ]
  ! grep -q "thread_ts" "$CURL_LOG"
}

@test "post: sends Authorization bearer header with the bot token" {
  run bash "$WEBAPI" post C123 "hi"
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer xoxb-test-token" "$CURL_LOG"
}

@test "post: prints the raw JSON response for the caller to inspect" {
  echo '{"ok":true,"ts":"1700000000.000200","channel":"C123"}' > "$CURL_RESPONSE_FILE"
  run bash "$WEBAPI" post C123 "hi"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.ts')" = "1700000000.000200" ]
}

# --- history ---

@test "history: calls conversations.history with the channel" {
  run bash "$WEBAPI" history C123
  [ "$status" -eq 0 ]
  grep -q "conversations.history" "$CURL_LOG"
  grep -q "channel=C123" "$CURL_LOG"
}

@test "history: defaults limit to 100 when not given" {
  run bash "$WEBAPI" history C123
  [ "$status" -eq 0 ]
  grep -q "limit=100" "$CURL_LOG"
}

@test "history: passes through oldest, latest, and a custom limit" {
  run bash "$WEBAPI" history C123 "1700000000.000000" "1700003600.000000" 50
  [ "$status" -eq 0 ]
  grep -q "oldest=1700000000.000000" "$CURL_LOG"
  grep -q "latest=1700003600.000000" "$CURL_LOG"
  grep -q "limit=50" "$CURL_LOG"
}

@test "history: omits oldest/latest when not given" {
  run bash "$WEBAPI" history C123
  [ "$status" -eq 0 ]
  ! grep -q "oldest=" "$CURL_LOG"
  ! grep -q "latest=" "$CURL_LOG"
}

# --- thread-replies ---

@test "thread-replies: calls conversations.replies with channel and ts" {
  run bash "$WEBAPI" thread-replies C123 "1700000000.000000"
  [ "$status" -eq 0 ]
  grep -q "conversations.replies" "$CURL_LOG"
  grep -q "channel=C123" "$CURL_LOG"
  grep -q "ts=1700000000.000000" "$CURL_LOG"
}

# --- find-by-text ---

@test "find-by-text: returns messages whose text contains the needle" {
  cat > "$CURL_RESPONSE_FILE" <<'EOF'
{"ok":true,"messages":[
  {"ts":"1700000100.000000","text":"unrelated message"},
  {"ts":"1700000200.000000","text":"build failed, see actions/runs/999 for details"}
]}
EOF
  run bash "$WEBAPI" find-by-text C123 "actions/runs/999"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].ts')" = "1700000200.000000" ]
}

@test "find-by-text: matches text embedded in attachments, not just top-level text" {
  cat > "$CURL_RESPONSE_FILE" <<'EOF'
{"ok":true,"messages":[
  {"ts":"1700000300.000000","attachments":[{"text":"Workflow: actions/runs/777"}]}
]}
EOF
  run bash "$WEBAPI" find-by-text C123 "actions/runs/777"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "1" ]
}

@test "find-by-text: returns an empty array when nothing matches" {
  cat > "$CURL_RESPONSE_FILE" <<'EOF'
{"ok":true,"messages":[{"ts":"1700000400.000000","text":"all green"}]}
EOF
  run bash "$WEBAPI" find-by-text C123 "actions/runs/999"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "find-by-text: returns an empty array (not an error) when the API call itself fails" {
  echo '{"ok":false,"error":"channel_not_found"}' > "$CURL_RESPONSE_FILE"
  run bash "$WEBAPI" find-by-text C_BOGUS "anything"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "find-by-text: returns an empty array (not blank stdout) on a transport failure" {
  # A real curl failure (timeout, DNS, connection reset, ...) can print
  # nothing at all — not even invalid JSON. jq's own "if/else" filter run
  # over empty stdin produces NO output (not even the else branch), which
  # would silently violate the "[] on any error" contract this function
  # promises. Simulate that directly: curl exits 0 but prints nothing.
  curl() { :; }
  export -f curl
  run bash "$WEBAPI" find-by-text C123 "anything"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- missing required args ---

@test "post: dies with a clear message instead of 'unbound variable' when args are missing" {
  run bash "$WEBAPI" post C123
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-api-post: expected at least 2 argument(s), got 1"* ]]
  [[ "$output" != *"unbound variable"* ]]
}

@test "history: dies with a clear message when the channel_id arg is missing" {
  run bash "$WEBAPI" history
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-api-history: expected at least 1 argument(s), got 0"* ]]
}

@test "thread-replies: dies with a clear message when args are missing" {
  run bash "$WEBAPI" thread-replies C123
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-api-thread-replies: expected at least 2 argument(s), got 1"* ]]
}

@test "find-by-text: dies with a clear message when args are missing" {
  run bash "$WEBAPI" find-by-text C123
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-api-find-by-text: expected at least 2 argument(s), got 1"* ]]
}

# --- CLI dispatch ---

@test "no arguments: prints usage and exits 1" {
  run bash "$WEBAPI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown command: prints usage and exits 1" {
  run bash "$WEBAPI" bogus-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command: bogus-command"* ]]
}

@test "--help: prints usage and exits 0" {
  run bash "$WEBAPI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- sourced (not executed) use ---

@test "can be sourced to call slack-api-post directly without invoking main" {
  run bash -c "
    source '$WEBAPI'
    export SLACK_BOT_TOKEN=xoxb-test-token
    curl() { echo \"\$*\" >> '$CURL_LOG'; cat '$CURL_RESPONSE_FILE'; }
    slack-api-post C123 'sourced call'
  "
  [ "$status" -eq 0 ]
  grep -q "chat.postMessage" "$CURL_LOG"
}
