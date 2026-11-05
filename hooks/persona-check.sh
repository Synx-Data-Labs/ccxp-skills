#!/usr/bin/env bash
# SessionStart(startup) + UserPromptSubmit hook: keeps the installed ccxp-agent persona
# (<profile>/agents/ccxp-agent.md) in step with the persona bundled with the RUNNING plugin version.
# A native `/plugin` update fires no hook and never touches the profile dir, so the persona would go stale;
# this refreshes it AUTOMATICALLY by calling the bundled `agent-pairing.sh update` (timestamped .bak kept, so
# hand edits are recoverable) and shows ONE short message. Content-based, no network, a few ms: the common
# case (identical files) is a single `cmp`. The last handled bundled-content hash is remembered in
# <profile>/ccxp-persona-check.json (mode 600), so a given content is refreshed at most once. Off switch:
# CCXP_PERSONA_AUTO_REFRESH=0, or {"autoRefresh":false} in that state file (for people who hand-edit).
# Silent (exit 0, no output) when jq is missing, the persona file is not installed, the profile does not use
# the ccxp-agent persona, the files are identical, the content was already handled, or anything fails.
# settings.json is only touched by agent-pairing.sh itself. See agent-pairing/SKILL.md.
set -uo pipefail

# hash_of FILE -> content hash ("" when no tool is available)
function hash_of() {
  { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | awk '{print $1; exit}'
}

# emit EVENT MESSAGE: one systemMessage for the user + the same text as context for the main-session agent.
function emit() {
  jq -cn --arg e "$1" --arg m "$2" '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
}

function persona-check() {
  local here dir asset file state json event h
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  asset="$here/agent-pairing/assets/ccxp-agent.md"
  file="$dir/agents/ccxp-agent.md"
  state="$dir/ccxp-persona-check.json"
  [ -f "$file" ] && [ -f "$asset" ] || return 0
  cmp -s "$asset" "$file" && return 0   # fast path: identical (or nothing to do)
  command -v jq >/dev/null 2>&1 || return 0
  [ "${CCXP_PERSONA_AUTO_REFRESH:-}" != 0 ] || return 0
  [ "$(jq -r 'if .autoRefresh == false then "off" else "on" end' "$state" 2>/dev/null)" != off ] || return 0
  [ "$(jq -r '.agent // empty' "$dir/settings.json" 2>/dev/null)" = ccxp-agent ] || return 0

  h="$(hash_of "$asset")"
  [ -n "$h" ] || return 0
  [ "$(jq -r '.lastHandled // empty' "$state" 2>/dev/null)" != "$h" ] || return 0   # this content already handled

  # Never downgrade: when a newer ccxp-skills version is cached beside the running one (an older session, or
  # `/update auto on` just installed one), that newer version's hook refreshes the persona; ours would undo it.
  local me newest
  me="$(basename "$here")"
  if [[ "$me" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    newest="$(ls "$(dirname "$here")" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)"
    [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$me" "$newest" | sort -V | tail -1)" = "$me" ] || return 0
  fi

  json="$(cat 2>/dev/null)"
  event="$(jq -r '.hook_event_name // empty' <<<"$json" 2>/dev/null)"
  [ "$event" = UserPromptSubmit ] || event=SessionStart

  # record_handled: remember this content (state written after the attempt, so an interrupted run retries).
  record_handled() {
    local tmp; [ ! -d "$state" ] || return 1
    tmp="$(mktemp "$state.XXXXXX" 2>/dev/null)" || return 1
    if jq -n --arg h "$h" --slurpfile old <(cat "$state" 2>/dev/null; true) \
         '(if ($old | length) > 0 and ($old[0] | type) == "object" then $old[0] else {} end) + {schema:1, lastHandled:$h}' >"$tmp" 2>/dev/null \
       && chmod 600 "$tmp" && mv "$tmp" "$state"; then return 0; fi
    rm -f "$tmp"; return 1
  }

  if [ -f "$here/agent-pairing/scripts/agent-pairing.sh" ] \
     && bash "$here/agent-pairing/scripts/agent-pairing.sh" update --claude-dir "$dir" >/dev/null 2>&1; then
    record_handled
    emit "$event" "ccxp-agent persona refreshed to match the installed ccxp-skills (previous copy kept as agents/ccxp-agent.md.bak-*). It usually shows in the next turn; if the new behavior does not show, restart Claude Code once no background jobs run."
  else
    # Failure: one notice; without a writable state file stay silent rather than repeat it on every prompt.
    record_handled || return 0
    emit "$event" "The installed ccxp-agent persona (agents/ccxp-agent.md) is outdated versus this ccxp-skills version and the automatic refresh failed. Run /agent-pairing update."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  persona-check || true
  exit 0
fi
