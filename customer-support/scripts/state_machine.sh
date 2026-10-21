#!/usr/bin/env bash
# state_machine.sh — pure label-state transition rules for /customer-support
# (T20261012-373882). No gh/network calls — a deterministic lookup table so
# the transition rules can be unit-tested without mocking GitHub.
#
# States (status:* labels, exactly one per issue): new, triaged, in-progress,
# blocked, needs-upstream, delivered (working), plus terminal wontfix and
# duplicate (names live in label_names.sh; retired names are canonicalised on
# input). `none` (an issue with no status label, e.g. legacy ones) is treated
# as `new` by `triage` only. Closing: CLOSED:completed (accept),
# CLOSED:timeout (autoclose), CLOSED:wontfix / CLOSED:duplicate (reject).
# block/needs-upstream REPLACE the current status; unblock/needs-upstream-off
# restore the previous one (passed in by the caller, fallback triaged).
#
# Usage:
#   cs-sm-next <current-primary-state> <subcommand> [<arg>]
#     <arg>: reject -> reason (wontfix|duplicate, default wontfix);
#            unblock/needs-upstream-off -> previous status to restore.
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
  local current="${1:-}" subcommand="${2:-}" arg="${3:-}"
  if [[ -z "$current" || -z "$subcommand" ]]; then
    echo "usage: state_machine.sh <current-primary-state> <subcommand>" >&2
    return 2
  fi

  current=$(cs-label-canon "$current")

  case "$subcommand" in
    triage)
      # `none` = legacy issue with no status label: treated as new.
      if [[ "$current" != "$CS_L_NEW" && "$current" != "none" ]]; then
        echo "invalid: 'triage' requires current state '${CS_L_NEW}' (or none), got '${current}'" >&2
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
      local reason="${arg:-wontfix}"
      case "$reason" in
        wontfix|duplicate) ;;
        *)
          echo "invalid: reject reason must be one of ${CS_REJECT_REASONS} (got '${reason}')" >&2
          return 1
          ;;
      esac
      if cs-sm-is-preclose "$current"; then
        echo "CLOSED:${reason}"
      else
        echo "invalid: 'reject' requires a pre-close state, got '${current}'" >&2
        return 1
      fi
      ;;
    block|needs-upstream)
      local target="$CS_L_BLOCKED"
      [[ "$subcommand" == "needs-upstream" ]] && target="$CS_L_NEEDS_UPSTREAM"
      if ! cs-sm-is-preclose "$current" || [[ "$current" == "$target" ]]; then
        echo "invalid: '${subcommand}' requires a pre-close state other than '${target}', got '${current}'" >&2
        return 1
      fi
      echo "$target"
      ;;
    unblock|needs-upstream-off)
      local from="$CS_L_BLOCKED" prev
      [[ "$subcommand" == "needs-upstream-off" ]] && from="$CS_L_NEEDS_UPSTREAM"
      if [[ "$current" != "$from" ]]; then
        echo "invalid: '${subcommand}' requires current state '${from}', got '${current}'" >&2
        return 1
      fi
      prev=$(cs-label-canon "$arg")
      if [[ -z "$arg" || "$prev" == "$from" ]] || ! cs-sm-is-preclose "$prev"; then
        prev="$CS_L_TRIAGED"
      fi
      echo "$prev"
      ;;
    *)
      echo "error: unknown subcommand '${subcommand}'" >&2
      return 2
      ;;
  esac
}

# cs-sm-is-preclose <state> — exit 0 if `state` is one of the primary
# pre-close (working) states; exit 1 otherwise (e.g. wontfix/duplicate/none).
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
