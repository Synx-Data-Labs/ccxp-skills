#!/usr/bin/env bash
# slack-fallback.sh - webhook fallback for ritual posts (standup / IPM / retro)
# when the Slack MCP tool is unavailable or errored. Never silent.
#
# Usage:
#   slack-fallback.sh [--journal FILE] <message>
#
# Posts via `slack-send.sh --channel dev` (SLACK_WEBHOOK_URL_DEV). slack-send.sh
# exits 0 even on a webhook HTTP error or a missing URL, so success is judged by
# its "sent successfully" line, not the exit code.
#
# Prints one status line (also appended to FILE as a bullet when --journal is given):
#   Slack post: Posted via webhook fallback — MCP unavailable   (exit 0)
#   Slack post FAILED: <reason>                                 (exit 1)
# Reasons are scrubbed of URLs; the message and webhook URL are never echoed.
#
# Test seam: SLACK_SEND_CMD overrides the slack-send.sh path.

set -euo pipefail

function slack-fallback() {
  local journal="" message
  if [[ "${1:-}" == "--journal" ]]; then
    journal="${2:-}"; shift 2 || true
  fi
  message="$*"
  local script_dir send out rc=0 line
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  send="${SLACK_SEND_CMD:-$script_dir/slack-send.sh}"

  if [[ -z "$message" ]]; then
    line="Slack post FAILED: empty message"
  else
    out=$(bash "$send" --channel dev "$message" 2>&1) || rc=$?
    if [[ $rc -eq 0 && "$out" == *"Slack notification sent successfully"* ]]; then
      line="Slack post: Posted via webhook fallback — MCP unavailable"
    else
      local reason
      reason=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 1 \
        | sed -E 's#https?://[^[:space:]]*#<url>#g; s/^(Warning|Error): //' | cut -c1-200) || true
      [[ -n "$reason" ]] || reason="no output from slack-send (exit $rc)"
      line="Slack post FAILED: $reason"
    fi
  fi

  echo "$line"
  if [[ -n "$journal" ]]; then
    printf -- '- %s\n' "$line" >> "$journal"
  fi
  [[ "$line" == "Slack post: "* ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  slack-fallback "$@"
fi
