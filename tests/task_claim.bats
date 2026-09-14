#!/usr/bin/env bats
# Tests for _session/task_claim.sh — the durable, main-resident task-claim lib.
#
# Pure logic (frontmatter get/set, the own-or-defer decision, the reclaim
# decision, claimant-id format, PR-ownership derivation) is tested by sourcing
# the script. The keystone test exercises the CORRECTNESS INVARIANT against real
# git: two concurrent claims of the same task MUST collide at merge — that
# conflict IS the lock. The thin gh/git I/O wrappers (_tc_pr_activity_days,
# _tc_days_since_last_commit, _tc_resolve_task_location, _tc_fetch_fm_field) are
# integration surface; _tc_pr_owner's DECISION is exercised by stubbing them.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Dispatch block is guarded by [ "${BASH_SOURCE[0]}" = "${0}" ], so sourcing
  # is side-effect-free.
  source "$REPO_ROOT/_session/task_claim.sh"
}

_mk_task_file() {
  # $1 path → a task file whose BODY also contains decoy "status:"/"claimed_by:"/
  # "owner:" lines, so we prove fm_get/fm_set touch ONLY the leading frontmatter
  # fence. `owner:` is the informal human-assignee field and must never be touched.
  cat > "$1" <<'EOF'
---
name: Demo task
estimation: 1h
status: Open
owner: Alex
claimed_by:
priority: Low
---

# T-demo

## Notes
status: this BODY line must never be touched
claimed_by: nor this BODY line
owner: nor this human-assignee BODY line
EOF
}

# --- frontmatter get/set (pure) ---------------------------------------------

@test "_tc_fm_get reads a frontmatter field and returns empty for an empty one" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  [ "$(_tc_fm_get "$f" status)" = "Open" ]
  [ -z "$(_tc_fm_get "$f" claimed_by)" ]
}

@test "_tc_fm_get ignores body lines that look like frontmatter fields" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  [ "$(_tc_fm_get "$f" status)" = "Open" ]
}

@test "_tc_fm_set replaces an existing field and leaves the body untouched" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  _tc_fm_set "$f" status Coding
  [ "$(_tc_fm_get "$f" status)" = "Coding" ]
  grep -qx 'status: this BODY line must never be touched' "$f"
  grep -qx 'claimed_by: nor this BODY line' "$f"
}

@test "_tc_fm_set never touches the human-assignee owner: field" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  _tc_fm_set "$f" claimed_by "sid@host"
  # the human owner is preserved exactly
  [ "$(_tc_fm_get "$f" owner)" = "Alex" ]
}

@test "_tc_fm_set with an empty value writes a bare 'field:' (no trailing space)" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  _tc_fm_set "$f" claimed_by "x@h"
  _tc_fm_set "$f" claimed_by ""
  grep -qx 'claimed_by:' "$f"
}

@test "_tc_fm_set inserts an absent field before the closing fence" {
  f="$BATS_TEST_TMPDIR/t.md"
  printf -- '---\nstatus: Open\n---\n\nbody\n' > "$f"
  _tc_fm_set "$f" claimed_by "x@h"
  [ "$(_tc_fm_get "$f" claimed_by)" = "x@h" ]
  [ "$(grep -c -- '^---$' "$f")" -eq 2 ]
}

# --- own-or-defer decision (the anti-steal core) ----------------------------

@test "_tc_decide: empty or 'none' -> none (free to take)" {
  [ "$(_tc_decide '' me)" = "none" ]
  [ "$(_tc_decide none me)" = "none" ]
}

@test "_tc_decide: same claimant -> mine (idempotent, not a steal)" {
  [ "$(_tc_decide me me)" = "mine" ]
}

@test "_tc_decide: different claimant -> other (MUST NOT steal)" {
  [ "$(_tc_decide someoneelse me)" = "other" ]
}

# --- reclaim decision (pure) ------------------------------------------------
# Signature: _tc_reclaim_decide <status> <claimed_by> <commit_days> <pr_days> <stale>
# (T20260622-404636: the old has_pr=1->live exclusion was replaced by PR-activity
#  gating; the irrelevant signal is large — 99999 — so the AND reduces to "the
#  relevant signal is stale".)

@test "_tc_reclaim_decide: non-active status -> live" {
  [ "$(_tc_reclaim_decide Open c 99 99 2)" = "live" ]
  [ "$(_tc_reclaim_decide Done c 99 99 2)" = "live" ]
}

@test "_tc_reclaim_decide: active but unclaimed -> live" {
  [ "$(_tc_reclaim_decide Coding '' 99 99 2)" = "live" ]
}

@test "_tc_reclaim_decide: no-PR task, recent commit on main -> live" {
  # pr_days large (no open PR); commit on main is recent -> live.
  # claimed_by is session-shaped ("h:/p") so the T20260724-312324 format
  # pre-check doesn't short-circuit these staleness-window cases.
  [ "$(_tc_reclaim_decide Coding h:/p 0 99999 2)" = "live" ]
}

@test "_tc_reclaim_decide: no-PR task, stale commit -> reclaimable" {
  [ "$(_tc_reclaim_decide Coding h:/p 3 99999 2)" = "reclaimable" ]
  [ "$(_tc_reclaim_decide Review h:/p 2 99999 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: open-PR task, RECENT PR activity -> live (no longer auto-blocked, but live work protected)" {
  # commit_days large (work sits on the unmerged PR branch, invisible on main);
  # the PR was touched recently (push/comment/review) -> live, NOT reclaimed.
  [ "$(_tc_reclaim_decide Coding h:/p 99999 0 2)" = "live" ]
  [ "$(_tc_reclaim_decide Review h:/p 99999 1 2)" = "live" ]
}

@test "_tc_reclaim_decide: open-PR task, ABANDONED PR -> reclaimable (the T20260622-404636 fix)" {
  # The case the old has_pr=1->live rule leaked forever: an open PR under a dead
  # owner, untouched past the window, is now reclaimable.
  [ "$(_tc_reclaim_decide Coding h:/p 99999 3 2)" = "reclaimable" ]
  [ "$(_tc_reclaim_decide Review h:/p 99999 5 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: BOTH signals must be stale (AND) -> live if either is fresh" {
  [ "$(_tc_reclaim_decide Coding h:/p 0 9 2)" = "live" ]   # fresh commit, stale PR
  [ "$(_tc_reclaim_decide Coding h:/p 9 0 2)" = "live" ]   # stale commit, fresh PR
}

# --- T20260724-312324: non-session claimant format pre-check ---------------
# A claimed_by value that isn't the "<host>:<path>" shape _tc_claimant_id
# produces (T20260721-132681's fix) is deliberately human-assigned (e.g. a
# maintainer hand-editing claimed_by to a bare name to take a task off the
# autonomous loop) and must NEVER be auto-reclaimed, regardless of how stale
# the git/PR activity signals are.

@test "_tc_reclaim_decide: non-session claimant (bare name, no colon) -> live even with fully stale signals" {
  [ "$(_tc_reclaim_decide Coding Alex 99 99 2)" = "live" ]
  [ "$(_tc_reclaim_decide Review Alex 99999 99999 2)" = "live" ]
}

@test "_tc_reclaim_decide: non-session claimant (colon but no absolute-path shape) -> live" {
  # Guards against a loose "has a colon" check matching non-claimant-shaped
  # values that happen to contain ':' (e.g. a time-of-day or ratio string).
  [ "$(_tc_reclaim_decide Coding notahost:notapath 99 99 2)" = "live" ]
}

@test "_tc_reclaim_decide: human email/mention override ('@' but not legacy sid shape) -> live" {
  # Guards against a loose "has an '@'" check matching a human-assigned
  # override that happens to contain '@' (an email address, or an
  # '@'-mention) — must still be treated as human-assigned and NEVER
  # auto-reclaimed, not misread as the legacy "<sid>@<machine>" shape.
  [ "$(_tc_reclaim_decide Coding alex@example.com 99 99 2)" = "live" ]
  [ "$(_tc_reclaim_decide Coding @Alex 99 99 2)" = "live" ]
}

@test "_tc_reclaim_decide: session-shaped claimant ('h:/p') is NOT caught by the format pre-check" {
  # Sanity check that the format pre-check doesn't over-fire on the normal
  # shape — reclaimability still falls through to the staleness window.
  [ "$(_tc_reclaim_decide Coding h:/p 99 99 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: LEGACY '<sid>@<machine>' claimant is also session-shaped, not human-assigned" {
  # Pre-T20260615-169917 claims (e.g. real board data like 8d907ecf@cdw) must
  # still age out via this staleness window ("ages out via the reclaim sweep",
  # per the "legacy <sid>@<machine> claim" test above) — the format pre-check
  # must not conflate "not the CURRENT shape" with "human-assigned".
  [ "$(_tc_reclaim_decide Coding deadbeef@cdw 99 99 2)" = "reclaimable" ]
}

# --- T20260911-698434: cc1- claimant shape (reader, landed before the writer) -

@test "_tc_reclaim_decide: cc1- claimant is session-shaped -> subject to the staleness window" {
  # The whole point of landing this arm first: without it a cc1- value
  # matches neither the "<host>:<path>" nor the legacy "<sid>@<machine>"
  # shape, falls to the human-override branch, and becomes permanently
  # unreclaimable.
  [ "$(_tc_reclaim_decide Coding cc1-a1b2c3d4:9f8e7d6c5b4a3210 99 99 2)" = "reclaimable" ]
  [ "$(_tc_reclaim_decide Review cc1-a1b2c3d4:9f8e7d6c5b4a3210 99 99 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: cc1- claimant still respects a fresh signal -> live" {
  [ "$(_tc_reclaim_decide Coding cc1-a1b2c3d4:9f8e7d6c5b4a3210 0 99999 2)" = "live" ]
}

@test "_tc_reclaim_decide: a LEGACY plaintext claim whose host begins 'cc1-' is not confused for the new shape" {
  # `cc1-box:/home/x` is a <host>:<path> claim from a machine named
  # "cc1-box"; it must match the *:/* arm, not the anchored cc1- regex.
  # Both are session-shaped, so the observable outcome is the same — the
  # test pins that neither arm ordering nor the anchor lets it fall through
  # to the human-override branch.
  [ "$(_tc_reclaim_decide Coding cc1-box:/home/x 99 99 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: cc1--prefixed values that are NOT the exact shape stay human-assigned" {
  # The anchor is what makes this hold: a bare "cc1-" glob would have
  # swallowed all of these and silently made hand-assigned tasks reclaimable.
  [ "$(_tc_reclaim_decide Coding cc1-Alex 99 99 2)" = "live" ]
  [ "$(_tc_reclaim_decide Coding cc1-a1b2c3d4 99 99 2)" = "live" ]                      # no path-hash
  [ "$(_tc_reclaim_decide Coding cc1-a1b2c3d4:9f8e 99 99 2)" = "live" ]                 # hash too short
  [ "$(_tc_reclaim_decide Coding cc1-A1B2C3D4:9f8e7d6c5b4a3210 99 99 2)" = "live" ]     # uppercase, not our emitter
  [ "$(_tc_reclaim_decide Coding cc2-a1b2c3d4:9f8e7d6c5b4a3210 99 99 2)" = "live" ]     # unknown version
}

# --- T20260724-312324: live-run/PID liveness pre-check ----------------------
# An optional 6th arg carries the caller-gathered liveness signal (in-progress
# GH Actions run, or a live local PID for a same-host claim) — "1" means live,
# anything else (including omitted, for back-compat with every test above)
# means "no live signal observed".

@test "_tc_reclaim_decide: live_signal=1 -> live even with fully stale git/PR activity" {
  [ "$(_tc_reclaim_decide Coding h:/p 99999 99999 2 1)" = "live" ]
}

@test "_tc_reclaim_decide: live_signal omitted (back-compat) -> unchanged staleness-window behavior" {
  [ "$(_tc_reclaim_decide Coding h:/p 99999 99999 2)" = "reclaimable" ]
}

@test "_tc_reclaim_decide: live_signal explicitly empty/0 -> unchanged staleness-window behavior" {
  [ "$(_tc_reclaim_decide Coding h:/p 99999 99999 2 '')" = "reclaimable" ]
  [ "$(_tc_reclaim_decide Coding h:/p 99999 99999 2 0)" = "reclaimable" ]
}

# --- claimant-id format (working-dir identity; T20260615-169917) ------------

@test "_tc_claimant_id is <machine>:<working-dir> (no per-invocation session id)" {
  session_machine() { printf 'boxname'; }
  session_clone_path() { printf '/home/u/clone'; }
  [ "$(_tc_claimant_id)" = "boxname:/home/u/clone" ]
}

@test "same clone + churning session-id resolves to the same claimant (no double-claim)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-demo.md"
  # real _tc_claimant_id; mock the underlying helpers. session_cc_session_id is
  # mocked to a CHANGING value to simulate the per-invocation churn that defeated
  # the old <sid>@<host> identity — this is a true regression guard: under the
  # old code _tc_claimant_id read session_cc_session_id and the 2nd acquire would
  # be 'claimed:' (exit 3); the new id must ignore it and resolve to 'mine'.
  session_machine() { printf 'box'; }
  session_clone_path() { printf '/clone/x'; }
  session_cc_session_id() { printf 'sess-one'; }
  run _tc_acquire T1; [ "$status" -eq 0 ]; [ "$output" = "acquired" ]
  session_cc_session_id() { printf 'sess-two'; }   # fresh CC invocation, same clone
  run _tc_acquire T1; [ "$status" -eq 0 ]; [ "$output" = "mine" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-demo.md" claimed_by)" = "box:/clone/x" ]
}

# --- release-on-pickup (the accumulation fix) -------------------------------

@test "release-others frees every task held by self, leaving other sessions' claims" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-a.md"
  _mk_task_file "$TASK_CLAIM_DIR/T2-b.md"
  _mk_task_file "$TASK_CLAIM_DIR/T3-c.md"

  # self accumulates two claims (acquire does NOT auto-release — that's the bug
  # release-others cleans up at the pick step).
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_acquire T1 >/dev/null
  _tc_acquire T2 >/dev/null
  # a different session holds T3.
  _tc_claimant_id() { printf 'other:/elsewhere'; }
  _tc_acquire T3 >/dev/null

  _tc_claimant_id() { printf 'box:/clone'; }
  run _tc_release_others
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T1-a$'
  echo "$output" | grep -q '^released:T2-b$'
  ! echo "$output" | grep -q 'T3'
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-b.md" claimed_by)" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T3-c.md" claimed_by)" = "other:/elsewhere" ]
  # freed tasks return to the pickable pool
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" status)" = "Open" ]
}

@test "release-others [except-id] keeps the about-to-be-acquired task" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-a.md"
  _mk_task_file "$TASK_CLAIM_DIR/T2-b.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_acquire T1 >/dev/null
  _tc_acquire T2 >/dev/null
  run _tc_release_others T2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T1-a$'
  ! echo "$output" | grep -q 'T2'
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]            # T1 freed
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-b.md" claimed_by)" = "box:/clone" ]  # T2 kept
}

@test "release-others + acquire enforces <=1 active claim (N -> N+1 pickup)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-a.md"
  _mk_task_file "$TASK_CLAIM_DIR/T2-b.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_release_others T1 >/dev/null      # nothing held yet → no-op
  run _tc_acquire T1; [ "$output" = "acquired" ]
  # the pick-step sequence for moving to T2: release-others (except T2) then acquire
  _tc_release_others T2 >/dev/null      # frees the prior claim T1
  run _tc_acquire T2; [ "$output" = "acquired" ]
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]   # prior claim released
  [ -n "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-b.md" claimed_by)" ]   # only T2 held now
}

@test "legacy <sid>@<machine> claim still parses, defers, and clears (age-out)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-demo.md"
  # a claim written by pre-upgrade code
  _tc_fm_set "$TASK_CLAIM_DIR/T1-demo.md" claimed_by "abc12345@oldbox"
  _tc_fm_set "$TASK_CLAIM_DIR/T1-demo.md" status Coding
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-demo.md" claimed_by)" = "abc12345@oldbox" ]   # parses
  # a new-format session sees it as someone else's → defers, never steals
  _tc_claimant_id() { printf 'box:/clone'; }
  run _tc_acquire T1
  [ "$status" -eq 3 ]; [ "$output" = "claimed:abc12345@oldbox" ]
  # release-others ignores it (not mine) — it ages out via the reclaim sweep / release
  run _tc_release_others
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-demo.md" claimed_by)" = "abc12345@oldbox" ]
  run _tc_release T1
  [ "$status" -eq 0 ]
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-demo.md" claimed_by)" ]
}

@test "release-others preserves Blocked/Review/terminal status, frees only Coding/Design" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-coding.md"
  _mk_task_file "$TASK_CLAIM_DIR/T2-blocked.md"
  _mk_task_file "$TASK_CLAIM_DIR/T3-review.md"
  _mk_task_file "$TASK_CLAIM_DIR/T4-done.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  for t in T1 T2 T3 T4; do _tc_acquire "$t" >/dev/null; done
  # the compound blocked status is what production writes — must NOT become Open
  _tc_fm_set "$TASK_CLAIM_DIR/T2-blocked.md" status "Blocked by T20251111-999999"
  _tc_fm_set "$TASK_CLAIM_DIR/T3-review.md"  status "Review"
  _tc_fm_set "$TASK_CLAIM_DIR/T4-done.md"    status "Done"
  run _tc_release_others
  [ "$status" -eq 0 ]
  # every task loses the claim ...
  for f in T1-coding T2-blocked T3-review T4-done; do
    [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/$f.md" claimed_by)" ]
  done
  # ... but only Coding/Design return to the pool; the rest keep their status
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-coding.md" status)"  = "Open" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-blocked.md" status)" = "Blocked by T20251111-999999" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T3-review.md" status)"  = "Review" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T4-done.md" status)"    = "Done" ]
}

@test "release-others scans PARKING: frees a self-held parked task (status preserved)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  PARKING="$BATS_TEST_TMPDIR/dev/PARKING"; mkdir -p "$PARKING"   # sibling of TODO
  _mk_task_file "$PARKING/T9-parked.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_fm_set "$PARKING/T9-parked.md" claimed_by "box:/clone"
  _tc_fm_set "$PARKING/T9-parked.md" status "Parked"
  run _tc_release_others
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T9-parked$'
  [ -z "$(_tc_fm_get "$PARKING/T9-parked.md" claimed_by)" ]
  [ "$(_tc_fm_get "$PARKING/T9-parked.md" status)" = "Parked" ]   # terminal — preserved
}

@test "release-others [except-id] protects a PARKED task being resumed (TODO-only finder would clobber it)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  PARKING="$BATS_TEST_TMPDIR/dev/PARKING"; mkdir -p "$PARKING"
  _mk_task_file "$TASK_CLAIM_DIR/T1-a.md"
  _mk_task_file "$PARKING/T2-parked.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_acquire T1 >/dev/null
  _tc_fm_set "$PARKING/T2-parked.md" claimed_by "box:/clone"
  _tc_fm_set "$PARKING/T2-parked.md" status "Parked"
  # resuming the parked T2: release all mine EXCEPT T2 (which lives in PARKING)
  run _tc_release_others T2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T1-a$'
  ! echo "$output" | grep -q 'T2'
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]              # T1 freed
  [ "$(_tc_fm_get "$PARKING/T2-parked.md" claimed_by)" = "box:/clone" ]   # parked except KEPT
}

@test "release-mine dispatcher verb is still accepted as a backward-compatible alias for release-others" {
  # T20260720-113930: release-mine was renamed to release-others (the argument
  # is an except-id, not the task to release — the old name read as a sibling
  # of `release <id>`, which caused a real mix-up). The old verb string must
  # keep working for any caller/doc that hasn't migrated yet — routes through
  # _tc_main, not the renamed function directly, so this actually exercises the
  # dispatcher's case statement rather than just the implementation.
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-a.md"
  _mk_task_file "$TASK_CLAIM_DIR/T2-b.md"
  _tc_claimant_id() { printf 'box:/clone'; }
  _tc_acquire T1 >/dev/null
  _tc_acquire T2 >/dev/null
  run _tc_main release-mine T2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T1-a$'
  ! echo "$output" | grep -q 'T2'
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]            # T1 freed
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-b.md" claimed_by)" = "box:/clone" ]  # T2 kept

  # and the new name, through the same dispatcher, behaves identically
  _tc_acquire T1 >/dev/null
  run _tc_main release-others T2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^released:T1-a$'
  [ -z "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-a.md" claimed_by)" ]
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T2-b.md" claimed_by)" = "box:/clone" ]
}

# --- verb round-trip --------------------------------------------------------

@test "acquire -> read -> (idempotent) -> defer-other -> release round-trip" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"
  mkdir -p "$TASK_CLAIM_DIR"
  _mk_task_file "$TASK_CLAIM_DIR/T1-demo.md"

  _tc_claimant_id() { printf 'sidA@h'; }
  run _tc_acquire T1
  [ "$status" -eq 0 ]; [ "$output" = "acquired" ]
  run _tc_read T1
  [ "$output" = "$(printf 'Coding\tsidA@h')" ]
  # human owner: is preserved across acquire
  [ "$(_tc_fm_get "$TASK_CLAIM_DIR/T1-demo.md" owner)" = "Alex" ]

  # idempotent re-acquire by the same claimant
  run _tc_acquire T1
  [ "$status" -eq 0 ]; [ "$output" = "mine" ]

  # a different session must be refused (exit 3, reports the holder)
  _tc_claimant_id() { printf 'sidB@h'; }
  run _tc_acquire T1
  [ "$status" -eq 3 ]; [ "$output" = "claimed:sidA@h" ]

  # release by the claimant clears claimed_by
  _tc_claimant_id() { printf 'sidA@h'; }
  run _tc_release T1
  [ "$status" -eq 0 ]; [ "$output" = "released" ]
  run _tc_read T1
  [ "$output" = "$(printf 'Open\t')" ]
}

@test "acquire on an unknown task id fails cleanly (exit 2)" {
  TASK_CLAIM_DIR="$BATS_TEST_TMPDIR/dev/TODO"; mkdir -p "$TASK_CLAIM_DIR"
  run _tc_acquire T-nope
  [ "$status" -eq 2 ]
}

# --- KEYSTONE: the conflict-guarantee (the lock itself) ---------------------

@test "two concurrent claims of the same task COLLIDE at git merge (the lock)" {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/dev/TODO"
  cd "$repo"
  git init -q
  git config user.email t@t; git config user.name t
  git config commit.gpgsign false
  _mk_task_file "$repo/dev/TODO/T1-demo.md"
  git add -A && git commit -qm base   # T0: claimed_by empty on main
  base="$(git rev-parse HEAD)"

  TASK_CLAIM_DIR="$repo/dev/TODO"

  # Session A branches off T0 and claims.
  git checkout -q -b sessA "$base"
  _tc_claimant_id() { printf 'sidA@host'; }
  run _tc_acquire T1; [ "$status" -eq 0 ]; [ "$output" = "acquired" ]
  git commit -qam "claim by A"

  # Session B branches off the SAME T0 and claims (it never saw A's claim).
  git checkout -q -b sessB "$base"
  _tc_claimant_id() { printf 'sidB@host'; }
  run _tc_acquire T1; [ "$status" -eq 0 ]; [ "$output" = "acquired" ]
  git commit -qam "claim by B"

  # A merges to main first — wins the lock.
  git checkout -q -b mainline "$base"
  run git merge --no-edit sessA
  [ "$status" -eq 0 ]

  # B now tries to land on top of A. The claimed_by line diverges from the
  # common base, so the merge MUST conflict — B cannot silently double-claim.
  run git merge --no-edit sessB
  [ "$status" -ne 0 ]
  grep -q '^<<<<<<<' "$repo/dev/TODO/T1-demo.md"
  grep -q 'sidA@host' "$repo/dev/TODO/T1-demo.md"
}

@test "rebasing the loser onto the winner also conflicts (merge-queue path)" {
  repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo/dev/TODO"
  cd "$repo"
  git init -q
  git config user.email t@t; git config user.name t
  git config commit.gpgsign false
  _mk_task_file "$repo/dev/TODO/T1-demo.md"
  git add -A && git commit -qm base
  base="$(git rev-parse HEAD)"
  TASK_CLAIM_DIR="$repo/dev/TODO"

  git checkout -q -b winner "$base"
  _tc_claimant_id() { printf 'sidA@host'; }
  _tc_acquire T1 >/dev/null; git commit -qam "A"

  git checkout -q -b loser "$base"
  _tc_claimant_id() { printf 'sidB@host'; }
  _tc_acquire T1 >/dev/null; git commit -qam "B"

  # Simulate a merge queue rebasing the loser's claim onto the winner's main.
  run git rebase winner
  [ "$status" -ne 0 ]   # rebase stops on conflict — loser is ejected, re-picks
  git rebase --abort 2>/dev/null || true
}

# --- iso/epoch (pure) -------------------------------------------------------

@test "_tc_iso_to_epoch round-trips a known timestamp; empty on garbage" {
  [ "$(_tc_iso_to_epoch 2021-01-01T00:00:00Z)" = "1609459200" ]
  [ -z "$(_tc_iso_to_epoch garbage)" ]
}

# --- PR ownership derived from the task claim (T20260622-404636) ------------
# _tc_pr_owner's DECISION is pure once the three I/O seams are stubbed:
#   session_pr_task_id (PR->task id), _tc_resolve_task_location (task id->repo/path),
#   _tc_fetch_fm_field (repo/path->claimed_by on main). We pin _tc_claimant_id too.

@test "pr-owner: PR maps to no task -> untracked" {
  session_pr_task_id() { printf ''; }
  [ "$(_tc_pr_owner 123)" = "untracked" ]
}

@test "pr-owner: task is unclaimed -> free" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { printf 'O/R\tdev/TODO/T20260622-404636-x.md'; }
  _tc_fetch_fm_field()        { printf ''; }            # claimed_by empty
  _tc_claimant_id()           { printf 'cdw:/home/ci/clone'; }
  [ "$(_tc_pr_owner 123)" = "free" ]
}

@test "pr-owner: task claimed by ME -> mine" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { printf 'O/R\tdev/TODO/T20260622-404636-x.md'; }
  _tc_claimant_id()           { printf 'cdw:/home/ci/clone'; }
  _tc_fetch_fm_field()        { printf 'cdw:/home/ci/clone'; }
  [ "$(_tc_pr_owner 123)" = "mine" ]
}

@test "pr-owner: task claimed by ANOTHER agent -> owned:<by> (defer)" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { printf 'O/R\tdev/TODO/T20260622-404636-x.md'; }
  _tc_claimant_id()           { printf 'cdw:/home/ci/clone'; }
  _tc_fetch_fm_field()        { printf 'otherbox:/home/other/clone'; }
  [ "$(_tc_pr_owner 123)" = "owned:otherbox:/home/other/clone" ]
}

@test "pr-owner: task location unresolvable -> unknown (fail-safe: caller defers)" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { return 1; }             # could not resolve repo/path
  [ "$(_tc_pr_owner 123)" = "unknown" ]
}

@test "pr-owner: task file fetch fails -> unknown (never a silent 'free')" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { printf 'O/R\tdev/TODO/T20260622-404636-x.md'; }
  _tc_fetch_fm_field()        { return 1; }              # API/decode failure
  [ "$(_tc_pr_owner 123)" = "unknown" ]
}

# --- pr-owner cross-repo blind spot (T20260626-195977) ----------------------
# A cross-repo task's claim is written from the HUB clone but /address-pr runs
# from the ephemeral TARGET clone (Phase 1.5 naming: <task-id>-<slug>-target).
# _tc_is_own_cross_repo_clone recognizes exactly that case; everything else
# must still fall through to _tc_decide's exact-match "owned:"/"mine".

@test "is_own_cross_repo_clone: same host, ephemeral target clone for THIS task -> yes" {
  run _tc_is_own_cross_repo_clone T20260626-195977 \
    'cdw:/home/ci/hub-repo' \
    'cdw:/tmp/T20260626-195977-pr-owner-target'
  [ "$status" -eq 0 ]
}

@test "is_own_cross_repo_clone: different host -> no (never weakens anti-steal)" {
  run _tc_is_own_cross_repo_clone T20260626-195977 \
    'otherbox:/home/other/hub-repo' \
    'cdw:/tmp/T20260626-195977-pr-owner-target'
  [ "$status" -eq 1 ]
}

@test "is_own_cross_repo_clone: same host, ephemeral clone for a DIFFERENT task -> no" {
  run _tc_is_own_cross_repo_clone T20260626-195977 \
    'cdw:/home/ci/hub-repo' \
    'cdw:/tmp/T20260101-111111-other-task-target'
  [ "$status" -eq 1 ]
}

@test "is_own_cross_repo_clone: same host, non-ephemeral clone path -> no" {
  run _tc_is_own_cross_repo_clone T20260626-195977 \
    'cdw:/home/ci/hub-repo' \
    'cdw:/home/ci/some-other-clone'
  [ "$status" -eq 1 ]
}

@test "is_own_cross_repo_clone: exact path match -> no (that's _tc_decide's 'mine', not this)" {
  run _tc_is_own_cross_repo_clone T20260626-195977 \
    'cdw:/home/ci/hub-repo' \
    'cdw:/home/ci/hub-repo'
  [ "$status" -eq 1 ]
}

@test "pr-owner: cross-repo PR, claim held by this host's hub clone -> mine" {
  session_pr_task_id()        { printf 'T20260626-195977'; }
  _tc_resolve_task_location() { printf 'your-org/hub-repo\tdev/TODO/T20260626-195977-x.md'; }
  _tc_claimant_id()            { printf 'cdw:/tmp/T20260626-195977-pr-owner-target'; }
  _tc_fetch_fm_field()        { printf 'cdw:/home/ci/hub-repo'; }
  [ "$(_tc_pr_owner 123)" = "mine" ]
}

@test "pr-owner: cross-repo PR, claim held by a DIFFERENT host -> still owned: (anti-steal preserved)" {
  session_pr_task_id()        { printf 'T20260626-195977'; }
  _tc_resolve_task_location() { printf 'your-org/hub-repo\tdev/TODO/T20260626-195977-x.md'; }
  _tc_claimant_id()            { printf 'cdw:/tmp/T20260626-195977-pr-owner-target'; }
  _tc_fetch_fm_field()        { printf 'otherbox:/home/other/hub-repo'; }
  [ "$(_tc_pr_owner 123)" = "owned:otherbox:/home/other/hub-repo" ]
}

@test "pr-owner: cross-repo PR, claim held by a different clone on the SAME host that is NOT the hub -> still owned: (no false-mine)" {
  session_pr_task_id()        { printf 'T20260626-195977'; }
  _tc_resolve_task_location() { printf 'your-org/hub-repo\tdev/TODO/T20260626-195977-x.md'; }
  _tc_claimant_id()            { printf 'cdw:/tmp/T20260101-111111-unrelated-target'; }
  _tc_fetch_fm_field()        { printf 'cdw:/home/ci/hub-repo'; }
  [ "$(_tc_pr_owner 123)" = "owned:cdw:/home/ci/hub-repo" ]
}

@test "pr-owner: same-repo PR behavior unchanged (regression)" {
  session_pr_task_id()        { printf 'T20260622-404636'; }
  _tc_resolve_task_location() { printf 'O/R\tdev/TODO/T20260622-404636-x.md'; }
  _tc_claimant_id()            { printf 'cdw:/home/ci/clone'; }
  _tc_fetch_fm_field()        { printf 'cdw:/home/ci/clone'; }
  [ "$(_tc_pr_owner 123)" = "mine" ]
}

# --- cross-repo task-location resolution (REAL function; gh stubbed) --------
# Guards the T20260622-404636 verification's CRITICAL finding: a decoy blob link
# preceding the Task: line must NOT redirect us to the wrong file, and a Task:
# link to a different task must not resolve.

@test "resolve_task_location: parses the Task: LINE link, NOT a decoy blob link before it" {
  BODY=$'Builds on https://github.com/your-org/ccxp-skills/blob/main/dev/TODO/T99999999-000001-decoy.md\nTask: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T20260622-404636-real.md\n'
  _session_gh() { case "$*" in *"pr view"*) printf '%s' "$BODY" ;; *) return 0 ;; esac; }
  loc="$(_tc_resolve_task_location 123 T20260622-404636)"
  [ "${loc%%$'\t'*}" = "your-org/hub-repo" ]                 # NOT ccxp-skills (the decoy)
  [ "${loc#*$'\t'}" = "dev/TODO/T20260622-404636-real.md" ]
}

@test "resolve_task_location: a Task: link to a DIFFERENT task id -> fail (caller defers)" {
  BODY=$'Task: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T11111111-000002-other.md\n'
  _session_gh() { case "$*" in *"pr view"*) printf '%s' "$BODY" ;; *) return 0 ;; esac; }
  run _tc_resolve_task_location 123 T20260622-404636
  [ "$status" -ne 0 ]
}

@test "resolve_task_location: body-fetch FAILURE fails closed (no same-repo fall-through)" {
  # A transient pr-view failure must NOT degrade to reading the wrong (target) repo.
  _session_gh() { case "$*" in *"pr view"*) return 1 ;; *) printf 'UNREACHED' ;; esac; }
  run _tc_resolve_task_location 123 T20260622-404636
  [ "$status" -ne 0 ]
  [[ "$output" != *UNREACHED* ]]
}

@test "resolve_task_location: a PREFIX-colliding longer id link is rejected (token boundary)" {
  # T20260622-404636 must NOT match T20260622-4046369-other.md (a distinct task).
  BODY=$'Task: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T20260622-4046369-other.md\n'
  _session_gh() { case "$*" in *"pr view"*) printf '%s' "$BODY" ;; *) return 0 ;; esac; }
  run _tc_resolve_task_location 123 T20260622-404636
  [ "$status" -ne 0 ]
}

@test "resolve_task_location: multiple distinct same-id Task: links -> fail closed (ambiguous)" {
  BODY=$'Task: https://github.com/attacker/evil/blob/main/dev/TODO/T20260622-404636-decoy.md\nTask: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T20260622-404636-real.md\n'
  _session_gh() { case "$*" in *"pr view"*) printf '%s' "$BODY" ;; *) return 0 ;; esac; }
  run _tc_resolve_task_location 123 T20260622-404636
  [ "$status" -ne 0 ]   # two distinct hub links for the id -> defer, never pick one
}

@test "resolve_task_location: duplicate identical Task: links collapse to one -> resolves" {
  BODY=$'Task: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T20260622-404636-real.md\nTask: https://github.com/your-org/hub-repo/blob/main/dev/TODO/T20260622-404636-real.md\n'
  _session_gh() { case "$*" in *"pr view"*) printf '%s' "$BODY" ;; *) return 0 ;; esac; }
  loc="$(_tc_resolve_task_location 123 T20260622-404636)"
  [ "${loc%%$'\t'*}" = "your-org/hub-repo" ]
  [ "${loc#*$'\t'}" = "dev/TODO/T20260622-404636-real.md" ]
}

# --- PR-activity picker (pure; the false-reclaim fix) -----------------------
# Guards the T20260622-404636 verification's HIGH finding: a task-tracked PR
# carrying its id ONLY in the branch name must still be found (else 99999 ->
# false reclaim of a live PR). This is also the load-bearing half of the
# T20260625-733429 agreement invariant: signal #1 (the `t<id>-…` branch that
# /focus + /gcpr always set, keyed by BOTH this picker and session_pr_task_id)
# matches every task-tracked PR even when its id is absent from body+title — so
# the pr-owner resolver and the reclaim picker agree on every PR a claim can have.
# If a refactor ever drops branch matching, this test fails and the gap re-opens.

@test "pick_pr_updated_at: matches a BRANCH-named PR (id only in headRefName)" {
  json='[{"updatedAt":"2026-06-20T00:00:00Z","headRefName":"t20260622-404636-foo","body":"no id","title":"no id"}]'
  [ "$(_tc_pick_pr_updated_at T20260622-404636 "$json")" = "2026-06-20T00:00:00Z" ]
}

# T20260625-733429 — the commit-only-id boundary is BY DESIGN, not a defect.
# session_pr_task_id (pr-owner) also scans commit messageHeadlines; this picker
# does not (it reads the `gh pr list` JSON, which carries no commits). A PR whose
# id lives ONLY in commit subjects — non-`t<id>-…` branch, id absent from body and
# title — is therefore unmatched here (-> empty). That can only describe a
# NON-task-tracked PR (focus/gcpr always set the `t<id>-…` branch matched above),
# so it is never a claimed task's live PR in the reclaim path. Pinning the boundary
# keeps it intentional: if a future change makes this case match, that is a
# behavior change to review, not a silent regression.
@test "pick_pr_updated_at: commit-only-id PR is by-design unmatched (non-task-tracked)" {
  json='[{"updatedAt":"2026-06-25T00:00:00Z","headRefName":"reclaim-picker-fix","body":"reclaim picker commit-headline signal","title":"fix: reclaim picker"}]'
  [ -z "$(_tc_pick_pr_updated_at T20260625-733429 "$json")" ]
}

@test "pick_pr_updated_at: matches by body/title; latest updatedAt wins; no match -> empty" {
  json='[{"updatedAt":"2026-06-19T00:00:00Z","headRefName":"x","body":"see T20260622-404636","title":"x"},{"updatedAt":"2026-06-21T00:00:00Z","headRefName":"y","body":"b","title":"T20260622-404636 fix"}]'
  [ "$(_tc_pick_pr_updated_at T20260622-404636 "$json")" = "2026-06-21T00:00:00Z" ]
  nomatch='[{"updatedAt":"2026-06-21T00:00:00Z","headRefName":"z","body":"b","title":"t"}]'
  [ -z "$(_tc_pick_pr_updated_at T20260622-404636 "$nomatch")" ]
}

# --- T20260724-312324: live-run liveness signal -----------------------------
# _tc_pick_pr_head_ref shares _tc_pick_pr_updated_at's exact match set (same
# branch/body/title matcher, T20260625-733429's invariant) but returns the
# matched PR's headRefName instead of updatedAt — the branch _tc_has_live_run
# checks GH Actions run status against.

@test "pick_pr_head_ref: matches a BRANCH-named PR (id only in headRefName)" {
  json='[{"updatedAt":"2026-06-20T00:00:00Z","headRefName":"t20260622-404636-foo","body":"no id","title":"no id"}]'
  [ "$(_tc_pick_pr_head_ref T20260622-404636 "$json")" = "t20260622-404636-foo" ]
}

@test "pick_pr_head_ref: no match -> empty" {
  json='[{"updatedAt":"2026-06-21T00:00:00Z","headRefName":"z","body":"b","title":"t"}]'
  [ -z "$(_tc_pick_pr_head_ref T20260622-404636 "$json")" ]
}

@test "_tc_has_live_run: in-progress run on the matched PR's branch -> 1" {
  _session_gh() {
    case "$*" in
      *"pr list"*) printf '[{"updatedAt":"2026-08-10T00:00:00Z","headRefName":"t20260724-312324-fix","body":"","title":""}]' ;;
      *"run list"*) printf 'in_progress' ;;
      *) return 1 ;;
    esac
  }
  [ "$(_tc_has_live_run T20260724-312324)" = "1" ]
}

@test "_tc_has_live_run: no in-progress run on the matched PR's branch -> empty" {
  _session_gh() {
    case "$*" in
      *"pr list"*) printf '[{"updatedAt":"2026-08-10T00:00:00Z","headRefName":"t20260724-312324-fix","body":"","title":""}]' ;;
      *"run list"*) printf 'completed' ;;
      *) return 1 ;;
    esac
  }
  [ -z "$(_tc_has_live_run T20260724-312324)" ]
}

@test "_tc_has_live_run: run awaiting environment approval (requested) -> 1" {
  # Code review, T20260724-312324: in_progress/queued/waiting alone missed a
  # run held on environment approval — still live, must not be reclaimable.
  _session_gh() {
    case "$*" in
      *"pr list"*) printf '[{"updatedAt":"2026-08-10T00:00:00Z","headRefName":"t20260724-312324-fix","body":"","title":""}]' ;;
      *"run list"*) printf 'requested' ;;
      *) return 1 ;;
    esac
  }
  [ "$(_tc_has_live_run T20260724-312324)" = "1" ]
}

@test "_tc_has_live_run: run awaiting environment approval (pending) -> 1" {
  _session_gh() {
    case "$*" in
      *"pr list"*) printf '[{"updatedAt":"2026-08-10T00:00:00Z","headRefName":"t20260724-312324-fix","body":"","title":""}]' ;;
      *"run list"*) printf 'pending' ;;
      *) return 1 ;;
    esac
  }
  [ "$(_tc_has_live_run T20260724-312324)" = "1" ]
}

@test "_tc_has_live_run: no open PR referencing the task -> empty (never blocks reclaim)" {
  _session_gh() {
    case "$*" in
      *"pr list"*) printf '[]' ;;
      *) return 1 ;;
    esac
  }
  [ -z "$(_tc_has_live_run T20260724-312324)" ]
}

@test "_tc_has_live_run: gh failure -> empty (fail toward the pre-existing staleness behavior)" {
  _session_gh() { return 1; }
  [ -z "$(_tc_has_live_run T20260724-312324)" ]
}
