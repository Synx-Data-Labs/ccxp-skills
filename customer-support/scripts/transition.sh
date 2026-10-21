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
#   transition.sh reject           <owner/repo> <issue> --reason <wontfix|duplicate>
#   transition.sh autoclose        <owner/repo> <issue> [--days N]   (delivered-timeout close, NOT an acceptance)
#   transition.sh block            <owner/repo> <issue>   (status -> status:blocked)
#   transition.sh unblock          <owner/repo> <issue>   (restores the previous status)
#   transition.sh needs-upstream   <owner/repo> <issue> <on|off>
#
# Scheme v2 (T20261021-421263): blocked/needs-upstream are statuses, not
# modifiers. block/needs-upstream-on REPLACE the current status; unblock/off
# restore the previous status read from the issue's label timeline (fallback
# status:triaged). `reject` swaps in the terminal status:wontfix|duplicate
# label itself and closes ("not planned" / "duplicate"), so a closed issue
# always carries exactly one status:* label. `accept` keeps status:delivered.
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

# cs-transition-previous-status <repo> <issue> <from-label> — prints the
# status the issue had before it last got <from-label> (the last status label
# removed before the last add of <from-label>, per the timeline), or nothing.
cs-transition-previous-status() {
  local repo="$1" issue="$2" from="$3" timeline
  timeline=$(cs-sweep-timeline "$repo" "$issue") || return 0
  jq -r --argjson from "$(cs-label-names-json "$from")" \
    --argjson st "$(cs-label-primary-names | jq -R . | jq -sc .)" '
    (to_entries | map(select(.value.event=="labeled"
        and (.value.label.name as $x | $from | index($x) != null))) | last | .key) as $i
    | if $i == null then empty else
        ([.[:$i][] | select(.event=="unlabeled"
            and (.label.name as $x | $st | index($x) != null))] | last | .label.name // empty)
      end' <<<"$timeline" 2>/dev/null || true
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
      ;;

    reject)
      local reason=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --reason) reason="$2"; shift 2 ;;
          *) echo "usage: transition.sh reject <owner/repo> <issue> --reason <wontfix|duplicate>" >&2; return 2 ;;
        esac
      done
      case "$reason" in
        wontfix|duplicate) ;;
        *)
          echo "error: --reason must be one of ${CS_REJECT_REASONS// /, } (got '${reason}'; a not-a-bug rejection is wontfix)" >&2
          return 2
          ;;
      esac
      local current next
      current=$(cs-labels-primary "$repo" "$issue")
      next=$(cs-sm-next "$current" reject "$reason")
      # cs-labels-apply swaps the old status for the terminal status label
      # (status:wontfix|duplicate) BEFORE closing — never left to the caller.
      cs-labels-apply "$repo" "$issue" "$current" "$next"
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

    block|unblock|needs-upstream)
      local sm="$subcommand" current next from prev=""
      if [[ "$subcommand" == "needs-upstream" ]]; then
        local mode="${1:?on|off required}"
        case "$mode" in
          on) ;;
          off) sm="needs-upstream-off" ;;
          *) echo "usage: transition.sh needs-upstream <owner/repo> <issue> <on|off>" >&2; return 2 ;;
        esac
      fi
      current=$(cs-labels-primary "$repo" "$issue")
      case "$sm" in
        unblock) from="$CS_L_BLOCKED" ;;
        needs-upstream-off) from="$CS_L_NEEDS_UPSTREAM" ;;
        *) from="" ;;
      esac
      # Restore path: only read the timeline when we really are in <from>.
      if [[ -n "$from" && "$(cs-label-canon "$current")" == "$from" ]]; then
        prev=$(cs-transition-previous-status "$repo" "$issue" "$from")
      fi
      next=$(cs-sm-next "$current" "$sm" "$prev")
      cs-labels-apply "$repo" "$issue" "$current" "$next"
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
