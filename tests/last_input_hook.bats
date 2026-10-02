#!/usr/bin/env bats
# Tests for statusline-setup/scripts/last-input-hook.sh — the Claude Code
# UserPromptSubmit hook that caches a sanitized, truncated copy of the last
# submitted prompt per session_id, read by statusline-command.sh's
# sl-last-input-part (T20260924-366770).
#
# Helper functions are sourced and tested directly (function-wrapped, see the
# BASH_SOURCE guard at the bottom of the script); the stdin entrypoint
# last-input-hook is tested end-to-end by piping a synthetic UserPromptSubmit
# payload, same pattern as tests/statusline_setup.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/statusline-setup/scripts/last-input-hook.sh"

setup() {
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
}

# ---------------------------------------------------------------------------
# Sourceable / structure
# ---------------------------------------------------------------------------

@test "last-input-hook.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "last-input-hook.sh is sourceable without executing its main (function-wrapped)" {
  run bash -c "source '$SCRIPT'; type last-input-hook >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# li-sanitize
# ---------------------------------------------------------------------------

@test "li-sanitize collapses newlines and tabs to single spaces" {
  run bash -c "source '$SCRIPT'; li-sanitize \$'hello\nworld\tagain'"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world again" ]
}

@test "li-sanitize squeezes repeated whitespace and trims ends" {
  run bash -c "source '$SCRIPT'; li-sanitize '  hello    world  '"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

# ---------------------------------------------------------------------------
# li-truncate
# ---------------------------------------------------------------------------

@test "li-truncate leaves a short string untouched" {
  run bash -c "source '$SCRIPT'; li-truncate 'hello' 40"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "li-truncate cuts a long string and appends a single ellipsis" {
  run bash -c "source '$SCRIPT'; li-truncate '0123456789abcdefghij' 10"
  [ "$status" -eq 0 ]
  [ "$output" = "0123456789…" ]
}

# ---------------------------------------------------------------------------
# last-input-hook (full stdin -> cache-file pipeline)
# ---------------------------------------------------------------------------

@test "last-input-hook writes a sanitized, truncated, single-line cache file" {
  run bash -c "printf '%s' '{\"session_id\":\"sess-1\",\"prompt\":\"hello   world\nwith newline and\ttabs plus a lot more text than forty characters for sure\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -f "$LAST_INPUT_STATE_DIR/sess-1" ]
  run cat "$LAST_INPUT_STATE_DIR/sess-1"
  [ "$status" -eq 0 ]
  # single line, no raw newline/tab bytes, capped at 40 chars + ellipsis
  [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
  [ "$output" = "hello world with newline and tabs plus a…" ]
}

@test "last-input-hook exits 0 and writes nothing when session_id is absent" {
  run bash -c "printf '%s' '{\"prompt\":\"no session id here\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -d "$LAST_INPUT_STATE_DIR" ] || [ -z "$(ls -A "$LAST_INPUT_STATE_DIR" 2>/dev/null)" ]
}

@test "last-input-hook exits 0 and writes an empty cache file when prompt is absent" {
  run bash -c "printf '%s' '{\"session_id\":\"sess-2\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -f "$LAST_INPUT_STATE_DIR/sess-2" ]
  [ -z "$(cat "$LAST_INPUT_STATE_DIR/sess-2")" ]
}

@test "last-input-hook exits 0 on malformed JSON (never fails prompt submission)" {
  run bash -c "printf '%s' 'not json at all' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
}

@test "last-input-hook prunes stale sibling files older than 30 days on write" {
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf 'stale' > "$LAST_INPUT_STATE_DIR/sess-old"
  # Backdate well past the 30-day prune window (works on both GNU and BSD
  # touch via -t YYYYMMDDhhmm).
  touch -t "$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '40 days ago' +%Y%m%d%H%M)" "$LAST_INPUT_STATE_DIR/sess-old"

  run bash -c "printf '%s' '{\"session_id\":\"sess-new\",\"prompt\":\"fresh\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -f "$LAST_INPUT_STATE_DIR/sess-new" ]
  [ ! -f "$LAST_INPUT_STATE_DIR/sess-old" ]
}

@test "last-input-hook does not prune a recent sibling file" {
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf 'recent' > "$LAST_INPUT_STATE_DIR/sess-recent"

  run bash -c "printf '%s' '{\"session_id\":\"sess-new2\",\"prompt\":\"fresh\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -f "$LAST_INPUT_STATE_DIR/sess-recent" ]
}
