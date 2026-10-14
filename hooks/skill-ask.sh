#!/usr/bin/env bash
# PreToolUse hook (matcher: Skill). Returns permissionDecision "ask" when the
# model calls a skill listed in ask-skills.txt; silent (exit 0 = no opinion)
# otherwise. Typed `/skill` never reaches this hook (verified, T20261012-352228).
set -euo pipefail

# Extract tool_input.skill from the hook's stdin JSON (jq, else python3).
function skill-name() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tool_input.skill // empty' <<<"$json"
  else
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("skill",""))' <<<"$json"
  fi
}

# Is $1 (bare or `plugin:name`) listed in $2? Always exit 0; prints "yes" on a hit.
function listed() {
  local name="${1##*:}" file="$2" line
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    if [[ -n "$line" && "$line" == "$name" ]]; then echo yes; return 0; fi
  done <"$file"
}

function skill-ask() {
  local dir json name
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  json="$(cat)"
  name="$(skill-name "$json")"
  [[ -n "$name" ]] || return 0
  if [[ "$(listed "$name" "$dir/ask-skills.txt")" == yes ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"The model wants to run the /%s skill. Approve to let it run."}}\n' "${name##*:}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  skill-ask "$@"
fi
