#!/usr/bin/env bash
# reclaim_sweep.sh [--apply] — free dead task-claims (no-heartbeat backstop).
#
# The peer-mode lock (_session/task_claim.sh, build-pipeline-repo
# T20260611-104067) is HEARTBEAT-FREE by design: a claim is a durable
# `claimed_by: <machine>:<working-dir>` line on `main`, which is what lets it
# survive restarts. The flip side — a claim whose owning CC session has *died*
# (crash / kill / reboot) is never released. The task stays `status: Coding`,
# `claimed_by: <dead session>`, and peer-mode `/todo next` excludes it from
# every OTHER session, so it silently leaks out of the backlog.
#
# NOTE (T20260615-169917): claimant id is now clone-stable (<machine>:<dir>), so
# a claim left by a crashed prior invocation IN THE SAME CLONE reads as the new
# live session's own — release-on-pickup (`task_claim.sh release-others`) frees it
# at the next pick. This sweep still frees same-clone-crash claims that never
# re-pick (seen as "other" + stale from a DIFFERENT clone) and all foreign dead
# claims; the self-guard below intentionally never frees the running clone's own.
#
# On-demand reclaim already exists (`/drive` + `/todo` call `task_claim.sh
# reclaimable` when they happen to consider a task), but nothing PROACTIVELY
# sweeps. This script is that sweep: run once per ccxp Phase-0 tick, it
# enumerates actively-claimed task files, asks the unit-tested `reclaimable`
# primitive whether each owner is gone, and frees the dead ones.
#
# Modes:
#   (default)   DRY-RUN — detect + print reclaimable claims; edit nothing.
#   --apply     detect + release each (clear claimed_by, set status: Open) in
#               place, so the ccxp recipe can commit the
#               freed task files to `main` via one batched claim-style PR.
#
# Output (both modes): one line per reclaimable claim, on stdout —
#   "reclaimed <task-id> — dead claimant <by> (was <status>)"
# and the same loudly to stderr via _session_log. A reclaimed task may have had
# real WIP, so a reclaim is NEVER silent — the ccxp recipe Slacks each line.
#
# Peer-mode gate: the sweep is the lock's backstop, so it is ACTIVE whenever
# peer mode is — i.e. by default. It no-ops only on the explicit opt-out
# `CCXP_PEER_MODE=0`, exactly mirroring the lock's own default-on semantics
# (ccxp-skills #93 / T20260611-104067). (The task's original test-plan bullet
# said "no-op when unset"; that predated peer-mode default-on. Gating the
# backstop off-by-default while the lock it protects is on-by-default would
# re-open the very symmetry gap #93 closed — so the sweep is default-on too.)
#
# Self-reclaim guard: never frees a claim held by THIS session (it's not dead).
# Best-effort: always exits 0 so it can never block the ccxp tick.

set -uo pipefail

_RS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_RS_DIR/task_claim.sh"   # _tc_* primitives + _session_log (via _lib.sh)

_rs_peer_mode_off() {
  # Peer mode is on by default; only the explicit "0" disables it.
  [ "${CCXP_PEER_MODE:-1}" = "0" ]
}

_rs_task_id_from_file() {
  # $1 path → the T<date>-<num> id embedded in the filename, or empty.
  basename "$1" .md | grep -oE '^T[0-9]{8}-[0-9]+' | head -1
}

reclaim_sweep() {
  # $1 (optional) "--apply" → release reclaimable claims in place.
  local apply="${1:-}"

  if _rs_peer_mode_off; then
    _session_log "  - reclaim_sweep: peer mode off (CCXP_PEER_MODE=0) — no-op"
    return 0
  fi

  local dir mine f id status claimed_by verdict shown
  dir="$(_tc_task_dir)"
  mine="$(_tc_claimant_id)"

  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    status="$(_tc_fm_get "$f" status)"
    # Only actively-claimed tasks can have a leaked claim.
    case "$status" in Coding|Review) : ;; *) continue ;; esac
    claimed_by="$(_tc_fm_get "$f" claimed_by)"
    { [ -n "$claimed_by" ] && [ "$claimed_by" != "none" ]; } || continue
    # Self-reclaim guard — our own claim is not dead. Short-circuit BEFORE the
    # liveness probe so a (mistakenly) reclaimable verdict can't free it.
    [ "$claimed_by" = "$mine" ] && continue
    id="$(_rs_task_id_from_file "$f")"
    [ -n "$id" ] || continue

    verdict="$(_tc_reclaimable "$id")"
    [ "$verdict" = "reclaimable" ] || continue

    if [ "$apply" = "--apply" ]; then
      if ! _tc_release "$id" Open >/dev/null; then
        _session_log "  ! reclaim_sweep: release failed for $id — skipping"
        continue
      fi
    fi
    # Render via claimant_display: a raw current-format id is 26 characters of
    # opaque hash, and the short form plus role is what a person reading this
    # line can actually use. Legacy values pass through unchanged.
    shown="$(claimant_display "$claimed_by" "$(_tc_fm_get "$f" claimed_role)")"
    printf 'reclaimed %s — dead claimant %s (was %s)\n' "$id" "$shown" "$status"
    _session_log "  ⚠ reclaim_sweep: freed $id (dead claimant: $shown, was $status)"
  done

  return 0
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  reclaim_sweep "$@"
fi
