#!/usr/bin/env bats
# Tests for _repos/repos.sh — repo registry: scan, list, paths (T20261031-139856).
# Hermetic: temp roots with real git repos, a real linked worktree and a real
# submodule; CLAUDE_CONFIG_DIR points at a temp dir so no developer registry
# is read or written. No network.

load test_helper

REPOS="$REPO_ROOT/_repos/repos.sh"

setup() {
  ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/ws"
  mkdir -p "$ROOT"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  export REPOS_CACHE_TTL=600
  REG="$CLAUDE_CONFIG_DIR/ccxp-repos.json"
  CACHE="$CLAUDE_CONFIG_DIR/state/ccxp-repos.json"
}

# mkrepo <dir> [marker=1] — git repo with a first commit and optionally dev/TODO.
mkrepo() {
  local d="$1" marker="${2:-1}"
  mkdir -p "$d"
  git -C "$d" init -q .
  git_identity "$d"
  if [ "$marker" = 1 ]; then
    mkdir -p "$d/dev/TODO"
    : >"$d/dev/TODO/.gitkeep"
  fi
  : >"$d/README"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
}

reg_paths() { jq -r '.repos[].path' "$REG" | sort; }

@test "guidelines-only folder is not listed" {
  mkrepo "$ROOT/real"
  mkrepo "$ROOT/docsonly" 0
  mkdir -p "$ROOT/docsonly/dev"
  : >"$ROOT/docsonly/dev/guidelines.md"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 added, 0 removed, 0 unchanged"* ]]
  [ "$(reg_paths)" = "$ROOT/real" ]
}

@test "a plain folder with dev/TODO but no git is not a repo" {
  mkdir -p "$ROOT/nogit/dev/TODO"
  mkrepo "$ROOT/real"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/real" ]
}

@test "depth 1 vs owner/repo depth 2" {
  mkrepo "$ROOT/top"
  mkrepo "$ROOT/org/nested"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$(printf '%s\n%s\n' "$ROOT/org/nested" "$ROOT/top")" ]
  run bash "$REPOS" scan "$ROOT" --depth 1
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/top" ]
  [[ "$output" == *"1 removed"* ]]
}

@test "never descends into a repo or symlink" {
  mkrepo "$ROOT/outer"
  mkrepo "$ROOT/outer/inner"
  mkrepo "$BATS_TEST_TMPDIR/elsewhere/linked"
  ln -s "$BATS_TEST_TMPDIR/elsewhere/linked" "$ROOT/linkedrepo"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/outer" ]
  [[ "$output" == *"1 symlink(s) skipped"* ]]
}

@test "linked worktree collapses under main" {
  mkrepo "$ROOT/main"
  git -C "$ROOT/main" worktree add -q "$ROOT/main-wt-x" -b wt-x
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/main" ]
  [[ "$output" == *"main (wt main-wt-x)"* ]]
}

@test "a linked worktree outside the root still adds its qualifying main" {
  mkrepo "$BATS_TEST_TMPDIR/home-of-main"
  mkdir -p "$ROOT"
  git -C "$BATS_TEST_TMPDIR/home-of-main" worktree add -q "$ROOT/wt-only" -b other
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$(cd "$BATS_TEST_TMPDIR/home-of-main" && pwd -P)" ]
}

@test "submodule root is skipped" {
  mkrepo "$BATS_TEST_TMPDIR/subsrc"
  mkrepo "$ROOT/host"
  git -C "$ROOT/host" -c protocol.file.allow=always submodule add -q "$BATS_TEST_TMPDIR/subsrc" sub
  [ -f "$ROOT/host/sub/.git" ]
  run bash "$REPOS" scan "$ROOT/host/sub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 added, 0 removed, 0 unchanged"* ]]
  [ -z "$(reg_paths)" ]
}

@test "--all is display-only" {
  mkrepo "$ROOT/real"
  mkrepo "$ROOT/plain" 0
  run bash "$REPOS" scan "$ROOT" --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain"* ]]
  [[ "$output" == *"display-only"* ]]
  [ ! -e "$REG" ]
  [ ! -e "$CACHE" ]
}

@test "aliases survive rescan" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  jq '.repos[0].aliases = ["rl"]' "$REG" >"$REG.new" && mv "$REG.new" "$REG"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos[0].aliases[0]' "$REG")" = "rl" ]
  [[ "$output" == *"0 added, 0 removed, 1 unchanged"* ]]
}

@test "slug comes from origin, ssh alias included" {
  mkrepo "$ROOT/real"
  git -C "$ROOT/real" remote add origin git@my-alias:some-org/real-repo.git
  bash "$REPOS" scan "$ROOT" >/dev/null
  [ "$(jq -r '.repos[0].slug' "$REG")" = "some-org/real-repo" ]
}

@test "stale path pruned by scan, omitted by list" {
  mkrepo "$ROOT/keep"
  mkrepo "$ROOT/gone"
  bash "$REPOS" scan "$ROOT" >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/graveyard"
  mv "$ROOT/gone" "$BATS_TEST_TMPDIR/graveyard/gone"
  run bash "$REPOS" list --fresh
  [ "$status" -eq 0 ]
  [[ "$output" != *" gone "* ]]
  [[ "$output" == *"1 stale path(s) skipped"* ]]
  [ "$(jq '.repos | length' "$REG")" -eq 2 ]
  run bash "$REPOS" scan "$ROOT"
  [[ "$output" == *"0 added, 1 removed, 1 unchanged"* ]]
  [ "$(jq '.repos | length' "$REG")" -eq 1 ]
}

@test "malformed registry is not overwritten" {
  mkrepo "$ROOT/real"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{not json' >"$REG"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 6 ]
  [ "$(cat "$REG")" = "{not json" ]
  run bash "$REPOS" list
  [ "$status" -eq 6 ]
}

@test "zero-arg scan stores the sibling root with depth 1" {
  mkrepo "$ROOT/me"
  mkrepo "$ROOT/sibling"
  mkrepo "$ROOT/deeper/inner"
  cd "$ROOT/me"
  run bash "$REPOS" scan
  [ "$status" -eq 0 ]
  [ "$(jq -r '.roots[0].depth' "$REG")" = "1" ]
  [ "$(jq -r '.roots[0].path' "$REG")" = "$ROOT" ]
  [ "$(reg_paths)" = "$(printf '%s\n%s\n' "$ROOT/me" "$ROOT/sibling")" ]
}

@test "scan with nothing to scan exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/not-git"
  cd "$BATS_TEST_TMPDIR/not-git"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" bash "$REPOS" scan
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing to scan"* ]]
}

@test "--roots is not remembered" {
  mkrepo "$ROOT/real"
  run bash "$REPOS" scan --roots "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq '.roots | length' "$REG")" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/real" ]
  run env CCXP_REPO_ROOTS="$ROOT" bash "$REPOS" scan
  [ "$status" -eq 0 ]
  [ "$(jq '.roots | length' "$REG")" -eq 0 ]
}

@test "a path scan remembers the root and a bare scan reuses it" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  [ "$(jq -r '.roots[0].path' "$REG")" = "$ROOT" ]
  mkrepo "$ROOT/late"
  cd "$BATS_TEST_TMPDIR"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" bash "$REPOS" scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 added"* ]]
}

@test "exclude glob" {
  mkrepo "$ROOT/real"
  mkrepo "$ROOT/real-wt-old"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"exclude":["*-wt-*"]}' >"$REG"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/real" ]
  [ "$(jq -r '.exclude[0]' "$REG")" = "*-wt-*" ]
}

@test "scan and list never write into a scanned repo" {
  mkrepo "$ROOT/real"
  : >"$ROOT/real/tracked"
  git -C "$ROOT/real" add tracked
  git -C "$ROOT/real" commit -q -m t
  sleep 1
  touch "$ROOT/real/tracked"      # stat-dirty file: a plain `git status` would rewrite .git/index
  marker="$BATS_TEST_TMPDIR/marker"
  : >"$marker"
  sleep 1
  bash "$REPOS" scan "$ROOT" >/dev/null
  bash "$REPOS" list --fresh >/dev/null
  run find "$ROOT/real" -newer "$marker"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list does not change .git" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  before="$(find "$ROOT/real/.git" -type f | LC_ALL=C sort | xargs cksum)"
  bash "$REPOS" list --fresh >/dev/null
  after="$(find "$ROOT/real/.git" -type f | LC_ALL=C sort | xargs cksum)"
  [ "$before" = "$after" ]
}

@test "list with no registry says to scan and exits 0" {
  run bash "$REPOS" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"/repo scan"* ]]
  run bash "$REPOS" list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "list shows fields and marks the current repo" {
  mkrepo "$ROOT/real"
  : >"$ROOT/real/dev/TODO/T20260101-000001-first.md"
  : >"$ROOT/real/dev/TODO/T20260101-000002-second.md"
  printf '# Q\n\n- [T20260101-000002](T20260101-000002-second.md): the second thing\n- [T20260101-000001](T20260101-000001-first.md): first\n' >"$ROOT/real/dev/TODO/queue.md"
  echo dirty >>"$ROOT/real/README"
  mkrepo "$ROOT/other"
  bash "$REPOS" scan "$ROOT" >/dev/null
  cd "$ROOT/real"
  run bash "$REPOS" list --fresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO"*"BRANCH"*"DIRTY"*"TASKS"*"TOP"* ]]
  real_line="$(printf '%s\n' "$output" | grep -E '^\*[[:space:]]+real ')"
  [[ "$real_line" == *"dirty"* ]]
  [[ "$real_line" == *" 2 "* ]]
  [[ "$real_line" == *"T20260101-000002 the second thing"* ]]
  other_line="$(printf '%s\n' "$output" | grep -E '^ [[:space:]]+other ')"
  [[ "$other_line" == *"clean"* ]]
}

@test "list names a current repo that is not registered" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  mkrepo "$BATS_TEST_TMPDIR/unregistered"
  cd "$BATS_TEST_TMPDIR/unregistered"
  run bash "$REPOS" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Current repo:"*"unregistered"*"not in the registry"* ]]
}

@test "list --json" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  cd "$ROOT/real"
  run bash "$REPOS" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].name')" = "real" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].current')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].dirty')" = "false" ]
}

@test "queue top skips struck-through" {
  mkrepo "$ROOT/real"
  printf '# Q\n\n- [T20260101-000008](a.md): ~~already shipped~~\n- [T20260101-000009](a.md): live one\n' >"$ROOT/real/dev/TODO/queue.md"
  bash "$REPOS" scan "$ROOT" >/dev/null
  run bash "$REPOS" list --json
  [ "$(printf '%s' "$output" | jq -r '.[0].top_task')" = "T20260101-000009 live one" ]
}

@test "worktree has its own row" {
  mkrepo "$ROOT/main"
  git -C "$ROOT/main" worktree add -q "$ROOT/main-wt-x" -b wt-x
  bash "$REPOS" scan "$ROOT" >/dev/null
  cd "$ROOT/main-wt-x"
  run bash "$REPOS" list --fresh
  [ "$status" -eq 0 ]
  wt_line="$(printf '%s\n' "$output" | grep -F '(wt main-wt-x)')"
  [[ "$wt_line" == "*"* ]]
  [[ "$wt_line" == *"wt-x"* ]]
}

@test "cache reused then invalidated (registry, dir mtime, --fresh)" {
  mkrepo "$ROOT/real"
  bash "$REPOS" scan "$ROOT" >/dev/null
  # New task file: not visible while the cache is fresh, visible with --fresh.
  : >"$ROOT/real/dev/TODO/T20260101-000005-new.md"
  run bash "$REPOS" list --json
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "0" ]
  run bash "$REPOS" list --json --fresh
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "1" ]
  # Registry change (explicit mtime) invalidates.
  : >"$ROOT/real/dev/TODO/T20260101-000006-new.md"
  touch -t 203001010000 "$REG"
  run bash "$REPOS" list --json
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "2" ]
  # TTL 0 invalidates.
  : >"$ROOT/real/dev/TODO/T20260101-000007-new.md"
  REPOS_CACHE_TTL=0 run bash "$REPOS" list --json
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "3" ]
  # A scanned folder that changed prints the rescan hint and recomputes.
  : >"$ROOT/real/dev/TODO/T20260101-000008-new.md"
  touch -t 203001010000 "$ROOT"
  run bash "$REPOS" list
  [[ "$output" == *"Scanned folders changed"* ]]
  run bash "$REPOS" list --json
  [ "$(printf '%s' "$output" | jq -r '.[0].open_tasks')" = "4" ]
}

@test "path with spaces" {
  mkrepo "$ROOT/with space/repo one"
  run bash "$REPOS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(reg_paths)" = "$ROOT/with space/repo one" ]
  run bash "$REPOS" list --fresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo one"* ]]
}

@test "paths lists registry plus siblings, no worktrees" {
  mkrepo "$ROOT/me"
  mkrepo "$ROOT/sibling"
  mkrepo "$BATS_TEST_TMPDIR/elsewhere/reg"
  git -C "$ROOT/me" worktree add -q "$ROOT/me-wt" -b mywt
  bash "$REPOS" scan "$BATS_TEST_TMPDIR/elsewhere" >/dev/null
  cd "$ROOT/me"
  run bash "$REPOS" paths
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s\n%s\n' "$BATS_TEST_TMPDIR/elsewhere/reg" "$ROOT/me" "$ROOT/sibling" | sed "s#^$BATS_TEST_TMPDIR#$(cd "$BATS_TEST_TMPDIR" && pwd -P)#" | LC_ALL=C sort)" ]
}

@test "usage: unknown verb exits 2, help exits 0" {
  run bash "$REPOS" bogus
  [ "$status" -eq 2 ]
  run bash "$REPOS" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"repos.sh scan"* ]]
}

@test "sourcing the script has no side effects" {
  run bash -c "source '$REPOS'; type repos-scan >/dev/null && echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "repo.sh forwards scan and list and rejects unknown verbs" {
  RS="$REPO_ROOT/repo/scripts/repo.sh"
  mkrepo "$ROOT/real"
  run bash "$RS" scan "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 added"* ]]
  run bash "$RS" list --fresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]]
  run bash "$RS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real"* ]]
  run bash "$RS" frobnicate
  [ "$status" -eq 2 ]
}

@test "bare scan keeps a remembered depth-2 root" {
  mkrepo "$ROOT/me"
  mkrepo "$ROOT/org/nested"
  bash "$REPOS" scan "$ROOT" >/dev/null
  [ "$(jq -r '.roots[0].depth' "$REG")" = "2" ]
  cd "$ROOT/me"
  run bash "$REPOS" scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 added, 0 removed, 2 unchanged"* ]]
  [ "$(jq -r '.roots[0].depth' "$REG")" = "2" ]
}

@test "list does not invoke a configured fsmonitor" {
  mkrepo "$ROOT/real"
  mkdir -p "$BATS_TEST_TMPDIR/fsm-calls"
  cat >"$BATS_TEST_TMPDIR/fsm.sh" <<HOOK
#!/bin/sh
touch "$BATS_TEST_TMPDIR/fsm-calls/called.\$\$"
HOOK
  chmod +x "$BATS_TEST_TMPDIR/fsm.sh"
  git -C "$ROOT/real" config core.fsmonitor "$BATS_TEST_TMPDIR/fsm.sh"
  # Precondition: a plain `git status` does call the hook, so the test can fail.
  git -C "$ROOT/real" status --porcelain >/dev/null 2>&1 || true
  [ "$(ls "$BATS_TEST_TMPDIR/fsm-calls" | wc -l | tr -d ' ')" -ge 1 ]
  before="$(ls "$BATS_TEST_TMPDIR/fsm-calls" | wc -l | tr -d ' ')"
  bash "$REPOS" scan "$ROOT" >/dev/null
  bash "$REPOS" list --fresh >/dev/null
  [ "$(ls "$BATS_TEST_TMPDIR/fsm-calls" | wc -l | tr -d ' ')" = "$before" ]
}

@test "CDPATH does not break a relative scan path" {
  mkrepo "$ROOT/real"
  cd "$BATS_TEST_TMPDIR"
  run env CDPATH="$BATS_TEST_TMPDIR:/" bash "$REPOS" scan ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 added"* ]]
}

@test "scan --depth or --roots without a value exits 2" {
  run bash "$REPOS" scan --depth
  [ "$status" -eq 2 ]
  run bash "$REPOS" scan --roots
  [ "$status" -eq 2 ]
}

@test "paths honours the registry exclude globs" {
  mkrepo "$ROOT/me"
  mkrepo "$ROOT/me-wt-skipme"
  mkrepo "$ROOT/sibling"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"exclude":["*-wt-*"]}' >"$REG"
  cd "$ROOT/me"
  run bash "$REPOS" paths
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT/sibling"* ]]
  [[ "$output" != *"skipme"* ]]
}
