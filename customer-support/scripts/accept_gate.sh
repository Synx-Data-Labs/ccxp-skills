#!/usr/bin/env bash
# accept_gate.sh — identity gate for /customer-support accept (T20261012-373882).
#
# "delivered -> closed (completed)" must never be self-applied by the
# delivering engineer — it is support-team-only (design doc "Transition
# rules": accept is "support team only"). This is a pure check: given the
# acting identity and the configured allowlist, decide allow/deny. No gh
# calls here — the caller resolves the acting login (e.g. `gh api user
# --jq .login`) and passes it in.
#
# Usage:
#   cs-accept-gate <acting-login> <comma-separated-allowed-logins>
# Exit 0 if allowed, 1 if denied, 2 on bad usage (e.g. empty allowlist —
# fail CLOSED, never silently allow everyone when the allowlist is
# unconfigured).
set -euo pipefail

cs-accept-gate() {
  local actor="${1:-}" allowed="${2:-}" IFS_OLD="$IFS" login
  if [[ -z "$actor" ]]; then
    echo "usage: accept_gate.sh <acting-login> <comma-separated-allowed-logins>" >&2
    return 2
  fi
  if [[ -z "$allowed" ]]; then
    echo "error: no support-team allowlist configured (SUPPORT_TEAM_LOGINS) — refusing 'accept' rather than allowing it by default" >&2
    return 2
  fi
  IFS=','
  for login in $allowed; do
    IFS="$IFS_OLD"
    login="${login// /}"
    if [[ "$login" == "$actor" ]]; then
      return 0
    fi
    IFS=','
  done
  IFS="$IFS_OLD"
  echo "error: '${actor}' is not on the support-team allowlist — 'accept' is support-team-only, never self-applied by the delivering engineer" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-accept-gate "$@"
fi
