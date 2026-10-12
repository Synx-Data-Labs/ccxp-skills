#!/usr/bin/env bash
# transition.sh — single enforced entrypoint for a /customer-support
# subcommand (T20261012-373882, hardened per independent review of
# ccxp-skills#346). Resolves the current primary label, asks
# state_machine.sh for the next one, runs the relevant gate
# (deliver_gate.sh / accept_gate.sh), and ONLY THEN calls labels.sh. This is
# what makes the evidence gate and identity gate structurally unbypassable
# from this skill's own workflow — a direct `labels.sh apply` call skips
# them, but this is the one documented entrypoint SKILL.md tells the caller
# to use for every state-changing subcommand.
#
# Usage:
#   transition.sh triage           <owner/repo> <issue>
#   transition.sh start            <owner/repo> <issue>
#   transition.sh deliver          <owner/repo> <issue> --urls <url>...
#   transition.sh deliver          <owner/repo> <issue> --release <sbom> <entitlement-label> [--clone-dir <dir>]
#   transition.sh request-confirm  <owner/repo> <issue>
#   transition.sh accept           <owner/repo> <issue> --actor <login> --allowed <comma-list>
#   transition.sh reject           <owner/repo> <issue> --reason <wontfix|invalid|duplicate>
#   transition.sh block            <owner/repo> <issue>
#   transition.sh unblock          <owner/repo> <issue>
#   transition.sh needs-upstream   <owner/repo> <issue> <on|off>
#
# `reject` applies the given reason label itself (folded in here, rather
# than a separate reject.sh — the specific wontfix/invalid/duplicate label
# is always applied before closing, never left to a caller's memory).
# `accept`/`reject` also clear any `blocked`/`needs-upstream` modifier on
# close, so a closed issue never carries a stale pre-close modifier.
set -euo pipefail

CS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./state_machine.sh
source "${CS_SCRIPTS_DIR}/state_machine.sh"
# shellcheck source=./labels.sh
source "${CS_SCRIPTS_DIR}/labels.sh"
# shellcheck source=./deliver_gate.sh
source "${CS_SCRIPTS_DIR}/deliver_gate.sh"
# shellcheck source=./accept_gate.sh
source "${CS_SCRIPTS_DIR}/accept_gate.sh"

# cs-transition-clear-modifiers <repo> <issue> — best-effort; a modifier not
# present is a harmless no-op failure from gh's own `--remove-label`, so
# errors here are swallowed (never block a close over a missing modifier).
cs-transition-clear-modifiers() {
  local repo="$1" issue="$2"
  cs-labels-toggle "$repo" "$issue" blocked off 2>/dev/null || true
  cs-labels-toggle "$repo" "$issue" needs-upstream off 2>/dev/null || true
}

cs-transition() {
  local subcommand="${1:?subcommand required}" repo="${2:?owner/repo required}" issue="${3:?issue number required}"
  shift 3

  case "$subcommand" in
    triage|start|request-confirm)
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" "$subcommand")
      cs-labels-apply "$repo" "$issue" "$current" "$next"
      ;;

    deliver)
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" deliver)
      case "${1:-}" in
        --urls)
          shift
          cs-deliver-check-urls "$@"
          ;;
        --release)
          shift
          local sbom="${1:?sbom path required}" label="${2:?entitlement label required}"
          shift 2
          cs-deliver-release-gate "${CS_SCRIPTS_DIR}/links.sh" "$sbom" "$label" "$@"
          ;;
        *)
          echo "usage: transition.sh deliver <owner/repo> <issue> --urls <url>...|--release <sbom> <label> [--clone-dir <dir>]" >&2
          return 2
          ;;
      esac
      # Gate passed (non-zero above would have already exited under -e) —
      # only now does the label actually move.
      cs-labels-apply "$repo" "$issue" "$current" "$next"
      ;;

    accept)
      local actor="" allowed=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --actor) actor="$2"; shift 2 ;;
          --allowed) allowed="$2"; shift 2 ;;
          *) echo "usage: transition.sh accept <owner/repo> <issue> --actor <login> --allowed <comma-list>" >&2; return 2 ;;
        esac
      done
      cs-accept-gate "$actor" "$allowed"
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" accept)
      cs-labels-apply "$repo" "$issue" "$current" "$next"
      cs-transition-clear-modifiers "$repo" "$issue"
      ;;

    reject)
      local reason=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --reason) reason="$2"; shift 2 ;;
          *) echo "usage: transition.sh reject <owner/repo> <issue> --reason <wontfix|invalid|duplicate>" >&2; return 2 ;;
        esac
      done
      case "$reason" in
        wontfix|invalid|duplicate) ;;
        *)
          echo "error: --reason must be one of wontfix, invalid, duplicate (got '${reason}')" >&2
          return 2
          ;;
      esac
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" reject)
      # Apply the specific rejection reason BEFORE closing, never left to
      # the caller to remember separately (the gap the independent review
      # of ccxp-skills#346 found: a bare CLOSED:rejected applies no label).
      cs-labels-toggle "$repo" "$issue" "$reason" on
      cs-labels-apply "$repo" "$issue" "$current" "$next"
      cs-transition-clear-modifiers "$repo" "$issue"
      ;;

    block)
      cs-labels-toggle "$repo" "$issue" blocked on
      ;;
    unblock)
      cs-labels-toggle "$repo" "$issue" blocked off
      ;;
    needs-upstream)
      local mode="${1:?on|off required}"
      cs-labels-toggle "$repo" "$issue" needs-upstream "$mode"
      ;;

    *)
      echo "error: unknown subcommand '${subcommand}'" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-transition "$@"
fi
