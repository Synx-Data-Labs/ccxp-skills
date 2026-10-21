#!/usr/bin/env bash
# state_machine.sh — pure label-state transition rules for /customer-support
# (T20261012-373882). No gh/network calls — a deterministic lookup table so
# the transition rules can be unit-tested without mocking GitHub.
#
# States (primary, mutually exclusive): new, triaged, in-progress,
# delivered (names live in label_names.sh; retired names `triage`/`accepted`
# are canonicalised on input). Terminal outcomes are not labels — they are "closed" with a
# reason: CLOSED:completed (accept) or CLOSED:rejected (reject).
#
# Usage:
#   cs-sm-next <current-primary-state> <subcommand>
#     prints the next primary state (or CLOSED:<reason>) on stdout, or a
#     clear error on stderr and exit 1 for an invalid transition, exit 2 for
#     an unrecognized subcommand.
#
# Sourceable (functions only; CLI entrypoint gated by the direct-execution
# guard at the bottom, per dev/guidelines.md Script Standards).
set -euo pipefail

_CS_SM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./label_names.sh
source "${_CS_SM_DIR}/label_names.sh"

# Primary states this state machine knows about (pre-close).
CS_SM_STATES="$CS_PRIMARY_LABELS"

cs-sm-next() {
  local current="${1:-}" subcommand="${2:-}"
  if [[ -z "$current" || -z "$subcommand" ]]; then
    echo "usage: state_machine.sh <current-primary-state> <subcommand>" >&2
    return 2
  fi

  current=$(cs-label-canon "$current")

  case "$subcommand" in
    triage)
      if [[ "$current" != "$CS_L_NEW" ]]; then
        echo "invalid: 'triage' requires current state '${CS_L_NEW}', got '${current}'" >&2
        return 1
      fi
      echo "$CS_L_TRIAGED"
      ;;
    start)
      case "$current" in
        "$CS_L_TRIAGED"|"$CS_L_DELIVERED") echo "$CS_L_IN_PROGRESS" ;;
        *)
          echo "invalid: 'start' requires '${CS_L_TRIAGED}' (normal) or '${CS_L_DELIVERED}' (revert after a failed delivery), got '${current}'" >&2
          return 1
          ;;
      esac
      ;;
    deliver)
      if [[ "$current" != "$CS_L_IN_PROGRESS" ]]; then
        echo "invalid: 'deliver' requires current state '${CS_L_IN_PROGRESS}', got '${current}'" >&2
        return 1
      fi
      echo "$CS_L_DELIVERED"
      ;;
    request-confirm)
      if [[ "$current" != "$CS_L_DELIVERED" ]]; then
        echo "invalid: 'request-confirm' requires current state '${CS_L_DELIVERED}', got '${current}'" >&2
        return 1
      fi
      echo "$current"
      ;;
    accept)
      if [[ "$current" != "$CS_L_DELIVERED" ]]; then
        echo "invalid: 'accept' requires current state '${CS_L_DELIVERED}', got '${current}'" >&2
        return 1
      fi
      echo "CLOSED:completed"
      ;;
    autoclose)
      # Timeout path (T20261021-266225): distinct from accept. Eligibility
      # (age, modifiers, foreign comments) is enforced by sweep.sh's gate
      # inside transition.sh; this table only says which state may time out.
      if [[ "$current" != "$CS_L_DELIVERED" ]]; then
        echo "invalid: 'autoclose' requires current state '${CS_L_DELIVERED}', got '${current}'" >&2
        return 1
      fi
      echo "CLOSED:timeout"
      ;;
    reject)
      case "$current" in
        "$CS_L_NEW"|"$CS_L_TRIAGED"|"$CS_L_IN_PROGRESS"|"$CS_L_DELIVERED") echo "CLOSED:rejected" ;;
        *)
          echo "invalid: 'reject' requires a pre-close state, got '${current}'" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "error: unknown subcommand '${subcommand}'" >&2
      return 2
      ;;
  esac
}

# cs-sm-is-preclose <state> — exit 0 if `state` is one of the primary
# pre-close states (valid target for the block/unblock/needs-upstream
# modifiers); exit 1 otherwise (e.g. already closed).
cs-sm-is-preclose() {
  local s state
  s=$(cs-label-canon "${1:-}")
  for state in $CS_SM_STATES; do
    [[ "$s" == "$state" ]] && return 0
  done
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-sm-next "$@"
fi
