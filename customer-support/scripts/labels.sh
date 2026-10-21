#!/usr/bin/env bash
# labels.sh — gh I/O for /customer-support's label-driven lifecycle
# (T20261012-373882). Reads/writes issue labels and close state. The
# transition *rules* live in state_machine.sh (pure, no I/O); this file is
# the thin GitHub-talking layer that applies a decided transition.
#
# gh wrapper — DI seam via CS_GH (tests inject a stub here), mirroring
# _gh/ci-triage.sh's CI_TRIAGE_GH / _taskid/url.sh's TASKID_GH convention.
set -euo pipefail

# shellcheck source=./label_names.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/label_names.sh"

CS_GH="${CS_GH:-}"
cs-gh() {
  if [[ -n "$CS_GH" ]]; then
    "$CS_GH" "$@"
  else
    gh "$@"
  fi
}

# cs-labels-primary <owner/repo> <issue-number>
# Prints the single current status label, or "none" if the issue carries
# none (e.g. a legacy issue). Fails loudly if MORE than one
# primary label is present — that is the exact invariant violation `audit`
# exists to catch; a transition should never proceed against a dirty state.
cs-labels-primary() {
  local repo="${1:?owner/repo required}" issue="${2:?issue number required}"
  local json names found="" n
  # Current status names plus retired aliases (a not-yet-renamed issue is
  # still valid; the label actually present is printed so a later
  # --remove-label hits the real one).
  json=$(cs-gh issue view "$issue" --repo "$repo" --json labels)
  names=$(echo "$json" | jq -r '.labels[].name')
  for n in $(cs-label-primary-names); do
    if grep -qxF "$n" <<<"$names"; then
      if [[ -n "$found" ]]; then
        echo "error: issue ${repo}#${issue} carries more than one primary label (${found}, ${n}) — invariant violated, run 'audit'" >&2
        return 1
      fi
      found="$n"
    fi
  done
  echo "${found:-none}"
}

# cs-labels-apply <owner/repo> <issue> <old-primary|none> <new-primary|CLOSED:reason>
# Removes the old status label (if any), adds the new one, or closes the
# issue when new starts with CLOSED: (completed|timeout keep the label;
# wontfix|duplicate swap in the terminal status label).
cs-labels-apply() {
  local repo="${1:?owner/repo required}" issue="${2:?issue number required}"
  local old="${3:?old state required}" new="${4:?new state required}"

  # accept/timeout closes keep the delivered status label (it is the one
  # status an accepted/timed-out issue carries); every other transition
  # removes the old status first.
  if [[ -n "$old" && "$old" != "none" && "$new" != "CLOSED:timeout" && "$new" != "CLOSED:completed" ]]; then
    cs-gh issue edit "$issue" --repo "$repo" --remove-label "$old"
  fi

  case "$new" in
    CLOSED:completed)
      cs-gh issue close "$issue" --repo "$repo" --reason completed
      ;;
    CLOSED:timeout)
      # Delivered-timeout close (T20261021-266225): NOT an acceptance. The
      # delivered label is kept (the caller's marker comment is the signature)
      # so a reopen routes through `start` (delivered -> in-progress).
      cs-gh issue close "$issue" --repo "$repo" --reason completed
      ;;
    CLOSED:wontfix)
      # Terminal status label replaces the old status BEFORE closing, so a
      # closed issue still carries exactly one status:* label.
      cs-gh issue edit "$issue" --repo "$repo" --add-label "$CS_L_WONTFIX"
      cs-gh issue close "$issue" --repo "$repo" --reason "not planned"
      ;;
    CLOSED:duplicate)
      cs-gh issue edit "$issue" --repo "$repo" --add-label "$CS_L_DUPLICATE"
      cs-gh issue close "$issue" --repo "$repo" --reason "duplicate"
      ;;
    *)
      cs-gh issue edit "$issue" --repo "$repo" --add-label "$new"
      ;;
  esac
}

# cs-labels-toggle <owner/repo> <issue> <label> <on|off>
cs-labels-toggle() {
  local repo="${1:?owner/repo required}" issue="${2:?issue number required}"
  local label="${3:?label required}" mode="${4:?on|off required}"
  case "$mode" in
    on) cs-gh issue edit "$issue" --repo "$repo" --add-label "$label" ;;
    off) cs-gh issue edit "$issue" --repo "$repo" --remove-label "$label" ;;
    *)
      echo "usage: cs-labels-toggle <owner/repo> <issue> <label> <on|off>" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    primary) cs-labels-primary "$@" ;;
    apply) cs-labels-apply "$@" ;;
    toggle) cs-labels-toggle "$@" ;;
    *)
      echo "usage: labels.sh <primary|apply|toggle> ..." >&2
      exit 2
      ;;
  esac
fi
