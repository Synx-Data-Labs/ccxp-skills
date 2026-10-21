#!/usr/bin/env bash
# label_names.sh — the ONE place /customer-support's label names live
# (T20261021-266225). state_machine.sh, labels.sh, transition.sh, audit.sh and
# sweep.sh source this file; none of them (nor the tests, where practical)
# spell a label name as a literal. To rename a label again: change its CS_L_*
# value here and append the previous name to CS_LABEL_ALIASES.
#
# Sourceable, functions/vars only, idempotent.

CS_L_NEW="new"
CS_L_TRIAGED="triaged"
CS_L_IN_PROGRESS="in-progress"
CS_L_DELIVERED="delivered"
CS_L_BLOCKED="blocked"
CS_L_NEEDS_UPSTREAM="needs-upstream"

CS_REJECT_LABELS="wontfix invalid duplicate"

# Primary (mutually exclusive) states, in lifecycle order.
CS_PRIMARY_LABELS="${CS_L_NEW} ${CS_L_TRIAGED} ${CS_L_IN_PROGRESS} ${CS_L_DELIVERED}"

# Retired names, <old>=<current>. Readers (state machine, audit, primary
# lookup) accept them so stale issues still pass; writers never emit them.
# 2026-10-21: triage -> new, accepted -> triaged.
CS_LABEL_ALIASES="triage=${CS_L_NEW} accepted=${CS_L_TRIAGED}"

# cs-label-canon <label> — prints the current name for a (possibly retired) label.
cs-label-canon() {
  local label="${1:-}" pair
  for pair in $CS_LABEL_ALIASES; do
    if [[ "${pair%%=*}" == "$label" ]]; then
      echo "${pair#*=}"
      return 0
    fi
  done
  echo "$label"
}

# cs-label-primary-names — every name a reader accepts as a primary label:
# the current ones plus the retired aliases.
cs-label-primary-names() {
  local pair
  echo "$CS_PRIMARY_LABELS"
  for pair in $CS_LABEL_ALIASES; do
    grep -qwF "$(cs-label-canon "${pair%%=*}")" <<<"$CS_PRIMARY_LABELS" && echo "${pair%%=*}"
  done
}
