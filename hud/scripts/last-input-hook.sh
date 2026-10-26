#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — records WHEN this session last received
# a prompt, so the hud `lastat` field ("you HH:MM") can show it without
# re-reading the growing transcript JSONL. Timestamp only: it never stores or
# reads the prompt text. The per-session file is empty; its mtime is the
# signal (hud-lib.sh: sl-last-input-epoch, read by hud-data.sh).
#
# History: this hook used to cache a truncated copy of the prompt for a
# `last: <text>` statusline segment (T20260924-366770). That text feature is
# retired; the script keeps its name and path so existing settings.json
# entries keep working. Writing (truncating) the per-session file also wipes
# any prompt text a previous version cached there.
#
# Fires exactly once per genuine human submission (slash commands included) —
# never on a tool-result turn, so no transcript role filtering is needed.
#
# Mirrors _session/claimant-id.sh's CLAIMANT_STATE_DIR convention
# (_session/claimant-id.sh:30) for an override env var, so BATS can isolate
# writes under $BATS_TEST_TMPDIR instead of the real ~/.claude/state.
#
# Deliberately NOT `set -euo pipefail`: same rationale as
# hud-lib.sh and claimant-id.sh — this runs on every prompt
# submission and must never fail/hang the interactive flow. Every failure
# path below degrades to "timestamp not updated this time" rather than a
# non-zero exit.

LAST_INPUT_STATE_DIR="${LAST_INPUT_STATE_DIR:-${HOME}/.claude/state/last-input}"
LAST_INPUT_PRUNE_DAYS="${LAST_INPUT_PRUNE_DAYS:-30}"

# True (0) iff $1 is safe to use as a bare filename under LAST_INPUT_STATE_DIR
# — no path separator (blocks traversal: a session_id can never escape the
# state dir without one) and not exactly "." or ".." (which would otherwise
# collide with the directory's own entries). Claude Code always generates a
# UUID-shaped session_id, but the hook/reader trust externally-supplied JSON,
# so this is defense-in-depth, not a format assumption.
li-safe-session-id() {
  local id="$1"
  [ -n "$id" ] || return 1
  case "$id" in
    */*|.|..) return 1 ;;
  esac
  return 0
}

# Remove timestamp files older than N days from the state dir. Best-effort —
# never fails the hook. Runs on every write (not tied to SessionEnd, since
# /clear or a crashed session can skip that hook).
li-prune-stale() {
  local dir="$1" days="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mtime "+${days}" -delete 2>/dev/null || true
}

# Reads a UserPromptSubmit stdin payload, takes only its session_id, and
# (re)creates an empty "$LAST_INPUT_STATE_DIR/<session_id>" so its mtime is
# now. Prunes stale sibling files. Always exits 0 — a broken hook must not
# block prompt submission.
last-input-hook() {
  local input session_id
  input=$(cat)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

  # No session id, or one that isn't a safe bare filename — nothing to key
  # the file on.
  li-safe-session-id "$session_id" || exit 0

  ( umask 077; mkdir -p "$LAST_INPUT_STATE_DIR" ) 2>/dev/null || exit 0
  ( umask 077; : > "$LAST_INPUT_STATE_DIR/$session_id" ) 2>/dev/null || true

  li-prune-stale "$LAST_INPUT_STATE_DIR" "$LAST_INPUT_PRUNE_DAYS"
  exit 0
}

# Run only when executed directly (not sourced), same BASH_SOURCE guard
# convention as hud-lib.sh / quality-probe/scripts/probe.sh.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  last-input-hook
fi
