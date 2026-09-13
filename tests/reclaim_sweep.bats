#!/usr/bin/env bats
# Tests for _session/reclaim_sweep.sh — the dead-claim reclaim sweep that
# backstops the heartbeat-free peer-mode lock (task_claim.sh).
#
# The sweep's own logic (file enumeration, status/claim filtering, the
# self-reclaim guard, the peer-mode gate, dry-run vs --apply) is unit-tested
# here by sourcing the script and pointing TASK_CLAIM_DIR at a tmp task dir.
# The liveness probe it delegates to — `task_claim.sh reclaimable`, whose only
# non-pure parts are the gh/git wrappers `_tc_pr_activity_days` and
# `_tc_days_since_last_commit` — is the integration seam: we override those two
# functions (DI, per dev/guidelines.md) so a test controls "owner alive?"
# without touching gh or git. (T20260622-404636: `_tc_has_open_pr` was replaced
# by `_tc_pr_activity_days` — open PRs are now reclaimable when their OWN
# activity is stale, not auto-excluded.)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Sourcing is side-effect-free (guarded dispatch). This also pulls in
  # task_claim.sh + _lib.sh.
  source "$REPO_ROOT/_session/reclaim_sweep.sh"

  export TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/TODO"
  mkdir -p "$TASK_CLAIM_DIR"

  # Default: peer mode ON (matches production default), owner looks DEAD.
  export CCXP_PEER_MODE=1
  _stub_dead_owner
}

# --- Liveness-seam stubs (override the gh/git I/O wrappers) ------------------

_stub_dead_owner() {
  # No recent PR activity, no recent commit, no live run → all signals stale →
  # reclaimable. _tc_has_live_run is a third gh-calling wrapper
  # (T20260724-312324) — stub it here too so these tests stay isolated from a
  # real `gh run list` call, same DI reasoning as the other two.
  _tc_pr_activity_days() { printf '99999'; }
  _tc_days_since_last_commit() { printf '99999'; }
  _tc_has_live_run() { printf ''; }
  export -f _tc_pr_activity_days _tc_days_since_last_commit _tc_has_live_run
}

_stub_live_owner() {
  # An open PR was touched recently (push/comment/review) → live, never reclaimed
  # — even though no commit landed on main (commit signal stale). This is the
  # post-T20260622-404636 path: liveness via PR activity, not has-a-PR.
  _tc_pr_activity_days() { printf '0'; }
  _tc_days_since_last_commit() { printf '99999'; }
  _tc_has_live_run() { printf ''; }
  export -f _tc_pr_activity_days _tc_days_since_last_commit _tc_has_live_run
}

_stub_abandoned_open_pr() {
  # An open PR exists but has been untouched past the window (dead owner) →
  # reclaimable. Guards the T20260622-404636 inversion: an open PR no longer
  # auto-blocks reclaim (the old has_pr=1->live rule leaked these forever).
  _tc_pr_activity_days() { printf '99999'; }
  _tc_days_since_last_commit() { printf '99999'; }
  _tc_has_live_run() { printf ''; }
  export -f _tc_pr_activity_days _tc_days_since_last_commit _tc_has_live_run
}

# --- Task-file fixture -------------------------------------------------------

_mk_claimed_task() {
  # $1 id  $2 status  $3 claimed_by → write $TASK_CLAIM_DIR/<id>-demo.md
  cat > "$TASK_CLAIM_DIR/$1-demo.md" <<EOF
---
name: Demo task
estimation: 1h
status: $2
owner: Alex
claimed_by: $3
priority: Low
---

# $1

## Notes
status: this BODY line must never be touched
claimed_by: nor this BODY line
EOF
}

# --- Reclaim path ------------------------------------------------------------

@test "--apply reclaims a Coding task with a dead claim (emits + frees the file)" {
  _mk_claimed_task T20260101-111111 Coding deadbeef@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed T20260101-111111"* ]]
  # File freed: claimed_by cleared, status back to Open.
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-111111-demo.md" claimed_by)" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-111111-demo.md" status)" = "Open" ]
}

@test "dry-run (no --apply) detects but does NOT edit the file" {
  _mk_claimed_task T20260101-222222 Review deadbeef@cdw
  run reclaim_sweep
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed T20260101-222222"* ]]
  # Untouched: still claimed, still Review.
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-222222-demo.md" claimed_by)" = "deadbeef@cdw" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-222222-demo.md" status)" = "Review" ]
}

# --- Live claim left alone ---------------------------------------------------

@test "leaves a live claim (recent PR activity) untouched" {
  _stub_live_owner
  _mk_claimed_task T20260101-333333 Coding somebody@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"reclaimed"* ]]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-333333-demo.md" claimed_by)" = "somebody@cdw" ]
}

@test "reclaims an open-PR task whose PR is ABANDONED (T20260622-404636: open PRs no longer auto-blocked)" {
  _stub_abandoned_open_pr
  # Legacy-shaped ("<hex-sid>@<machine>", T20260724-312324's format pre-check)
  # so this dead-session fixture is actually session-shaped, not a mnemonic
  # string the tightened check would misread as a human override.
  _mk_claimed_task T20260101-555555 Review deadc0de@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed T20260101-555555"* ]]
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-555555-demo.md" claimed_by)" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-555555-demo.md" status)" = "Open" ]
}

# --- Status filter -----------------------------------------------------------

@test "ignores non-active statuses (Open/Done) even with a stray claim" {
  _mk_claimed_task T20260101-444444 Open ghost@cdw
  _mk_claimed_task T20260101-555555 Done ghost@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"reclaimed"* ]]
}

# --- Self-reclaim guard ------------------------------------------------------

@test "never reclaims THIS session's own active claim" {
  mine="$(_tc_claimant_id)"
  _mk_claimed_task T20260101-666666 Coding "$mine"
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"reclaimed"* ]]
  # Our claim survives.
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-666666-demo.md" claimed_by)" = "$mine" ]
}

# --- Peer-mode gate ----------------------------------------------------------

@test "no-op when peer mode is off (CCXP_PEER_MODE=0), even when reclaimable" {
  export CCXP_PEER_MODE=0
  _mk_claimed_task T20260101-777777 Coding deadbeef@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"reclaimed"* ]]
  # Untouched.
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T20260101-777777-demo.md" claimed_by)" = "deadbeef@cdw" ]
}

@test "active by default when CCXP_PEER_MODE is unset (default-on, matches the lock)" {
  unset CCXP_PEER_MODE
  _mk_claimed_task T20260101-888888 Coding deadbeef@cdw
  run reclaim_sweep --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed T20260101-888888"* ]]
}

# --- Logging (best-effort, loud) ---------------------------------------------

@test "logs each reclaim to stderr (never silent)" {
  _mk_claimed_task T20260101-999999 Coding deadbeef@cdw
  run reclaim_sweep --apply
  [[ "$output" == *"freed T20260101-999999"* ]]   # _session_log line on stderr; run merges 2>&1
}
