#!/usr/bin/env bats
# i202: epic members that live in ANOTHER repo (plain IDs or GitHub blob URLs)
# resolve through the owning repo and count by its state; refresh never
# rewrites a GitHub-URL member. No network: TASKID_GH is a fixture-tree stub
# and a fake `gh` shadows the real one for the PR lookup.

load test_helper
setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/epics"
  EPIC="$REPO_ROOT/epic/scripts/epic.sh"
  STATUS="$REPO_ROOT/ccxp/scripts/epic-status.sh"
  LINKS="$REPO_ROOT/_taskid/epic-links.sh"
  export TMPDIR="$BATS_TEST_TMPDIR" CCXP_PEER_MODE=1
  export REMOTE_FIXTURE="$FIX/remote" TASKID_GH="$FIX/remote-gh.sh"
  export REMOTE_GH_LOG="$BATS_TEST_TMPDIR/remote-gh.log"
  use_fake_bin "$FIX/fake-gh.sh" gh
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/dev/TODO" "$R/dev/PARKING" "$R/dev/JOURNAL" "$R/dev/EPICS"
  cd "$R"
  git init -q .
  git remote add origin git@github.com:team/hub.git
  printf -- '---\nstatus: Open\n---\n\n# T20260101-000001: local open\n' > dev/TODO/T20260101-000001-local.md
  U="https://github.com/other-org/other-repo/blob/main/dev"
  cat > dev/EPICS/E1-mixed.md <<EOF2
# E1 — Mixed repos

Goal: g

- [T20260101-000001](../TODO/T20260101-000001-local.md) — local open
- T20260201-000001 — plain id, remote in progress
- T20260201-000002 — plain id, remote done
- [T20260201-000003]($U/TODO/T20260201-000003-remote-url.md) — url member
- [T20260201-000002]($U/TODO/T20260201-000002-stale-path.md) — url member, file moved to JOURNAL
- T20260201-999999 — nowhere
EOF2
}

@test "plan: plain remote ids resolve via the repos named by URL members" {
  run bash "$EPIC" plan E1
  [ "$status" -eq 0 ]
  grep -qE $'^T20260201-000001\texternal\tother-repo:other-org/other-repo\tIn Progress\t' <<<"$output"
  grep -qE $'^T20260201-000002\tskip\tdone\tDone\t' <<<"$output"
  grep -qE $'^T20260201-000003\texternal\tother-repo:other-org/other-repo\tOpen\t' <<<"$output"
  grep -qE $'^T20260201-999999\texternal\tno-file\t' <<<"$output"
}

@test "plan: a stale URL path is re-resolved by id (file moved to JOURNAL = done)" {
  run bash "$EPIC" plan E1
  [ "$(grep -c $'^T20260201-000002\tskip\tdone' <<<"$output")" = "2" ]
}

@test "plan: TASKID_REMOTE_REPOS names the repo when no URL member does" {
  sed -i.bak -E '/blob\/main/d' dev/EPICS/E1-mixed.md
  run bash "$EPIC" plan E1
  grep -qE $'^T20260201-000001\texternal\tno-file\t' <<<"$output"
  TASKID_REMOTE_REPOS="other-org/other-repo" run bash "$EPIC" plan E1
  grep -qE $'^T20260201-000001\texternal\tother-repo:other-org/other-repo\tIn Progress\t' <<<"$output"
}

@test "status roll-up counts remote Done/In Progress/Open from the source of truth" {
  run bash "$STATUS" render
  [ "$status" -eq 0 ]
  # local Open, remote In Progress, 2x remote Done (plain + URL), remote Open, 1 unresolved
  grep -q '6 tasks: 2 Done · 0 Review · 1 In Progress · 0 Design · 0 Blocked/Parked · 2 Open' <<<"$output"
  grep -q 'T20260201-999999 unresolved' <<<"$output"
  [ "$(grep -c unresolved <<<"$output")" = "1" ]
}

@test "status: member table shows remote status and counts Done" {
  run bash "$EPIC" status E1
  [ "$status" -eq 0 ]
  grep -qE '^\| T20260201-000002 \| Done \|' <<<"$output"
  grep -qE '^\| T20260201-000001 \| In Progress \|' <<<"$output"
}

@test "status: a gh failure degrades to unresolved, never aborts" {
  TASKID_GH=false run bash "$STATUS" render
  [ "$status" -eq 0 ]
  grep -q 'unresolved' <<<"$output"
}

@test "refresh: GitHub-URL members are left byte-identical, local links still sync" {
  cp dev/EPICS/E1-mixed.md "$BATS_TEST_TMPDIR/before.md"
  run bash "$EPIC" refresh E1
  [ "$status" -eq 0 ]
  grep -qF "[T20260201-000003]($U/TODO/T20260201-000003-remote-url.md)" dev/EPICS/E1-mixed.md
  grep -qF "[T20260201-000002]($U/TODO/T20260201-000002-stale-path.md)" dev/EPICS/E1-mixed.md
  run diff "$BATS_TEST_TMPDIR/before.md" dev/EPICS/E1-mixed.md
  [ "$status" -eq 0 ]
}

@test "epic-links sync: URL member stays a URL; lint does not flag it" {
  run bash "$LINKS" sync
  [ "$status" -eq 0 ]
  grep -q 'blob/main/dev/TODO/T20260201-000003' dev/EPICS/E1-mixed.md
  run bash "$LINKS" lint
  [ "$status" -eq 0 ]
}

@test "epic-links sync: plain id with no local file stays plain (not turned into a URL)" {
  bash "$LINKS" sync 2>/dev/null
  grep -qE '^- T20260201-000001 — plain id' dev/EPICS/E1-mixed.md
}
