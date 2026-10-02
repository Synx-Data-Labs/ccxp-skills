#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — caches a sanitized, truncated copy of
# the just-submitted prompt so statusline-command.sh can show "what did I
# just ask this session" without re-reading the growing transcript JSONL on
# every render (T20260924-366770).
#
# Fires exactly once per genuine human submission (slash commands included,
# as their literal typed text) — never on a tool-result turn (those also
# carry role:user in the transcript, but UserPromptSubmit never sees them),
# so no transcript role filtering is needed here.
#
# Mirrors _session/claimant-id.sh's CLAIMANT_STATE_DIR convention
# (_session/claimant-id.sh:30) for an override env var, so BATS can isolate
# writes under $BATS_TEST_TMPDIR instead of the real ~/.claude/state.
#
# Deliberately NOT `set -euo pipefail`: same rationale as
# statusline-command.sh and claimant-id.sh — this runs on every prompt
# submission and must never fail/hang the interactive flow. Every failure
# path below degrades to "cache not written this time" rather than a
# non-zero exit.

LAST_INPUT_STATE_DIR="${LAST_INPUT_STATE_DIR:-${HOME}/.claude/state/last-input}"
LAST_INPUT_MAX_CHARS="${LAST_INPUT_MAX_CHARS:-40}"
LAST_INPUT_PRUNE_DAYS="${LAST_INPUT_PRUNE_DAYS:-30}"

# Collapse newlines/tabs to spaces, squeeze repeated whitespace, trim ends.
li-sanitize() {
  local text="$1"
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  printf '%s' "$text" | sed -E 's/ +/ /g; s/^ //; s/ $//'
}

# Truncate to N chars, appending a single "…" when cut.
li-truncate() {
  local text="$1" max="$2"
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$max}"
  fi
}

# Remove cache files older than N days from the state dir. Best-effort —
# never fails the hook. Runs on every write (not tied to SessionEnd, since
# /clear or a crashed session can skip that hook).
li-prune-stale() {
  local dir="$1" days="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mtime "+${days}" -delete 2>/dev/null || true
}

# Reads a UserPromptSubmit stdin payload (prompt/session_id/cwd/...), writes
# the sanitized+truncated prompt to "$LAST_INPUT_STATE_DIR/<session_id>", and
# prunes stale sibling files. Always exits 0 — a broken hook must not block
# prompt submission.
last-input-hook() {
  local input session_id prompt sanitized
  input=$(cat)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)

  # No session id — nothing to key the cache file on.
  [ -n "$session_id" ] || exit 0

  mkdir -p "$LAST_INPUT_STATE_DIR" 2>/dev/null || exit 0

  sanitized=$(li-sanitize "$prompt")
  sanitized=$(li-truncate "$sanitized" "$LAST_INPUT_MAX_CHARS")

  ( umask 077; printf '%s' "$sanitized" > "$LAST_INPUT_STATE_DIR/$session_id" ) 2>/dev/null || true

  li-prune-stale "$LAST_INPUT_STATE_DIR" "$LAST_INPUT_PRUNE_DAYS"
  exit 0
}

# Run only when executed directly (not sourced), same BASH_SOURCE guard
# convention as statusline-command.sh / quality-probe/scripts/probe.sh.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  last-input-hook
fi
