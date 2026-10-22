#!/usr/bin/env bash
# job-resume.sh <job-number>|<name> "<answer>"
# Delivers the user's answer to a finished or idle job by waking the SAME
# session with its saved options. Verified rules (bg-jobs.md): resume must be
# run with NO other flags, from the job's cwd, after stopping the live process
# (resuming a live session, or passing flags, starts an unsandboxed COPY).
# A job blocked on a permission prompt cannot be answered this way: attach.
set -euo pipefail

function resume() {
  (( $# == 2 )) || { echo "usage: job-resume.sh <job-number>|<name> \"<answer>\"" >&2; return 2; }
  local sel="$1" answer="$2" row id sid cwd waiting
  row="$(claude agents --json --all | jq -c --arg sel "$sel" '
    [.[] | select(.name == $sel or ((.name // "") | startswith("j" + $sel + "-")))][0] // empty')"
  [[ -n "$row" ]] || { echo "no such job: $sel" >&2; return 1; }
  id="$(jq -r .id <<< "$row")"
  sid="$(jq -r .sessionId <<< "$row")"
  cwd="$(jq -r .cwd <<< "$row")"
  waiting="$(jq -r '.waitingFor // ""' <<< "$row")"
  if [[ "$waiting" == "permission prompt" ]]; then
    echo "job $sel waits on a permission prompt; only 'claude attach $id' can answer it. Not resuming." >&2
    return 4
  fi
  claude stop "$id" >/dev/null 2>&1 || true
  # resuming while the process is still alive starts an unsandboxed copy:
  # wait (bounded) until the session shows no live status
  local i
  for ((i = 0; i < ${CCXP_JOB_STOP_WAIT:-10}; i++)); do
    [[ -z "$(claude agents --json --all | jq -r --arg id "$id" '.[] | select(.id == $id) | .status // empty')" ]] && break
    sleep 1
  done
  (cd "$cwd" && claude --resume "$sid" --bg "$answer")
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resume "$@"
fi
