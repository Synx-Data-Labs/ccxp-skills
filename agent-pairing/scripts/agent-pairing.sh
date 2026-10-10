#!/usr/bin/env bash
# agent-pairing.sh <on|off|status> [--claude-dir DIR]
#
# Toggles the "dispatcher" main-session agent persona as a Claude Code
# profile's default (~/.claude unless --claude-dir overrides it): every
# future session hands requests to background subagents instead of working
# inline. A jq-based settings.json edit, never a text replace -- that file
# also carries hooks/permissions/plugin config that must survive untouched.
#
# `on`/`off` only ever touch the `.agent` key, and only when it's ours to
# touch: `off` never deletes a *different* custom agent someone else set.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET="$SCRIPT_DIR/../assets/dispatcher.md"

usage() {
  echo "usage: agent-pairing.sh <on|off|status> [--claude-dir DIR]" >&2
}

ACTION="${1:-}"
case "$ACTION" in
  on|off|status) ;;
  *) usage; exit 64 ;;
esac
shift

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
while [ $# -gt 0 ]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="${2:?--claude-dir requires a value}"; shift 2 ;;
    *) echo "agent-pairing.sh: unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "agent-pairing.sh: jq is required but not found on PATH" >&2
  exit 1
fi

SETTINGS="$CLAUDE_DIR/settings.json"
AGENTS_DIR="$CLAUDE_DIR/agents"
DISPATCHER="$AGENTS_DIR/dispatcher.md"

if [ ! -f "$SETTINGS" ]; then
  echo "agent-pairing.sh: $SETTINGS not found -- not a Claude Code profile directory" >&2
  exit 1
fi

if ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "agent-pairing.sh: $SETTINGS is not valid JSON -- refusing to touch it" >&2
  exit 1
fi

current_agent() {
  jq -r '.agent // empty' "$SETTINGS"
}

write_agent_key() {
  # $1: jq filter. Atomic write via a sibling tempfile + mv, preserving the
  # original file's permissions (it can carry a secret, e.g. GITHUB_TOKEN --
  # mktemp's own 0600 default must never silently narrow or widen that).
  local filter="$1"
  local tmp perm
  tmp="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
  if ! jq "$filter" "$SETTINGS" > "$tmp"; then
    rm -f "$tmp"
    echo "agent-pairing.sh: jq failed to apply the edit -- $SETTINGS left untouched" >&2
    return 1
  fi
  # GNU stat first: its `-c` cleanly fails (nonzero, no stdout) on real BSD
  # stat, which is a safe probe. The reverse order is NOT safe -- BSD-style
  # `-f FORMAT` collides with GNU stat's own `-f` (an unrelated boolean flag,
  # "show filesystem status"): GNU stat then silently treats the format
  # string as a second file argument and dumps filesystem info to STDOUT
  # instead of failing, which would corrupt $perm on any machine where GNU
  # coreutils' stat shadows the system one on PATH (common via Homebrew).
  perm="$(stat -c '%a' "$SETTINGS" 2>/dev/null || stat -f '%Lp' "$SETTINGS" 2>/dev/null)"
  [[ "$perm" =~ ^[0-7]{3,4}$ ]] || perm=644
  chmod "$perm" "$tmp"
  mv "$tmp" "$SETTINGS"
}

case "$ACTION" in
  on)
    mkdir -p "$AGENTS_DIR"
    if [ -f "$DISPATCHER" ]; then
      if ! cmp -s "$ASSET" "$DISPATCHER"; then
        echo "agent-pairing.sh: $DISPATCHER already exists and differs from the bundled dispatcher.md -- leaving it as-is (not overwriting a hand-edited file)" >&2
      fi
    else
      cp "$ASSET" "$DISPATCHER"
      echo "agent-pairing.sh: installed $DISPATCHER"
    fi

    if [ "$(current_agent)" = "dispatcher" ]; then
      echo "agent-pairing.sh: already ON (takes effect at the next session start)"
      exit 0
    fi
    write_agent_key '. + {agent: "dispatcher"}' || exit 1
    echo "agent-pairing.sh: ON -- takes effect at the next session start (this session is unaffected)"
    ;;

  off)
    if [ "$(current_agent)" != "dispatcher" ]; then
      echo "agent-pairing.sh: already OFF"
      exit 0
    fi
    write_agent_key 'del(.agent)' || exit 1
    echo "agent-pairing.sh: OFF -- takes effect at the next session start"
    ;;

  status)
    AGENT="$(current_agent)"
    if [ "$AGENT" = "dispatcher" ]; then
      echo "agent-pairing: ON"
    elif [ -n "$AGENT" ]; then
      echo "agent-pairing: OFF (current default agent: $AGENT)"
    else
      echo "agent-pairing: OFF"
    fi
    ;;
esac
