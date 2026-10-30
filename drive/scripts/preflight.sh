#!/usr/bin/env bash
# preflight.sh <task-id|-> [--auto-selected] — /drive Phase 0 skip rule and the
# Phase 1 pre-claim gate chain, as one verdict.
#
#   <task-id>        an explicit id: run the gates below, in this order
#   -                bare /drive (auto-pick): nothing to gate (/todo next only
#                    surfaces free, unfrozen tasks of this clone)
#   --auto-selected  the id came from an orchestrator (/autopilot), not a human
#
# Gates (first failure wins):
#   1 clone-locality  _taskid/in-this-repo.sh: absent here -> cross-repo,
#                     only in dev/JOURNAL -> closed
#   2 claim           _session/task_claim.sh: claimed_by held by someone else and
#                     not reclaimable -> held (mine, free or reclaimable pass);
#                     skipped when CCXP_PEER_MODE=0 (no claim registry then)
#   3 lint-frozen     _session/lint_frozen.sh: a claim PR could not merge -> frozen
#
# stdout, one line:  verdict=<v> phase0=<run|skip> detail=<free text to end of line>
#   phase0=skip when a human gave an explicit id (no --auto-selected): skip the PR drain.
# Exit codes: 0 go | 10 held | 11 frozen | 12 cross-repo | 13 closed | 14 refused
# (cross-repo while DRIVE_STRICT_CLONE=1: abort) | 2 usage.
# Judgment stays with the caller: what to do on cross-repo (clone the hub fresh),
# whether to re-pick on held/frozen, whether a task is Blocked (Phase 6).
#
# Env (tests): IN_THIS_REPO_SH, TASK_CLAIM_SH, LINT_FROZEN_SH override the helpers;
# TASK_CLAIM_DIR (default dev/TODO) is where the task file is looked up.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN_THIS_REPO_SH="${IN_THIS_REPO_SH:-$HERE/../../_taskid/in-this-repo.sh}"
TASK_CLAIM_SH="${TASK_CLAIM_SH:-$HERE/../../_session/task_claim.sh}"
LINT_FROZEN_SH="${LINT_FROZEN_SH:-$HERE/../../_session/lint_frozen.sh}"

usage() { echo "usage: preflight.sh <task-id|-> [--auto-selected]" >&2; exit 2; }

id="" auto=0
for a in "$@"; do
  case "$a" in
    --auto-selected) auto=1 ;;
    -h|--help) usage ;;
    -) [ -z "$id" ] || usage; id=- ;;
    -*) usage ;;
    *) [ -z "$id" ] || usage; id="$a" ;;
  esac
done
[ -n "$id" ] || usage
if [ "$id" != - ] && ! [[ "$id" =~ ^T[0-9]+(-[0-9]+)?$ ]]; then
  echo "preflight.sh: not a task id: $id" >&2; exit 2
fi

phase0=run
if [ "$id" != - ] && [ "$auto" = 0 ]; then phase0=skip; fi

verdict() { # <verdict> <exit> <detail>
  printf 'verdict=%s phase0=%s detail=%s\n' "$1" "$phase0" "$3"
  exit "$2"
}

[ "$id" != - ] || verdict go 0 auto-pick

# 1 clone-locality
err="$(bash "$IN_THIS_REPO_SH" "$id" 2>&1 >/dev/null)"; rc=$?
case "$rc" in
  0) ;;
  3) verdict closed 13 "closed here (task file is in dev/JOURNAL); do not re-work, file a new task" ;;
  1|2)
    slug="$(printf '%s\n' "$err" | sed -n 's/^  Clone: //p' | head -n1)"
    note="not in this clone; hub is ${slug:-unknown (slug could not be detected)}"
    [ "$rc" = 1 ] && verdict refused 14 "$note; DRIVE_STRICT_CLONE=1 forbids working it from this clone"
    verdict cross-repo 12 "$note; clone it fresh" ;;
  *) echo "preflight.sh: in-this-repo.sh failed ($rc)" >&2; exit 2 ;;
esac

# 2 claim
note=free
file=""
for m in "${TASK_CLAIM_DIR:-dev/TODO}/$id"-*.md "${TASK_CLAIM_DIR:-dev/TODO}/$id".md; do [ -e "$m" ] && { file="$m"; break; }; done
if [ -z "$file" ]; then
  note="no task file in ${TASK_CLAIM_DIR:-dev/TODO} (parked?); claim and freeze checks skipped"
else
  if [ "${CCXP_PEER_MODE:-1}" = 0 ]; then
    note="peer mode off; claim check skipped"
  elif row="$(bash "$TASK_CLAIM_SH" read "$id" 2>/dev/null)"; then
    by="${row#*$'\t'}"
    if [ -n "$by" ]; then
      mine="$(bash "$TASK_CLAIM_SH" claimant-id 2>/dev/null || true)"
      if [ -n "$mine" ] && [ "$by" = "$mine" ]; then
        note=mine
      elif [ "$(bash "$TASK_CLAIM_SH" reclaimable "$id" 2>/dev/null || true)" = reclaimable ]; then
        note="reclaimable (stale claim by $by)"
      else
        verdict held 10 "claimed_by $by (live); re-pick via /todo next, or exit for an explicit id"
      fi
    fi
  fi
  # 3 lint-frozen
  if bash "$LINT_FROZEN_SH" is-frozen "$file" >/dev/null 2>&1; then
    verdict frozen 11 "lint-frozen ($file): a claim PR cannot merge; re-pick, or exit with this reason"
  fi
fi
verdict go 0 "$note"
