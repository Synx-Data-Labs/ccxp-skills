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
#   transition.sh triage           <owner/repo> <issue> [--task <ref>]
#   transition.sh start            <owner/repo> <issue>
#   transition.sh deliver          <owner/repo> <issue> --urls <url>...
#   transition.sh deliver          <owner/repo> <issue> --release <sbom> <entitlement-label> [--clone-dir <dir>]
#   transition.sh request-confirm  <owner/repo> <issue>
#   transition.sh accept           <owner/repo> <issue> --actor <login> --allowed <comma-list>
#   transition.sh reject           <owner/repo> <issue> --reason <wontfix|invalid|duplicate>
#   transition.sh autoclose        <owner/repo> <issue> [--days N]   (delivered-timeout close, NOT an acceptance)
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
# shellcheck source=./sweep.sh
source "${CS_SCRIPTS_DIR}/sweep.sh"
# shellcheck source=./task_url.sh
source "${CS_SCRIPTS_DIR}/task_url.sh"

# cs-transition-clear-modifiers <repo> <issue> — best-effort; a modifier not
# present is a harmless no-op failure from gh's own `--remove-label`, so
# errors here are swallowed (never block a close over a missing modifier).
cs-transition-clear-modifiers() {
  local repo="$1" issue="$2"
  cs-labels-toggle "$repo" "$issue" "$CS_L_BLOCKED" off 2>/dev/null || true
  cs-labels-toggle "$repo" "$issue" "$CS_L_NEEDS_UPSTREAM" off 2>/dev/null || true
}

cs-transition() {
  local subcommand="${1:?subcommand required}" repo="${2:?owner/repo required}" issue="${3:?issue number required}"
  shift 3

  case "$subcommand" in
    triage|start|request-confirm)
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" "$subcommand")
      # `triage`'s optional --task <ref> (T20261019-181127, URL T20261021-289402):
      # posts a tracking comment with a FULL clickable URL to the task file
      # BEFORE the label moves, so the comment and the `triaged` label land
      # together. The URL is resolved first (task_url.sh): when the task cannot
      # be resolved nothing is posted and the label does not move. Plain
      # `triage <repo> <issue>` with no --task is unchanged.
      if [[ "$subcommand" == "triage" && "${1:-}" == "--task" ]]; then
        local ref="${2:?task ref required}" resolved kind url title prurl body
        resolved=$(cs-task-url "$ref" "${repo%%/*}") || return 1
        IFS=$'\037' read -r kind url title prurl <<<"$resolved"
        body="Tracked internally as [${ref}](${url})"
        [[ -n "$title" ]] && body+=" — ${title}"
        body+=$'\n\n'"${url}"
        if [[ "$kind" == "pr" ]]; then
          body+=$'\n\n'"The task file is not on the default branch yet; its filing PR is still open: ${prurl}"
        fi
        cs-gh issue comment "$issue" --repo "$repo" --body "$body"
      fi
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

    autoclose)
      # Delivered-timeout close (T20261021-266225). Not an accept: no
      # identity gate, but the gate below re-verifies age/modifiers/foreign
      # comments itself, so neither sweep.sh nor a direct call can bypass it.
      local days="$CS_SWEEP_DEFAULT_DAYS"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --days) days="${2:?--days needs a value}"; shift 2 ;;
          *) echo "usage: transition.sh autoclose <owner/repo> <issue> [--days N]" >&2; return 2 ;;
        esac
      done
      local current next verdict timeline
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" autoclose)
      verdict=$(cs-autoclose-gate "$repo" "$issue" "$days") || {
        echo "autoclose refused for ${repo}#${issue}: ${verdict:-not eligible}" >&2
        return 1
      }
      timeline=$(cs-sweep-timeline "$repo" "$issue")
      # Retry-safe: skip the comment if an earlier run already posted it.
      if ! cs-sweep-has-marker "$timeline"; then
        cs-gh issue comment "$issue" --repo "$repo" --body "**Auto-closed (not accepted):** this issue was marked \`${CS_L_DELIVERED}\` and has had no reject or reply for ${days} days, so it is being closed automatically. This is NOT an acceptance by the support team. The support team or the customer can reopen it at any time; the \`start\` step then moves it back from \`${CS_L_DELIVERED}\` to \`${CS_L_IN_PROGRESS}\`.
${CS_AUTOCLOSE_MARKER}"
      fi
      cs-labels-apply "$repo" "$issue" "$current" "$next"
      ;;

    block)
      cs-labels-toggle "$repo" "$issue" "$CS_L_BLOCKED" on
      ;;
    unblock)
      cs-labels-toggle "$repo" "$issue" "$CS_L_BLOCKED" off
      ;;
    needs-upstream)
      local mode="${1:?on|off required}"
      cs-labels-toggle "$repo" "$issue" "$CS_L_NEEDS_UPSTREAM" "$mode"
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
