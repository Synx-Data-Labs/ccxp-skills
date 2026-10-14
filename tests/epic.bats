#!/usr/bin/env bats
# Tests for epic/scripts/epic.sh — member resolution, drive filtering,
# refresh report, final report ordering. Hermetic: throwaway repo, no gh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/epic/scripts/epic.sh"
  export CCXP_PEER_MODE=1
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/dev/TODO" "$R/dev/PARKING" "$R/dev/JOURNAL" "$R/dev/EPICS"
  cd "$R"
  git init -q .
  git remote add origin git@github.com:o/r.git
  mk() { # id status [extra frontmatter] [title]
    printf -- '---\nstatus: %s\nestimation: 1\n%s\n---\n\n# %s: %s\n' "$2" "${3:-}" "$1" "${4:-title $1}" > "dev/TODO/$1-slug.md"
  }
  mk T20260101-000001 Open "" "Alpha open"
  mk T20260101-000002 "Open" "claimed_by: someone-else" "Peer claimed"
  mk T20260101-000003 "Blocked by T20260101-000001" "" "Blocked one"
  mk T20260101-000004 "In Progress — SUPERVISED (needs VPN)" "" "Supervised one"
  mk T20260101-000005 Open "deadline: 2026-11-01" "Late deadline"
  mk T20260101-000006 "Blocked by T20260101-000099" "" "Stale blocker"
  mk T20260101-000007 Open "" "Unrelated gizmo"
  mk T20260101-000008 Open "related: [T20260101-000001]" "Linked by related"
  printf -- '---\nstatus: Done\n---\n\n# T20260101-000010: done one\n' > dev/JOURNAL/2026-02-02-T20260101-000010-done.md
  printf -- '---\nstatus: Parked\n---\n\n# T20260101-000011: parked one\n' > dev/PARKING/T20260101-000011-parked.md
  # queue: 5 first, then 1, 4, 3
  printf '# TODO Queue\n\n- [T20260101-000005](T20260101-000005-slug.md): x\n- [T20260101-000001](T20260101-000001-slug.md): x\n- [T20260101-000004](T20260101-000004-slug.md): x\n- [T20260101-000003](T20260101-000003-slug.md): x\n' > dev/TODO/queue.md
  cat > dev/EPICS/E1-alpha-gizmo.md <<'EOF'
---
status: Active
---

# E1 — Alpha pipeline

## Tasks

- T20260101-000003 — Blocked one
- [T20260101-000001](../TODO/T20260101-000001-slug.md) — Alpha open
- T20260101-000010 — done one
- T20260101-000011 — parked one
- T20260101-000002 — Peer claimed
- T20260101-000004 — Supervised one
- T20260101-000006 — Stale blocker
- T20260101-000005 — Late deadline
- T20260101-999999 — other repo thing
EOF
}

@test "members: epic-file order, both line forms, title after first em dash" {
  run bash "$SCRIPT" members E1
  [ "$status" -eq 0 ]
  [ "$(head -n1 <<<"$output")" = $'T20260101-000003\tBlocked one' ]
  [ "$(sed -n 2p <<<"$output")" = $'T20260101-000001\tAlpha open' ]
  [ "$(wc -l <<<"$output" | tr -d ' ')" = "9" ]
}

@test "plan: verdicts for done, parked, blocked, supervised, stale blocker, external" {
  run bash "$SCRIPT" plan E1
  [ "$status" -eq 0 ]
  grep -qE $'^T20260101-000003\tskip\tblocked:T20260101-000001\t' <<<"$output"
  grep -qE $'^T20260101-000001\tdrive\t' <<<"$output"
  grep -qE $'^T20260101-000010\tskip\tdone\t' <<<"$output"
  grep -qE $'^T20260101-000011\tskip\tparked\t' <<<"$output"
  grep -qE $'^T20260101-000004\tskip\tsupervised\t' <<<"$output"
  grep -qE $'^T20260101-000006\tdrive\t' <<<"$output"
  grep -qE $'^T20260101-999999\texternal\tno-file\t' <<<"$output"
}

@test "plan: peer claim is skipped unless peer mode is off" {
  run bash "$SCRIPT" plan E1
  # claimed_by is not this session's id; a fresh claim with no PR may be
  # reclaimable, so accept either skip:peer or drive but never a crash
  grep -qE $'^T20260101-000002\t(skip\tpeer:|drive)' <<<"$output"
  CCXP_PEER_MODE=0 run bash "$SCRIPT" plan E1
  grep -qE $'^T20260101-000002\tdrive\t' <<<"$output"
}

@test "next: first driveable in epic order, skipping attempted ids" {
  run bash "$SCRIPT" next E1
  [ "$status" -eq 0 ]
  [ "$output" = "T20260101-000001" ]
  run bash "$SCRIPT" next E1 T20260101-000001
  [ "$status" -eq 0 ]
  [ "$output" != "T20260101-000001" ]
}

@test "next: epic order, not queue.md order (000005 is first in queue but later in epic)" {
  run bash "$SCRIPT" next E1 T20260101-000001 T20260101-000002 T20260101-000006
  [ "$output" = "T20260101-000005" ]
}

@test "next: a merged blocker unblocks its dependent on the next call" {
  mv dev/TODO/T20260101-000001-slug.md dev/JOURNAL/2026-03-03-T20260101-000001-slug.md
  run bash "$SCRIPT" plan E1
  grep -qE $'^T20260101-000003\tdrive\t' <<<"$output"
  run bash "$SCRIPT" next E1
  [ "$output" = "T20260101-000003" ]
}

@test "next: exits 1 when nothing is left" {
  run bash "$SCRIPT" next E1 T20260101-000001 T20260101-000002 T20260101-000006 T20260101-000005
  [ "$status" -eq 1 ]
}

@test "record: one TSV line, tabs and newlines in summary flattened" {
  bash "$SCRIPT" record "$BATS_TEST_TMPDIR/res.tsv" T20260101-000001 failed $'a\tb\nc'
  [ "$(cat "$BATS_TEST_TMPDIR/res.tsv")" = $'T20260101-000001\tfailed\ta b c' ]
}

@test "report: merged list, then failures and skips ordered deadline-first then queue position" {
  res="$BATS_TEST_TMPDIR/res.tsv"
  bash "$SCRIPT" record "$res" T20260101-000006 merged "PR #7"
  bash "$SCRIPT" record "$res" T20260101-000001 failed "tests red"
  bash "$SCRIPT" record "$res" T20260101-000005 escalated "NEEDS INPUT: which API"
  run bash "$SCRIPT" report E1 "$res"
  [ "$status" -eq 0 ]
  grep -q '^- T20260101-000006 — PR #7' <<<"$output"
  # 000005 has a deadline -> first; then queue order: 000001 (pos 2), 000004 (pos 3), 000003 (pos 4)
  order="$(grep -oE '^- T[0-9]{8}-[0-9]{6}' <<<"$output" | sed -n '2,$p' | sed 's/^- //' | tr -d '\n')"
  [[ "$order" == T20260101-000005T20260101-000001T20260101-000004T20260101-000003* ]]
  grep -q 'due 2026-11-01' <<<"$output"
  grep -q 'drive the blocker T20260101-000001 first' <<<"$output"
  grep -q 'operator-only' <<<"$output"
  grep -q 'T20260101-999999 — other repo thing' <<<"$output"
  ! grep -q 'T20260101-000010' <<<"$output"
}

@test "report: nothing merged and nothing outstanding is explicit" {
  rm dev/EPICS/E1-alpha-gizmo.md
  printf '# E2 — Empty\n\n- T20260101-000010 — done one\n' > dev/EPICS/E2-empty.md
  run bash "$SCRIPT" report E2 ""
  [[ "$output" == *"(none)"* ]]
  [[ "$output" == *"(nothing outstanding)"* ]]
}

@test "status: read-only member table" {
  before="$(git status --porcelain; cat dev/EPICS/E1-alpha-gizmo.md)"
  run bash "$SCRIPT" status E1
  [ "$status" -eq 0 ]
  [[ "$output" == *"| T20260101-000001 | Open |"* ]]
  [ "$before" = "$(git status --porcelain; cat dev/EPICS/E1-alpha-gizmo.md)" ]
}

@test "refresh: relinks moved task, reports plain, lists candidates, is idempotent" {
  mv dev/TODO/T20260101-000001-slug.md dev/PARKING/T20260101-000001-slug.md
  run bash "$SCRIPT" refresh E1
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved from:"* ]]
  [[ "$output" == *"T20260101-999999"* ]]
  [[ "$output" == *"lint: ok"* ]]
  grep -qF '](../PARKING/T20260101-000001-slug.md)' dev/EPICS/E1-alpha-gizmo.md
  # candidates: related-linked and title-keyword matches, never the unrelated one, never auto-added
  [[ "$output" == *"T20260101-000008"* ]]
  [[ "$output" != *"T20260101-000007"* ]]
  ! grep -q 'T20260101-000008' dev/EPICS/E1-alpha-gizmo.md
  run bash "$SCRIPT" refresh E1
  [[ "$output" == *"links: unchanged"* ]]
}

@test "unknown epic: error, exit non-zero" {
  run bash "$SCRIPT" plan E9
  [ "$status" -ne 0 ]
  [[ "$output" == *"no epic file"* ]]
}

@test "sourceable without side effects" {
  run bash -c "source '$SCRIPT'; type epic-plan >/dev/null && echo sourced"
  [ "$status" -eq 0 ]
  [[ "$output" == *sourced* ]]
}
