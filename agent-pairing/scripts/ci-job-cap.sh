#!/usr/bin/env bash
# ci-job-cap.sh: print how many "CI failure response" jobs the ccxp-agent persona may start per turn.
# Read-only, no network, no writes. First valid positive integer wins:
#   1. env CCXP_CI_JOB_CAP
#   2. "ciJobCap" in <profile dir>/ccxp-hud.json (the profile's existing ccxp config file)
#   3. the default, 6
# An invalid value (not a positive integer, or missing/unreadable file) falls through to the next source.
# Sibling setting, unrelated: CCXP_ALERTS_CAP (the Slack-alerts cap, agent-pairing/alerts.md).
set -euo pipefail

[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"

CCXP_CI_JOB_CAP_DEFAULT=6

function cjc-valid() { [[ "${1:-}" =~ ^[0-9]{1,6}$ ]] && ((10#$1 > 0)); }

function cjc-from-file() {
  local f="${CCXP_PROFILE_DIR:-}/ccxp-hud.json" v
  [ -n "${CCXP_PROFILE_DIR:-}" ] && [ -r "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  v="$(jq -r 'if type == "object" then (.ciJobCap | if type == "number" or type == "string" then tostring else "" end) else "" end' "$f" 2>/dev/null || true)"
  if cjc-valid "$v"; then echo $((10#$v)); fi
}

function ci-job-cap() {
  local v
  if cjc-valid "${CCXP_CI_JOB_CAP:-}"; then echo $((10#$CCXP_CI_JOB_CAP)); return 0; fi
  v="$(cjc-from-file)"
  if [ -n "$v" ]; then echo "$v"; return 0; fi
  echo "$CCXP_CI_JOB_CAP_DEFAULT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ci-job-cap "$@"
fi
