#!/usr/bin/env bash
# claim_gap.sh — detect In-Progress-status tasks that were never claimed.
#
# Complementary to reclaim_sweep.sh, which finds the OPPOSITE problem: a claim
# that was taken and then went stale (owner died). This script finds tasks
# actively being IMPLEMENTED (status: In Progress, or the legacy Coding alias
# — T20260809-355059) whose `claimed_by:` was never set in the first place —
# the gap left by any path that flips status via
# _session/status.sh (board visualization only, no lock) without also calling
# task_claim.sh acquire. `/ccxp` Phase 2a.3 (the pre-IPM design pass) is the
# confirmed live example (T20260610-248248).
#
# Design/Review are deliberately NOT flagged (T20260809-310724, corrected
# 2026-08-09): `Design`/`Review` + empty `claimed_by` is the NORMAL resting
# state of an unclaimed backlog design/review, not a coordination gap --
# `/todo next`'s peer-claim filter only skips a task when `claimed_by` is
# NON-empty, so nothing is actually invisible to claim-based coordination for
# those statuses. Verified live: 3 of 4 previously-flagged Design tasks had
# simply never been claimed (claimed_by empty since their seed-migration
# commit, untouched since) -- flagging them was the actual bug, not a symptom
# of one. `In Progress` (or the legacy `Coding` alias) is different: a task
# mid-implementation with no claimant IS a real gap (someone flipped status
# without acquiring the lock).
#
# Detector only — never mutates a file, unlike reclaim_sweep.sh's --apply
# mode. A false negative here just means a task looks fine when it's actually
# uncoordinated; a false positive is a harmless extra log line. Cheap log/
# Slack line, not a gate — matches reclaim_sweep.sh's own best-effort framing.
#
# Output: one line per gap, on stdout —
#   "unclaimed <task-id> — active status <status> with no claim"
# and the same to stderr via _session_log.
#
# Run once per `/ccxp` Phase-0 tick alongside reclaim_sweep.sh. Callers that
# want to avoid re-Slacking an unchanged finding every tick should call
# claim_gap_changed (below) instead of claim_gap directly.

set -uo pipefail

_CG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CG_DIR/task_claim.sh"   # _tc_* primitives + _session_log (via _lib.sh)

_cg_task_id_from_file() {
  # $1 path → the T<date>-<num> id embedded in the filename, or empty.
  basename "$1" .md | grep -oE '^T[0-9]{8}-[0-9]+' | head -1
}

claim_gap() {
  local dir f id status claimed_by
  dir="$(_tc_task_dir)"

  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    status="$(_tc_fm_get "$f" status)"
    case "$status" in Coding|"In Progress") : ;; *) continue ;; esac
    claimed_by="$(_tc_fm_get "$f" claimed_by)"
    { [ -z "$claimed_by" ] || [ "$claimed_by" = "none" ]; } || continue
    id="$(_cg_task_id_from_file "$f")"
    [ -n "$id" ] || continue

    printf 'unclaimed %s — active status %s with no claim\n' "$id" "$status"
    _session_log "  ⚠ claim_gap: $id is $status with no claimed_by"
  done

  return 0
}

# Where the last-posted gap list's hash is remembered, so callers can skip
# re-Slacking an unchanged finding every tick (T20260809-310724 root cause C:
# the sweep re-Slacked the same 7-task list 4+ consecutive ticks in one day).
# Repo-relative, same convention as TASK_CLAIM_DIR — override for tests.
_cg_state_file() {
  printf '%s' "${CLAIM_GAP_STATE_FILE:-.claude/state/claim-gap-last.json}"
}

# Hash just the flagged task IDs (sorted, deduped) — not full lines — so a
# cosmetic wording change wouldn't spuriously look "new", only an actual
# change in WHICH tasks are flagged does. Only ever called on non-empty
# input (claim_gap_changed short-circuits the empty case below) — but
# `|| true` guards the grep-no-match-under-pipefail case defensively anyway,
# since `grep` legitimately exits 1 on "no lines matched" and this function
# runs under the caller's `set -e`/`pipefail` (a bare failing pipeline in an
# assignment would otherwise abort the whole calling script, not just return
# a wrong value — caught by a direct unit test on this function).
_cg_list_hash() {
  local ids
  ids="$(grep -oE 'unclaimed T[0-9]{8}-[0-9]+' <<<"$1" | sort -u)" || true
  # claimant_sha256 (via task_claim.sh -> claimant-id.sh) rather than bare
  # sha256sum: that is GNU-only and absent on a stock macOS, where this whole
  # function silently produced an empty hash and defeated the change-detection
  # it exists for (T20260911-698434 adopted the portable helper).
  printf '%s' "$ids" | claimant_sha256
}

# Run claim_gap; only print its output when the flagged-ID list differs from
# the last recorded call (or there is no prior record). Same "stdout empty =
# nothing to do" contract claim_gap already had — ccxp's existing "Slack iff
# stdout non-empty" logic works unchanged; it just now also stays quiet on an
# UNCHANGED non-empty finding, not just on a genuinely-empty one. claim_gap's
# own per-line _session_log (stderr) still fires every call regardless, so
# local log visibility into "what's currently flagged" is never suppressed
# — only the repeat Slack post is. Never errors on a missing/corrupt state
# file; treats that the same as "no prior state" (i.e. always post).
#
# The empty-board case is handled BEFORE touching the hash machinery at all
# (not just short-circuited for output): sha256 of empty input is a real,
# non-trivial hash, not a sentinel for "nothing," so treating it like any
# other hash would (a) print a bare blank line instead of true silence on
# the first-ever clean run, and (b) clearing state here means a LATER
# reappearance of the exact same gap (after a genuinely clean tick) is
# correctly reported again, rather than silently matching the stale
# pre-clean hash still sitting in the state file.
claim_gap_changed() {
  local out hash state_file prev
  out="$(claim_gap "$@")"
  state_file="$(_cg_state_file)"

  if [ -z "$out" ]; then
    rm -f "$state_file" 2>/dev/null || true
    return 0
  fi

  hash="$(_cg_list_hash "$out")"
  prev=""
  if [ -f "$state_file" ]; then
    prev="$(jq -r '.hash // empty' "$state_file" 2>/dev/null)" || prev=""
  fi
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  jq -n --arg hash "$hash" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{hash:$hash, updated_at:$ts}' > "$state_file" 2>/dev/null || true
  if [ "$hash" != "$prev" ]; then
    printf '%s\n' "$out"
  fi
  return 0
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claim_gap_changed "$@"
fi
