#!/usr/bin/env bats
# Tests for _session/attribution.sh — per-location task-attribution aggregation.
#
# Pure logic (classify, frontmatter read) is tested by sourcing the script. The
# completed-task recovery is tested against a REAL git fixture (the close-time
# `claimed_by` wipe is the whole point — see attribution.sh header), as is the
# end-to-end table over a git-backed dev/ tree where the JOURNAL stub's live
# `claimed_by` is empty and must be recovered from history.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Sourcing is side-effect-free (CLI is under the direct-exec guard).
  source "$REPO_ROOT/_session/attribution.sh"
  # Deterministic classification default for the unit tests.
  export ATTRIBUTION_CCXP_PATHS="/home/ci/focus/some-repo"
}

# Write a task file with the given frontmatter status + claimed_by, plus decoy
# body lines that must never be read as frontmatter.
_mk_task() {
  # $1 path  $2 status  $3 claimed_by
  cat > "$1" <<EOF
---
estimation: 1h
status: $2
claimed_by: $3
priority: Low
---

# T-demo

## Notes
claimed_by: this BODY line must never be read
status: nor this BODY line
EOF
}

# A git-backed dev/ tree under $BATS_TEST_TMPDIR/repo with a JOURNAL task whose
# claimed_by was set then CLEARED (the realistic close flow). Echoes the repo dir.
_mk_git_dev() {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/dev/TODO" "$repo/dev/JOURNAL"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  # A shipped JOURNAL task: claimed by the cron clone, then cleared at close.
  local j="$repo/dev/JOURNAL/2026-06-28-T20260601-111111-shipped.md"
  _mk_task "$j" Done "cdw:/home/ci/focus/some-repo"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "work T111111"
  # Release clears claimed_by (task_claim.sh:345 behaviour).
  _mk_task "$j" Done ""
  git -C "$repo" add -A && git -C "$repo" commit -q -m "close T111111 (claimed_by cleared)"
  printf '%s' "$repo"
}

# --- classify (pure, no I/O) ------------------------------------------------

@test "classify: a path in ATTRIBUTION_CCXP_PATHS is ccxp" {
  [ "$(attribution_classify 'cdw:/home/ci/focus/some-repo')" = "ccxp" ]
}

@test "classify: a non-empty path NOT in the list is interactive" {
  [ "$(attribution_classify 'cdw:/home/ci/some-repo')" = "interactive" ]
}

@test "classify: an explicit claimed_role wins (the cc1- path, T20260911-698434)" {
  # A current claim's path half is a hash, so the role must come from the
  # task's own claimed_role field rather than being parsed back out.
  [ "$(attribution_classify 'cc1-a1b2c3d4:9f8e7d6c5b4a3210' ccxp)" = "ccxp" ]
  [ "$(attribution_classify 'cc1-a1b2c3d4:9f8e7d6c5b4a3210' interactive)" = "interactive" ]
}

@test "classify: a cc1- claim with NO role falls back to interactive, never a bogus path match" {
  [ "$(attribution_classify 'cc1-a1b2c3d4:9f8e7d6c5b4a3210')" = "interactive" ]
}

@test "classify: PRE-MIGRATION plaintext history still classifies by path" {
  # Completed-task attribution recovers claimed_by from git history, which
  # keeps the old <host>:<path> form forever. Every historical retro must keep
  # attributing correctly without a claimed_role field existing back then.
  ATTRIBUTION_CCXP_PATHS='/home/ci/focus/some-repo'
  [ "$(attribution_classify 'cdw:/home/ci/focus/some-repo')" = "ccxp" ]
  [ "$(attribution_classify 'cdw:/home/someone/interactive-clone')" = "interactive" ]
}

@test "classify: empty location is unattributed" {
  [ "$(attribution_classify '')" = "unattributed" ]
  [ "$(attribution_classify)" = "unattributed" ]
}

@test "classify: honours a multi-path colon list and matches the path after the first colon" {
  export ATTRIBUTION_CCXP_PATHS="/a/box:/home/ci/focus/some-repo:/c/box"
  [ "$(attribution_classify 'otherhost:/c/box')" = "ccxp" ]
  [ "$(attribution_classify 'otherhost:/not/listed')" = "interactive" ]
}

# --- location normalization (regression: live-data garbage rows) ------------

@test "norm_loc: strips matched surrounding quotes and treats quote-empty as empty" {
  [ -z "$(_attribution_norm_loc '""')" ]
  [ -z "$(_attribution_norm_loc "''")" ]
  [ -z "$(_attribution_norm_loc '   ')" ]
  [ "$(_attribution_norm_loc '  "cdw:/x"  ')" = "cdw:/x" ]
  [ "$(_attribution_norm_loc 'cdw:/x')" = "cdw:/x" ]
}

# --- frontmatter read -------------------------------------------------------

@test "fm_get reads a frontmatter field and ignores body lines" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task "$f" Coding "host:/p"
  [ "$(attribution_fm_get "$f" status)" = "Coding" ]
  [ "$(attribution_fm_get "$f" claimed_by)" = "host:/p" ]
}

@test "fm_get returns empty for a bare/empty field" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task "$f" Done ""
  [ -z "$(attribution_fm_get "$f" claimed_by)" ]
}

# --- last_claimed_by --------------------------------------------------------

@test "last_claimed_by: current frontmatter wins when non-empty" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task "$f" Coding "cdw:/live/claim"
  [ "$(attribution_last_claimed_by "$f")" = "cdw:/live/claim" ]
}

@test "last_claimed_by: recovers the pre-clear value from git history (close wipe)" {
  repo="$(_mk_git_dev)"
  j="$repo/dev/JOURNAL/2026-06-28-T20260601-111111-shipped.md"
  # current frontmatter claimed_by is empty (cleared at close) ...
  [ -z "$(attribution_fm_get "$j" claimed_by)" ]
  # ... but the recovery walks history and returns the pre-clear value.
  [ "$(attribution_last_claimed_by "$j")" = "cdw:/home/ci/focus/some-repo" ]
}

@test "last_claimed_by: empty outside a git repo when frontmatter is empty" {
  f="$BATS_TEST_TMPDIR/loose.md"; _mk_task "$f" Done ""
  [ -z "$(attribution_last_claimed_by "$f")" ]
}

@test "last_claimed_by: a DIFFERENT same-id/different-slug file does not cross-attribute (HIGH regression)" {
  # A task can split into design+impl docs: same T-id, different slug. The
  # recovery must key on the id+SLUG stem, not the bare id — else the newest
  # commit of file B leaks into file A's attribution.
  local repo="$BATS_TEST_TMPDIR/repo3"
  mkdir -p "$repo/dev/JOURNAL"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@e.com"; git -C "$repo" config user.name "T"
  local A="$repo/dev/JOURNAL/2026-06-20-T20260601-333333-design.md"
  _mk_task "$A" Done "cdw:/box-A"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "A claim"
  _mk_task "$A" Done ""                                  # A closed (cleared)
  git -C "$repo" add -A && git -C "$repo" commit -q -m "A close"
  local B="$repo/dev/JOURNAL/2026-06-21-T20260601-333333-impl.md"   # same id, other slug
  _mk_task "$B" Done "cdw:/box-B"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "B claim (more recent)"
  # recovering A must return A's own pre-clear claim, NOT B's newer claim.
  [ "$(attribution_last_claimed_by "$A")" = "cdw:/box-A" ]
}

# --- collect ----------------------------------------------------------------

@test "collect: TODO claimed + Coding/Review count as in-flight; unclaimed Open is skipped" {
  d="$BATS_TEST_TMPDIR/dev"; mkdir -p "$d/TODO"
  _mk_task "$d/TODO/T1.md" Coding ""                 # in-flight by status (loc empty)
  _mk_task "$d/TODO/T2.md" Design "cdw:/peer"        # in-flight by claim
  _mk_task "$d/TODO/T3.md" Open ""                   # skipped (Open + unclaimed)
  run attribution_collect "$d" "2026-01-01" "2026-12-31"
  [ "$status" -eq 0 ]
  # two in-flight rows, none shipped
  [ "$(printf '%s\n' "$output" | grep -c 'in-flight')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c 'shipped')" -eq 0 ]
}

@test "collect: shipped JOURNAL only when the filename date is in [since,until); non-task docs skipped" {
  d="$BATS_TEST_TMPDIR/dev"; mkdir -p "$d/JOURNAL"
  _mk_task "$d/JOURNAL/2026-06-28-T20260601-111111-in.md"  Done "cdw:/x"
  _mk_task "$d/JOURNAL/2026-06-20-T20260601-222222-out.md" Done "cdw:/x"
  # non-task journal docs must be ignored
  : > "$d/JOURNAL/2026-06-28-daily-summary.md"
  : > "$d/JOURNAL/2026-06-28-ipm-weekly.md"
  run attribution_collect "$d" "2026-06-28" "2026-06-29"   # window = the 28th only
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'shipped')" -eq 1 ]
}

# --- table ------------------------------------------------------------------

@test "table: empty dev tree prints nothing" {
  d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d/TODO" "$d/JOURNAL"
  run attribution_table "$d" "2026-06-28" "2026-06-29"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "table: aggregates per location with ccxp/interactive classes and a Total" {
  d="$BATS_TEST_TMPDIR/dev"; mkdir -p "$d/TODO"
  _mk_task "$d/TODO/T1.md" Coding "cdw:/home/ci/focus/some-repo"   # ccxp in-flight
  _mk_task "$d/TODO/T2.md" Coding "cdw:/home/ci/some-repo"         # interactive in-flight
  run attribution_table "$d" "2026-06-28" "2026-06-29"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^\| Location \| Class \| Shipped \| In-flight \| Total \|'
  printf '%s\n' "$output" | grep -qE '/focus/some-repo \| ccxp \| 0 \| 1 \| 1 \|'
  printf '%s\n' "$output" | grep -qE 'ci/some-repo \| interactive \| 0 \| 1 \| 1 \|'
}

@test "table: end-to-end over a git-backed dev/ recovers a cleared JOURNAL claim into the ccxp row" {
  repo="$(_mk_git_dev)"
  run attribution_table "$repo/dev" "2026-06-28" "2026-06-29"
  [ "$status" -eq 0 ]
  # the shipped task's claimed_by was cleared at close but recovered from history,
  # so it lands in the ccxp row as 1 shipped.
  printf '%s\n' "$output" | grep -qE '/focus/some-repo \| ccxp \| 1 \| 0 \| 1 \|'
}

@test "table: an unrecoverable shipped task renders a correct (unattributed) row (leading-tab regression)" {
  # A JOURNAL task whose history never had a non-empty claimed_by → empty
  # location. The empty location must render as "(unattributed)" with the count
  # in the Shipped column (not shifted into the Location field — the IFS leading
  # -tab-strip bug the live run surfaced).
  local repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo/dev/JOURNAL"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@e.com"; git -C "$repo" config user.name "T"
  _mk_task "$repo/dev/JOURNAL/2026-06-28-T20260601-999999-orphan.md" Done ""
  git -C "$repo" add -A && git -C "$repo" commit -q -m "orphan, never claimed"
  run attribution_table "$repo/dev" "2026-06-28" "2026-06-29"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^\| \(unattributed\) \| unattributed \| 1 \| 0 \| 1 \|$'
}

# ============================================================================
# ATTRIBUTION_CCXP_PATHS — no baked-in default; ~/.claude/.env resolution
# (T20260827-280088: removed the hardcoded /home/ci/... default so the
# public ccxp-skills copy of this file ships with no path baked in)
# ============================================================================

@test "_attribution_load_env: no default — ATTRIBUTION_CCXP_PATHS is empty with nothing configured" {
  # setup() exports ATTRIBUTION_CCXP_PATHS for the other tests' determinism —
  # unset it for this subshell so we observe the script's own true default.
  result=$(env -u ATTRIBUTION_CCXP_PATHS bash -c "source '$REPO_ROOT/_session/attribution.sh'; echo \"[\$ATTRIBUTION_CCXP_PATHS]\"")
  [ "$result" = "[]" ]
}

@test "_attribution_load_env: ENV_FILE override wins when set" {
  envfile="$BATS_TEST_TMPDIR/custom.env"
  echo "ATTRIBUTION_CCXP_PATHS=/custom/cron/path" > "$envfile"
  result=$(env -u ATTRIBUTION_CCXP_PATHS ENV_FILE="$envfile" bash -c "source '$REPO_ROOT/_session/attribution.sh'; echo \"\$ATTRIBUTION_CCXP_PATHS\"")
  [ "$result" = "/custom/cron/path" ]
}

@test "_attribution_load_env: already-exported ATTRIBUTION_CCXP_PATHS is left alone (no file needed)" {
  result=$(ATTRIBUTION_CCXP_PATHS=/preset/path bash -c "source '$REPO_ROOT/_session/attribution.sh'; echo \"\$ATTRIBUTION_CCXP_PATHS\"")
  [ "$result" = "/preset/path" ]
}

@test "attribution_classify: empty ATTRIBUTION_CCXP_PATHS classifies every location as interactive" {
  ATTRIBUTION_CCXP_PATHS=""
  [ "$(attribution_classify 'someone:/some/path')" = "interactive" ]
}
