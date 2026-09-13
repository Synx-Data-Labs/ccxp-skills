#!/usr/bin/env bats
# Tests for _ipm/stamp-scheduled.sh — stamps a task file's `scheduled:` frontmatter
# from the current iteration's Monday, resolved by a 3-tier hybrid:
#   1. IPM file (token-free, via _ipm/current.sh)
#   2. Project-API fallback (via $STAMP_ITER_HELPER, normally _session/iteration.sh)
#   3. next-week-Monday fallback (computed from today)
# update-forward-only; best-effort (never hard-fails a caller on a soft error).
#
# "today" is injected via IPM_TODAY; the API tier is injected via STAMP_ITER_HELPER
# so tests are deterministic without a token or network.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STAMP="$REPO_ROOT/_ipm/stamp-scheduled.sh"
  JDIR="$BATS_TEST_TMPDIR/journal"
  mkdir -p "$JDIR"
  TASK="$BATS_TEST_TMPDIR/T20260626-190842-x.md"
}

# Write a committed (or staging) IPM file. $1=date $2=staging(yes/no)
mk_ipm() {
  local d="$1" staging="$2" f="$JDIR/$1-ipm-weekly.md"
  if [ "$staging" = yes ]; then
    printf '# IPM Weekly — %s\n\n**Status**: Pre-IPM staging\n' "$d" > "$f"
  else
    printf '# Weekly Focus: %s\n\n**Budget**: 20h\n' "$d" > "$f"
  fi
}

# Write a YAML task file. $1=optional existing scheduled value
mk_task() {
  { echo '---'; echo 'status: Open'; echo 'estimation: 1h';
    [ -n "${1:-}" ] && echo "scheduled: $1";
    echo '---'; echo; echo '# Task body'; } > "$TASK"
}

# A STAMP_ITER_HELPER stub that prints $1 regardless of args (the API tier).
api_stub() {  # $1=date-to-emit (empty for "no iteration")
  local s="$BATS_TEST_TMPDIR/iter_stub.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "${1:-}" > "$s"
  chmod +x "$s"
  printf 'bash %s' "$s"
}

sched_line() { grep -E '^scheduled:' "$TASK" | head -1; }

# --- Tier 1: IPM file ---------------------------------------------------------

@test "tier1 current: stamps the committed IPM's Monday" {
  mk_ipm 2026-06-22 no
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
  [ "$(sched_line)" = "scheduled: 2026-06-22" ]
}

@test "tier1 next: stamps the IPM Monday + 7 days" {
  mk_ipm 2026-06-22 no
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" next "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-29" ]
  [ "$(sched_line)" = "scheduled: 2026-06-29" ]
}

@test "tier1 is staging-aware: the still-staged stub is skipped" {
  mk_ipm 2026-06-15 no
  mk_ipm 2026-06-22 yes
  mk_task
  run env IPM_TODAY=2026-06-22 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-15" ]
}

# --- Tier 2: Project-API fallback --------------------------------------------

@test "tier2: no IPM, API helper supplies the date" {
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER="$(api_stub 2026-07-13)" bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-07-13" ]
  [ "$(sched_line)" = "scheduled: 2026-07-13" ]
}

# --- Tier 3: next-week-Monday fallback ---------------------------------------

@test "tier3 current: no IPM, no API -> next week's Monday" {
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-29" ]
}

@test "tier3 next: no IPM, no API -> the Monday after next" {
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" next "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-07-06" ]
}

# --- update-forward-only ------------------------------------------------------

@test "forward-only: an earlier existing scheduled is overwritten" {
  mk_ipm 2026-06-22 no
  mk_task 2026-06-01
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
  [ "$(sched_line)" = "scheduled: 2026-06-22" ]
}

@test "forward-only: a later existing scheduled is kept (never moved backward)" {
  mk_ipm 2026-06-22 no
  mk_task 2026-12-01
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-12-01" ]
  [ "$(sched_line)" = "scheduled: 2026-12-01" ]
}

@test "forward-only: a quoted later existing scheduled is still honored (kept)" {
  mk_ipm 2026-06-22 no
  mk_task '"2026-12-01"'
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-12-01" ]
}

@test "best-effort: an unparseable existing scheduled is overwritten (can't honor forward-only)" {
  mk_ipm 2026-06-22 no
  mk_task 'someday'
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
  [ "$(sched_line)" = "scheduled: 2026-06-22" ]
}

@test "absent scheduled is inserted" {
  mk_ipm 2026-06-22 no
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  grep -qE '^scheduled: 2026-06-22$' "$TASK"
  # exactly one scheduled key
  [ "$(grep -cE '^scheduled:' "$TASK")" -eq 1 ]
}

# --- idempotence + best-effort -----------------------------------------------

@test "idempotent: a second run is a no-op (single scheduled key, same date)" {
  mk_ipm 2026-06-22 no
  mk_task
  env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
  [ "$(grep -cE '^scheduled:' "$TASK")" -eq 1 ]
}

@test "best-effort: a non-YAML (legacy) task file is left unmodified, exit 0" {
  printf '# Legacy task\n\n- **Status**: Open\n' > "$TASK"
  before="$(cat "$TASK")"
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" current "$JDIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$TASK")" = "$before" ]
}

@test "missing task-file argument is a usage error" {
  run bash "$STAMP"
  [ "$status" -ne 0 ]
}

@test "mode defaults to current when omitted" {
  mk_ipm 2026-06-22 no
  mk_task
  run env IPM_TODAY=2026-06-24 STAMP_ITER_HELPER=true bash "$STAMP" "$TASK" "" "$JDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-06-22" ]
}
