#!/usr/bin/env bats
# Tests for hud/scripts/last-input-hook.sh — the Claude Code
# UserPromptSubmit hook that records WHEN a session last got a prompt: an empty
# per-session_id file whose mtime is the signal, read by hud-lib.sh's
# sl-last-input-epoch for the hud `lastat` field. It stores no prompt text.
#
# Helper functions are sourced and tested directly (function-wrapped, see the
# BASH_SOURCE guard at the bottom of the script); the stdin entrypoint
# last-input-hook is tested end-to-end by piping a synthetic UserPromptSubmit
# payload, same pattern as the other hook tests.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/hud/scripts/last-input-hook.sh"

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
# li-safe-session-id
# ---------------------------------------------------------------------------

@test "li-safe-session-id accepts a normal UUID-shaped id" {
  run bash -c "source '$SCRIPT'; li-safe-session-id 'abc123-def456'"
  [ "$status" -eq 0 ]
}

@test "li-safe-session-id rejects a path-traversal-shaped id" {
  run bash -c "source '$SCRIPT'; li-safe-session-id '../../etc/passwd'"
  [ "$status" -ne 0 ]
}

@test "li-safe-session-id rejects a bare slash-containing id" {
  run bash -c "source '$SCRIPT'; li-safe-session-id 'a/b'"
  [ "$status" -ne 0 ]
}

@test "li-safe-session-id rejects '.' and '..'" {
  run bash -c "source '$SCRIPT'; li-safe-session-id '.'"
  [ "$status" -ne 0 ]
  run bash -c "source '$SCRIPT'; li-safe-session-id '..'"
  [ "$status" -ne 0 ]
}

@test "li-safe-session-id rejects an empty id" {
  run bash -c "source '$SCRIPT'; li-safe-session-id ''"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# last-input-hook (full stdin -> timestamp-file pipeline)
# ---------------------------------------------------------------------------

@test "last-input-hook writes an EMPTY per-session file — no prompt text is stored" {
  run bash -c "printf '%s' '{\"session_id\":\"sess-1\",\"prompt\":\"super secret prompt text\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ -f "$LAST_INPUT_STATE_DIR/sess-1" ]
  [ ! -s "$LAST_INPUT_STATE_DIR/sess-1" ]
  run grep -rl "secret" "$LAST_INPUT_STATE_DIR"
  [ "$status" -ne 0 ]
}

@test "last-input-hook bumps the file mtime to now on each prompt" {
  mkdir -p "$LAST_INPUT_STATE_DIR"
  : > "$LAST_INPUT_STATE_DIR/sess-1"
  touch -t 202001010000 "$LAST_INPUT_STATE_DIR/sess-1"
  run bash -c "printf '%s' '{\"session_id\":\"sess-1\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  run bash -c "source '$REPO_ROOT/hud/scripts/hud-lib.sh'; sl-last-input-epoch '$LAST_INPUT_STATE_DIR' sess-1"
  [ "$status" -eq 0 ]
  [ "$output" -gt 1700000000 ]
}

@test "last-input-hook wipes prompt text cached there by the retired text feature" {
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf 'old cached prompt' > "$LAST_INPUT_STATE_DIR/sess-1"
  run bash -c "printf '%s' '{\"session_id\":\"sess-1\",\"prompt\":\"x\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -s "$LAST_INPUT_STATE_DIR/sess-1" ]
}

@test "last-input-hook exits 0 and writes nothing when session_id is absent" {
  run bash -c "printf '%s' '{\"prompt\":\"no session id here\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -d "$LAST_INPUT_STATE_DIR" ] || [ -z "$(ls -A "$LAST_INPUT_STATE_DIR" 2>/dev/null)" ]
}

@test "last-input-hook refuses a path-traversal session_id and writes nothing outside the state dir" {
  marker="$BATS_TEST_TMPDIR/outside-marker"
  run bash -c "printf '%s' '{\"session_id\":\"../outside-marker\",\"prompt\":\"pwned\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ ! -d "$LAST_INPUT_STATE_DIR" ] || [ -z "$(ls -A "$LAST_INPUT_STATE_DIR" 2>/dev/null)" ]
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
