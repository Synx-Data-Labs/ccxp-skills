#!/usr/bin/env bash
# label_names.sh — the ONE place /customer-support's label names live
# (T20261021-266225, scheme v2 T20261021-421263). state_machine.sh, labels.sh,
# transition.sh, audit.sh and sweep.sh source this file; none of them (nor the
# tests, where practical) spell a label name as a literal. To rename a label
# again: change its CS_L_* value here and append the previous name to
# CS_LABEL_ALIASES.
#
# Scheme v2 (2026-10-21): every lifecycle state is a `status:*` label, exactly
# one per issue (open or closed). blocked/needs-upstream are statuses, not
# stackable modifiers. `invalid` is dropped (a not-a-bug rejection = wontfix).
#
# Sourceable, functions/vars only, idempotent.

# status:* — exactly one per issue.
CS_L_NEW="status:new"
CS_L_TRIAGED="status:triaged"
CS_L_IN_PROGRESS="status:in-progress"
CS_L_BLOCKED="status:blocked"
CS_L_NEEDS_UPSTREAM="status:needs-upstream"
CS_L_DELIVERED="status:delivered"
CS_L_WONTFIX="status:wontfix"
CS_L_DUPLICATE="status:duplicate"

# type:* / severity:* / kb:* — not touched by the lifecycle scripts, but named
# here so the scheme is complete and the aliases below resolve them.
CS_L_TYPE_BUG="type:bug"
CS_L_TYPE_ENHANCEMENT="type:enhancement"
CS_L_TYPE_QUESTION="type:question"
CS_L_SEVERITY_1="severity:1"
CS_L_SEVERITY_2="severity:2"
CS_L_SEVERITY_3="severity:3"
CS_L_SEVERITY_4="severity:4"
CS_L_KB_CANDIDATE="kb:candidate"
CS_L_KB_PUBLISHED="kb:published"
# Unchanged, listed for reference: area:*, family:*, substrate:*, track:poc.

# Accepted values of `reject --reason`; each is also the terminal status label.
CS_REJECT_REASONS="wontfix duplicate"

# Every status label (what `audit` requires exactly one of, open or closed).
CS_STATUS_LABELS="${CS_L_NEW} ${CS_L_TRIAGED} ${CS_L_IN_PROGRESS} ${CS_L_BLOCKED} ${CS_L_NEEDS_UPSTREAM} ${CS_L_DELIVERED} ${CS_L_WONTFIX} ${CS_L_DUPLICATE}"

# Working (pre-close) states, in lifecycle order: the valid sources of a
# transition. Terminal wontfix/duplicate are statuses but not working states.
CS_PRIMARY_LABELS="${CS_L_NEW} ${CS_L_TRIAGED} ${CS_L_IN_PROGRESS} ${CS_L_BLOCKED} ${CS_L_NEEDS_UPSTREAM} ${CS_L_DELIVERED}"

# Retired names, <old>=<current>. Readers (state machine, audit, primary
# lookup, sweep) accept them so issues work before AND after the GitHub label
# rename; writers never emit them.
# 2026-10-21 (v1): triage -> new, accepted -> triaged. (v2): bare -> prefixed.
CS_LABEL_ALIASES="triage=${CS_L_NEW} accepted=${CS_L_TRIAGED} \
new=${CS_L_NEW} triaged=${CS_L_TRIAGED} in-progress=${CS_L_IN_PROGRESS} \
blocked=${CS_L_BLOCKED} needs-upstream=${CS_L_NEEDS_UPSTREAM} \
delivered=${CS_L_DELIVERED} wontfix=${CS_L_WONTFIX} duplicate=${CS_L_DUPLICATE} \
invalid=${CS_L_WONTFIX} \
bug=${CS_L_TYPE_BUG} enhancement=${CS_L_TYPE_ENHANCEMENT} question=${CS_L_TYPE_QUESTION} \
sev1=${CS_L_SEVERITY_1} sev2=${CS_L_SEVERITY_2} sev3=${CS_L_SEVERITY_3} sev4=${CS_L_SEVERITY_4} \
kb-candidate=${CS_L_KB_CANDIDATE} kb-published=${CS_L_KB_PUBLISHED}"

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

# cs-label-names <current-label> — one name per line: the current name plus
# every retired alias that maps to it (what a reader must match on).
cs-label-names() {
  local want
  want=$(cs-label-canon "${1:?label required}")
  echo "$want"
  local pair
  for pair in $CS_LABEL_ALIASES; do
    [[ "${pair#*=}" == "$want" ]] && echo "${pair%%=*}"
  done
  return 0
}

# cs-label-primary-names — every name a reader accepts as a status label
# (one per line): the current ones plus the retired aliases.
cs-label-primary-names() {
  local s
  for s in $CS_STATUS_LABELS; do
    cs-label-names "$s"
  done
}

# cs-label-names-json <current-label> — cs-label-names as a JSON array (jq).
cs-label-names-json() {
  cs-label-names "$1" | jq -R . | jq -sc .
}
