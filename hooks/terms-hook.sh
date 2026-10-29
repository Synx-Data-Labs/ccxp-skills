#!/usr/bin/env bash
# UserPromptSubmit hook: tells the model which of the owner's terms (terms.json, the repo's glossary)
# appear in the prompt and, when the owner just defined one, how to record it. Read-only: it only runs
# `terms.sh expand` and `terms.sh detect`; every write stays with the agent and the owner's say-so.
# Silent (no output, exit 0) when there is nothing to say, jq is missing, or anything fails.
# Capture hints only appear when the profile has a terms.json or runs ccxp-agent mode by default
# (settings.json "agent"), so other profiles never see the feature. See agent-pairing/terms.md.
set -uo pipefail

# Prompt text -> hook output JSON on stdout (or nothing).
function terms-hook() {
  command -v jq >/dev/null 2>&1 || return 0
  local json prompt cwd here terms dir ex dt ctx out
  json=$(cat)
  prompt=$(jq -r '.prompt // empty' <<<"$json" 2>/dev/null) || return 0
  [[ -n "$prompt" ]] || return 0
  cwd=$(jq -r '.cwd // empty' <<<"$json" 2>/dev/null)
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  terms="$here/../agent-pairing/scripts/terms.sh"
  [[ -f "$terms" ]] || return 0
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local file="${CCXP_TERMS_FILE:-$dir/terms.json}" capture=0
  if [[ -f "$file" ]] || [[ "$(jq -r '.agent // empty' "$dir/settings.json" 2>/dev/null)" == "ccxp-agent" ]]; then capture=1; fi

  ctx=(--cwd "${cwd:-$PWD}")
  ex=$(printf '%s' "$prompt" | bash "$terms" expand "${ctx[@]}" - 2>/dev/null) || ex='[]'
  dt='[]'
  if [[ "$capture" == 1 ]]; then dt=$(printf '%s' "$prompt" | bash "$terms" detect "${ctx[@]}" - 2>/dev/null) || dt='[]'; fi
  jq -e 'type == "array"' <<<"$ex" >/dev/null 2>&1 || ex='[]'
  jq -e 'type == "array"' <<<"$dt" >/dev/null 2>&1 || dt='[]'
  [[ "$ex" != '[]' || "$dt" != '[]' ]] || return 0

  out=$(jq -rn --argjson ex "$ex" --argjson dt "$dt" --arg t "$terms" '
    def q: @sh;
    ($ex | map(if .status == "resolved" then "- \(.term) = \(.text)"
               else "- \(.term) is ambiguous: " + ([.candidates[].text | "\"" + . + "\""] | join(" | "))
                    + ". Ask the owner one short question, then record the answer: bash \($t | q) choose \(.term | q) \"<chosen meaning>\""
               end)) as $known
    | ($dt | map(if .kind == "explicit"
        then "- stated by the owner: \(.term) = \(.text). Record it (bash \($t | q) add \(.term | q) \(.text | q)), then tell the owner in one line \"noted: \(.term) = \(.text)\". Undo: bash \($t | q) remove \(.term | q) \(.text | q)"
        else "- unsure: ask the owner \"remember \(.term) = \(.text)?\" and record it only after a yes (bash \($t | q) add \(.term | q) \(.text | q) --origin asked)" end)) as $new
    | "Owner terms (terms.json / repo glossary), matched in this prompt:\n"
      + (if ($known | length) > 0 then ($known | join("\n")) + "\nWhen you write a prompt for a subagent or background job, expand these terms in it (subagents never see them).\n" else "" end)
      + (if ($new | length) > 0 then "Possible new term(s):\n" + ($new | join("\n")) + "\n" else "" end)' 2>/dev/null) || return 0
  [[ -n "$out" ]] || return 0
  jq -cn --arg c "$out" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  terms-hook "$@" || true
  exit 0
fi
