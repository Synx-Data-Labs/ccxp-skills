#!/usr/bin/env bash
# agent-pairing.sh <on|off|status|update> [--dry-run|-n] [--claude-dir DIR]
#
# Toggles the "ccxp-agent" main-session agent persona (a dispatcher) as a
# Claude Code profile's default (~/.claude unless --claude-dir overrides
# it): every future session hands requests to background subagents instead
# of working inline. A jq-based settings.json edit, never a text replace --
# that file also carries hooks/permissions/plugin config that must survive
# untouched.
#
# `on`/`off` only ever touch the `.agent` key, and only when it's ours to
# touch: `off` never deletes a *different* custom agent someone else set.
#
# `update` refreshes what `on` installed: the agents/ccxp-agent.md definition
# and the managed settings (today only the `.agent` key, re-asserted only when
# it is already "ccxp-agent" -- `update` never changes on/off state). By
# default it keeps a timestamped .bak-* copy of every file it is about to
# change, then replaces it atomically; nothing is asked. --dry-run (-n) shows
# the diff and writes nothing. --yes is accepted and ignored (legacy). It
# reports, never edits, dependencies it does not own.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET="$SCRIPT_DIR/../assets/ccxp-agent.md"

usage() {
  echo "usage: agent-pairing.sh <on|off|status|update> [--dry-run|-n] [--claude-dir DIR]" >&2
}

ACTION="${1:-}"
case "$ACTION" in
  on|off|status|update) ;;
  *) usage; exit 64 ;;
esac
shift

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="${2:?--claude-dir requires a value}"; shift 2 ;;
    --dry-run|-n|--yes)
      # --yes: legacy no-op (update no longer asks), accepted so old docs/habits work.
      if [ "$ACTION" != "update" ]; then
        echo "agent-pairing.sh: $1 is only valid with update" >&2; usage; exit 64
      fi
      [ "$1" = "--yes" ] || DRY_RUN=1
      shift ;;
    *) echo "agent-pairing.sh: unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "agent-pairing.sh: jq is required but not found on PATH" >&2
  exit 1
fi

SETTINGS="$CLAUDE_DIR/settings.json"
AGENTS_DIR="$CLAUDE_DIR/agents"
AGENT_FILE="$AGENTS_DIR/ccxp-agent.md"
LEGACY_AGENT_FILE="$AGENTS_DIR/dispatcher.md"

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

file_perm() {
  # GNU stat first: its `-c` cleanly fails (nonzero, no stdout) on real BSD
  # stat, which is a safe probe. The reverse order is NOT safe -- BSD-style
  # `-f FORMAT` collides with GNU stat's own `-f` (an unrelated boolean flag,
  # "show filesystem status"): GNU stat then silently treats the format
  # string as a second file argument and dumps filesystem info to STDOUT
  # instead of failing, which would corrupt the result on any machine where
  # GNU coreutils' stat shadows the system one on PATH (common via Homebrew).
  local perm
  perm="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$perm" =~ ^[0-7]{3,4}$ ]] || perm=644
  echo "$perm"
}

write_settings() {
  # $1: jq filter. Atomic write via a sibling tempfile + mv, preserving the
  # original file's permissions (it can carry a secret, e.g. GITHUB_TOKEN --
  # mktemp's own 0600 default must never silently narrow or widen that).
  local filter="$1"
  local tmp
  tmp="$(mktemp "$CLAUDE_DIR/.settings.json.XXXXXX")"
  if ! jq "$filter" "$SETTINGS" > "$tmp"; then
    rm -f "$tmp"
    echo "agent-pairing.sh: jq failed to apply the edit -- $SETTINGS left untouched" >&2
    return 1
  fi
  chmod "$(file_perm "$SETTINGS")" "$tmp"
  mv "$tmp" "$SETTINGS"
}

# --- update helpers ---------------------------------------------------------

backup_path() {
  # $1: file. Timestamped sibling path that does not exist yet.
  local base cand n=0
  base="$1.bak-$(date +%Y%m%d-%H%M%S)"
  cand="$base"
  while [ -e "$cand" ]; do n=$((n + 1)); cand="$base-$n"; done
  echo "$cand"
}

diffstat() {
  # $1 old, $2 new: "+A -R lines" from a unified diff.
  diff -u "$1" "$2" | awk '
    /^\+\+\+ / || /^--- / { next }
    /^\+/ { a++ } /^-/ { r++ }
    END { printf "+%d -%d lines", a, r }'
}

agent_def_state() {
  # echoes: missing | current | outdated
  if [ ! -f "$AGENT_FILE" ]; then echo missing
  elif cmp -s "$ASSET" "$AGENT_FILE"; then echo current
  else echo outdated
  fi
}

update_agent_definition() {
  case "$(agent_def_state)" in
    missing)
      echo "agent-pairing: agent definition: not installed ($AGENT_FILE) -- run 'on' to install it"
      return 0 ;;
    current)
      echo "agent-pairing: agent definition: up to date (identical to the bundled ccxp-agent.md)"
      return 0 ;;
  esac
  local stat
  stat="$(diffstat "$AGENT_FILE" "$ASSET")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "agent-pairing: agent definition: OUTDATED ($stat) -- dry run, nothing written. Diff (- = installed, incl. local edits; + = bundled):"
    diff -u -L "installed: $AGENT_FILE" -L "bundled: assets/ccxp-agent.md" "$AGENT_FILE" "$ASSET"
    return 0
  fi
  local bak tmp
  bak="$(backup_path "$AGENT_FILE")"
  cp -p "$AGENT_FILE" "$bak" || { echo "agent-pairing.sh: could not write backup $bak -- $AGENT_FILE left untouched" >&2; return 1; }
  tmp="$(mktemp "$AGENTS_DIR/.ccxp-agent.XXXXXX")" || return 1
  if ! cp "$ASSET" "$tmp"; then
    rm -f "$tmp"
    echo "agent-pairing.sh: could not stage the bundled definition -- $AGENT_FILE left untouched" >&2
    return 1
  fi
  chmod "$(file_perm "$AGENT_FILE")" "$tmp"
  mv "$tmp" "$AGENT_FILE"
  echo "agent-pairing: agent definition: UPDATED ($stat); previous version kept at $bak -- takes effect at the next session start"
}

update_settings() {
  # Managed settings = the `.agent` key, nothing else. It is re-asserted only
  # when already "ccxp-agent" (mode ON); an OFF profile -- including one with a
  # different or stale agent -- is left exactly as it is.
  local filter="." mode_note
  if [ "$(current_agent)" = "ccxp-agent" ]; then
    filter='. + {agent: "ccxp-agent"}'
    mode_note="mode ON"
  else
    mode_note="mode OFF, left as-is"
  fi
  local before after
  before="$(jq -S . "$SETTINGS")"
  after="$(jq -S "$filter" "$SETTINGS")"
  if [ "$before" = "$after" ]; then
    echo "agent-pairing: settings.json: nothing to change ($mode_note)"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "agent-pairing: settings.json: managed keys differ from the desired state -- dry run, not written:"
    diff -u -L "current: $SETTINGS" -L "desired" <(echo "$before") <(echo "$after")
    return 0
  fi
  local bak
  bak="$(backup_path "$SETTINGS")"
  cp -p "$SETTINGS" "$bak" || { echo "agent-pairing.sh: could not write backup $bak -- $SETTINGS left untouched" >&2; return 1; }
  write_settings "$filter" || return 1
  echo "agent-pairing: settings.json: UPDATED (managed key re-asserted); previous version kept at $bak -- takes effect at the next session start"
}

report_unmanaged() {
  # Things the persona depends on that `update` does not own: report only.
  local s missing=""
  for s in job-launch.sh job-status.sh job-resume.sh; do
    [ -f "$SCRIPT_DIR/$s" ] || missing="$missing $s"
  done
  if [ -n "$missing" ]; then
    echo "agent-pairing: note: bundled helper scripts missing next to this script:$missing -- reinstall/update the ccxp-skills plugin"
  fi
  if ! compgen -G "$CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills/*/agent-pairing" >/dev/null; then
    echo "agent-pairing: note: no ccxp-skills plugin install under $CLAUDE_DIR/plugins/cache -- the detached-jobs section of the agent looks for bg-jobs.md and job-*.sh there; update does not manage plugin installs"
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "agent-pairing: note: 'claude' CLI not found on PATH -- detached jobs (claude --bg) need it; update does not install it"
  fi
  if [ -f "$LEGACY_AGENT_FILE" ]; then
    echo "agent-pairing: note: $LEGACY_AGENT_FILE (pre-rename \"dispatcher\") is still present and unused -- remove it by hand"
  fi
  if [ "$(current_agent)" = "dispatcher" ]; then
    echo "agent-pairing: note: settings.json still has the stale agent \"dispatcher\"; update does not change on/off state -- run 'on' to switch to ccxp-agent"
  fi
}

case "$ACTION" in
  on)
    mkdir -p "$AGENTS_DIR"
    if [ -f "$AGENT_FILE" ]; then
      if ! cmp -s "$ASSET" "$AGENT_FILE"; then
        echo "agent-pairing.sh: $AGENT_FILE already exists and differs from the bundled ccxp-agent.md -- leaving it as-is (not overwriting a hand-edited file)" >&2
      fi
    else
      cp "$ASSET" "$AGENT_FILE"
      echo "agent-pairing.sh: installed $AGENT_FILE"
    fi
    if [ -f "$LEGACY_AGENT_FILE" ]; then
      echo "agent-pairing.sh: note: $LEGACY_AGENT_FILE (the pre-rename \"dispatcher\" agent) is still present and now unused -- safe to remove once you've switched to ccxp-agent" >&2
    fi

    if [ "$(current_agent)" = "ccxp-agent" ]; then
      echo "agent-pairing.sh: already ON (takes effect at the next session start)"
      exit 0
    fi
    write_settings '. + {agent: "ccxp-agent"}' || exit 1
    echo "agent-pairing.sh: ON -- takes effect at the next session start (this session is unaffected)"
    ;;

  off)
    if [ "$(current_agent)" != "ccxp-agent" ]; then
      echo "agent-pairing.sh: already OFF"
      exit 0
    fi
    write_settings 'del(.agent)' || exit 1
    echo "agent-pairing.sh: OFF -- takes effect at the next session start"
    ;;

  status)
    AGENT="$(current_agent)"
    if [ "$AGENT" = "ccxp-agent" ]; then
      echo "agent-pairing: ON"
    elif [ "$AGENT" = "dispatcher" ]; then
      echo "agent-pairing: OFF (stale pre-rename agent \"dispatcher\" still set -- re-run 'on' to upgrade to ccxp-agent)"
    elif [ -n "$AGENT" ]; then
      echo "agent-pairing: OFF (current default agent: $AGENT)"
    else
      echo "agent-pairing: OFF"
    fi
    case "$(agent_def_state)" in
      current) echo "agent-pairing: agent definition: up to date" ;;
      outdated) echo "agent-pairing: agent definition: OUTDATED -- run update" ;;
      missing) echo "agent-pairing: agent definition: not installed (run on)" ;;
    esac
    ;;

  update)
    update_agent_definition || exit 1
    update_settings || exit 1
    report_unmanaged
    ;;
esac
