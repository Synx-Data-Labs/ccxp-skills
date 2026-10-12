#!/usr/bin/env bash
# state_machine.sh — pure label-state transition rules for /customer-support
# (T20261012-373882). No gh/network calls — a deterministic lookup table so
# the transition rules can be unit-tested without mocking GitHub.
#
# States (primary, mutually exclusive): triage, accepted, in-progress,
# delivered. Terminal outcomes are not labels — they are "closed" with a
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

# Primary states this state machine knows about (pre-close).
CS_SM_STATES="triage accepted in-progress delivered"

cs-sm-next() {
  local current="${1:-}" subcommand="${2:-}"
  if [[ -z "$current" || -z "$subcommand" ]]; then
    echo "usage: state_machine.sh <current-primary-state> <subcommand>" >&2
    return 2
  fi

  case "$subcommand" in
    triage)
      if [[ "$current" != "triage" ]]; then
        echo "invalid: 'triage' requires current state 'triage', got '${current}'" >&2
        return 1
      fi
      echo "accepted"
      ;;
    start)
      case "$current" in
        accepted|delivered) echo "in-progress" ;;
        *)
          echo "invalid: 'start' requires 'accepted' (normal) or 'delivered' (revert after a failed delivery), got '${current}'" >&2
          return 1
          ;;
      esac
      ;;
    deliver)
      if [[ "$current" != "in-progress" ]]; then
        echo "invalid: 'deliver' requires current state 'in-progress', got '${current}'" >&2
        return 1
      fi
      echo "delivered"
      ;;
    request-confirm)
      if [[ "$current" != "delivered" ]]; then
        echo "invalid: 'request-confirm' requires current state 'delivered', got '${current}'" >&2
        return 1
      fi
      echo "$current"
      ;;
    accept)
      if [[ "$current" != "delivered" ]]; then
        echo "invalid: 'accept' requires current state 'delivered', got '${current}'" >&2
        return 1
      fi
      echo "CLOSED:completed"
      ;;
    reject)
      case "$current" in
        triage|accepted|in-progress|delivered) echo "CLOSED:rejected" ;;
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
  local s="${1:-}" state
  for state in $CS_SM_STATES; do
    [[ "$s" == "$state" ]] && return 0
  done
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-sm-next "$@"
fi
