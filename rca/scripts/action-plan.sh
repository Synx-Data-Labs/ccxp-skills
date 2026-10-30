#!/usr/bin/env bash
# action-plan.sh --class CLASS --confidence CONF [options] — the /rca step 6
# gating matrix as a plan: one line per action, on stdout. It only DECIDES
# which actions apply; it runs, posts and writes nothing. Classifying the
# failure (and judging Confirmed vs Unconfirmed) stays with the caller.
#
#   --class CLASS        our-code | upstream | configuration | transient |
#                        infrastructure (case-insensitive; "Our code" works too)
#   --confidence CONF    confirmed | unconfirmed
#   --kb-task-open [ID]  step 3.5 found an open task for this failure (only
#                        valid with confirmed); ID (T<id>) is echoed on TOP
#   --recent N           transient only (required unless --kb-task-open): how many times this failure
#                        happened in the last 7 days, this run included
#   --retry-result R     infrastructure only: pass | fail | pending (default
#                        pending = the retry has not finished yet)
#
# Output (one action per line, KEY[ key=value]; lines are in execution order):
#   RETRY                    rerun the failed jobs (infrastructure; always)
#   TOP [id=T<id>]           re-top the open task (step 3.5); replaces TASK
#   TASK kind=fix            file the task (our code / upstream / configuration,
#                            transient at 3+, infrastructure whose retry failed)
#   TASK kind=instrument     file the instrumentation task (unconfirmed)
#   PROMOTE                  mid-week auto-promote + scheduled: stamp (steps 3-4)
#   NOTE reason=<text>       nothing to file
#   IF_RETRY_FAILS <action>  the same, but only once the retry has failed
# Exit: 0 ok, 2 usage / inconsistent inputs (nothing is printed).
set -uo pipefail

die() { echo "action-plan.sh: $1" >&2; exit 2; }

cls="" conf="" kb_open=0 kb_id="" recent="" retry="pending"
while [ $# -gt 0 ]; do
  case "$1" in
    --class)       [ $# -ge 2 ] || die "--class needs a value"; cls="$2"; shift 2 ;;
    --confidence)  [ $# -ge 2 ] || die "--confidence needs a value"; conf="$2"; shift 2 ;;
    --recent)      [ $# -ge 2 ] || die "--recent needs a value"; recent="$2"; shift 2 ;;
    --retry-result) [ $# -ge 2 ] || die "--retry-result needs a value"; retry="$2"; shift 2 ;;
    --kb-task-open)
      kb_open=1; shift
      if [ $# -gt 0 ] && [[ "$1" =~ ^T[0-9]{8}-[0-9]{6}$ ]]; then kb_id="$1"; shift; fi ;;
    *) die "unknown argument: $1" ;;
  esac
done

cls="$(printf '%s' "$cls" | tr '[:upper:] ' '[:lower:]-')"
conf="$(printf '%s' "$conf" | tr '[:upper:]' '[:lower:]')"
retry="$(printf '%s' "$retry" | tr '[:upper:]' '[:lower:]')"
case "$cls" in our-code|upstream|configuration|transient|infrastructure) ;; *) die "--class must be our-code|upstream|configuration|transient|infrastructure, got '$cls'" ;; esac
case "$conf" in confirmed|unconfirmed) ;; *) die "--confidence must be confirmed|unconfirmed, got '$conf'" ;; esac
case "$retry" in pass|fail|pending) ;; *) die "--retry-result must be pass|fail|pending, got '$retry'" ;; esac
[ "$kb_open" = 0 ] || [ "$conf" = confirmed ] || die "--kb-task-open needs --confidence confirmed (step 3.5 runs only on a confirmed KB match)"
if [ "$cls" = transient ]; then
  # an open KB task re-tops without the 3+ check, so the count is then optional
  if [ "$kb_open" = 1 ] && [ -z "$recent" ]; then recent=0
  else [[ "$recent" =~ ^[0-9]+$ ]] || die "--recent N (a count) is required for a transient failure"; fi
elif [ -n "$recent" ]; then
  die "--recent applies to transient failures only"
fi
[ "$cls" = infrastructure ] || [ "$retry" = pending ] || die "--retry-result applies to infrastructure failures only"

out=()
add() { out+=("$1"); }
# task_actions <prefix>: the file-a-task pair (or the re-top when step 3.5 found one)
task_actions() {
  local p="$1" kind="$2"
  if [ "$kb_open" = 1 ]; then
    add "${p}TOP${kb_id:+ id=$kb_id}"
  else
    add "${p}TASK kind=$kind"
    add "${p}PROMOTE"
  fi
}

fix_kind=fix
[ "$conf" = unconfirmed ] && fix_kind=instrument

case "$cls" in
  our-code|upstream|configuration)
    task_actions "" "$fix_kind" ;;
  transient)
    if [ "$kb_open" = 1 ]; then
      task_actions "" fix                      # the 3+ check no longer applies
    elif [ "$conf" = unconfirmed ]; then
      task_actions "" instrument               # unconfirmed always files
    elif [ "$recent" -ge 3 ]; then
      task_actions "" fix
    else
      add "NOTE reason=transient, fewer than 3 occurrences in the last 7 days"
    fi ;;
  infrastructure)
    add "RETRY"                                # always, before anything else
    if [ "$kb_open" = 1 ]; then
      task_actions "" fix
    elif [ "$retry" = fail ] || [ "$conf" = unconfirmed ]; then
      # a failed retry files the fix task; unconfirmed files the instrumentation
      # task whatever the retry did
      task_actions "" "$fix_kind"
    elif [ "$retry" = pass ]; then
      add "NOTE reason=retry passed, no task needed"
    else
      task_actions "IF_RETRY_FAILS " fix
    fi ;;
esac

printf '%s\n' "${out[@]}"
