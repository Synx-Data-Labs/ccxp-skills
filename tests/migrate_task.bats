#!/usr/bin/env bats
# Tests for migrate-task/scripts/migrate.sh — moves a task file from one
# repo's dev/TODO/ to another's (T20260827-201400).
#
# Pure logic (frontmatter field get/delete, collision-check, bidirectional-
# blocking check, queue.md append-or-insert-before) is tested by sourcing the
# script. The full `--dry-run` path is exercised end-to-end against two real
# local git repos (no network, no `gh`) — mirroring tests/task_claim.bats'
# keystone-test style of using `git init` fixtures instead of mocks. The
# live push/PR-opening path is untested integration surface, same convention
# as task_claim.sh's thin gh/git I/O wrappers.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/migrate-task/scripts/migrate.sh"
}

_mk_task_file() {
  # $1 path, $2 extra frontmatter lines (optional), $3 body blocks: line (optional)
  local extra="${2:-}"
  cat > "$1" <<EOF
---
estimation: 1h
status: Open
source: test fixture
target-repo: your-org/private-skills-repo
${extra}
---

# T20260101-000001: Demo task

## Problem

Demo.
EOF
}

# --- frontmatter helpers (pure) ---------------------------------------------

@test "mt-fm-get reads a frontmatter field" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  [ "$(mt-fm-get "$f" status)" = "Open" ]
}

@test "mt-fm-get returns empty for an absent field" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  [ -z "$(mt-fm-get "$f" claimed_by)" ]
}

@test "mt-fm-delete removes a frontmatter field and leaves others intact" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f"
  mt-fm-delete "$f" target-repo
  [ -z "$(mt-fm-get "$f" target-repo)" ]
  [ "$(mt-fm-get "$f" status)" = "Open" ]
  ! grep -q '^target-repo:' "$f"
}

@test "mt-fm-delete never touches a body line that looks like frontmatter" {
  f="$BATS_TEST_TMPDIR/t.md"
  _mk_task_file "$f"
  printf '\n## Notes\n\ntarget-repo: this body line must survive\n' >> "$f"
  mt-fm-delete "$f" target-repo
  grep -qx 'target-repo: this body line must survive' "$f"
}

# --- collision check (pure, real filesystem) --------------------------------

@test "mt-collision-check passes when the id exists nowhere in the target" {
  dest="$BATS_TEST_TMPDIR/dest"; mkdir -p "$dest/dev/TODO" "$dest/dev/PARKING" "$dest/dev/JOURNAL"
  run mt-collision-check "$dest/dev" T20260101-000001
  [ "$status" -eq 0 ]
}

@test "mt-collision-check fails when the id already exists in target TODO" {
  dest="$BATS_TEST_TMPDIR/dest"; mkdir -p "$dest/dev/TODO"
  touch "$dest/dev/TODO/T20260101-000001-already-here.md"
  run mt-collision-check "$dest/dev" T20260101-000001
  [ "$status" -ne 0 ]
  [[ "$output" == *"T20260101-000001-already-here.md"* ]]
}

@test "mt-collision-check fails when the id already exists in target JOURNAL" {
  dest="$BATS_TEST_TMPDIR/dest"; mkdir -p "$dest/dev/JOURNAL"
  touch "$dest/dev/JOURNAL/2026-01-01-T20260101-000001-old.md"
  run mt-collision-check "$dest/dev" T20260101-000001
  [ "$status" -ne 0 ]
}

# --- bidirectional-blocking check (pure) ------------------------------------

@test "mt-blocking-check passes when the task has no blocks: and nothing is Blocked by it" {
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src/dev/TODO"
  f="$src/dev/TODO/T20260101-000001-demo.md"; _mk_task_file "$f"
  run mt-blocking-check "$src/dev/TODO" T20260101-000001 "$f"
  [ "$status" -eq 0 ]
}

@test "mt-blocking-check fails when the migrated task itself has a non-empty blocks:" {
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src/dev/TODO"
  f="$src/dev/TODO/T20260101-000001-demo.md"
  _mk_task_file "$f" "blocks: [T20260101-000002]"
  run mt-blocking-check "$src/dev/TODO" T20260101-000001 "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocks:"* ]]
}

@test "mt-blocking-check fails when another source task is Blocked by it" {
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src/dev/TODO"
  f="$src/dev/TODO/T20260101-000001-demo.md"; _mk_task_file "$f"
  cat > "$src/dev/TODO/T20260101-000002-other.md" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000001 — waiting on the demo task
---

# T20260101-000002: Other task
EOF
  run mt-blocking-check "$src/dev/TODO" T20260101-000001 "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"T20260101-000002"* ]]
}

@test "mt-blocking-check fails when the migrated task is the SECOND id in a multi-blocker status" {
  # lifecycle.md documents "Blocked by T{id} (list all blockers)", and
  # lint_tasks.py's check_blocked_by uses findall — a status line can legally
  # name more than one blocker (e.g. "Blocked by T1, T2"). The migrated task
  # must be caught regardless of its position in that list.
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src/dev/TODO"
  f="$src/dev/TODO/T20260101-000001-demo.md"; _mk_task_file "$f"
  cat > "$src/dev/TODO/T20260101-000002-other.md" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000003, T20260101-000001
---

# T20260101-000002: Other task
EOF
  run mt-blocking-check "$src/dev/TODO" T20260101-000001 "$f"
  [ "$status" -ne 0 ]
}

@test "mt-blocking-check's self-skip works even when task_file is spelled relative and todo_dir absolute" {
  # Regression: migrate-task() calls this with an absolute todo_dir but a
  # relative source_file (both point at the same file, spelled differently).
  # Give the file itself a (corrupt/contrived) self-referential status so the
  # scan loop would find a false positive on its OWN line unless the
  # self-skip comparison correctly recognizes "this is the file being
  # migrated" regardless of how the path was spelled.
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src/dev/TODO"
  f="$src/dev/TODO/T20260101-000001-demo.md"
  cat > "$f" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000001
---

# T20260101-000001: Self-referential fixture
EOF
  cd "$src"
  run mt-blocking-check "$src/dev/TODO" T20260101-000001 "dev/TODO/T20260101-000001-demo.md"
  [ "$status" -eq 0 ]
}

# --- target-side "blocked by the migrated task" lookup (pure) --------------

@test "mt-target-blocked-by returns empty when nothing in target is blocked by it" {
  dst="$BATS_TEST_TMPDIR/dst"; mkdir -p "$dst/dev/TODO"
  cat > "$dst/dev/TODO/T2-other.md" <<'EOF'
---
estimation: 1h
status: Open
---

# T2: Other
EOF
  [ -z "$(mt-target-blocked-by "$dst/dev/TODO" T20260101-000001)" ]
}

@test "mt-target-blocked-by returns the id of the target task blocked by it" {
  dst="$BATS_TEST_TMPDIR/dst"; mkdir -p "$dst/dev/TODO"
  cat > "$dst/dev/TODO/T2-other.md" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000001 — waiting on the migrated task
---

# T2: Other
EOF
  [ "$(mt-target-blocked-by "$dst/dev/TODO" T20260101-000001)" = "T2" ]
}

@test "mt-target-blocked-by finds it as the second id in a multi-blocker status" {
  dst="$BATS_TEST_TMPDIR/dst"; mkdir -p "$dst/dev/TODO"
  cat > "$dst/dev/TODO/T2-other.md" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000099, T20260101-000001
---

# T2: Other
EOF
  [ "$(mt-target-blocked-by "$dst/dev/TODO" T20260101-000001)" = "T2" ]
}

# --- queue.md append-or-insert-before (pure) --------------------------------

@test "mt-queue-insert appends when the task blocks nothing already queued" {
  q="$BATS_TEST_TMPDIR/queue.md"
  printf '# TODO Queue\n\n- [T1](T1-a.md): A\n' > "$q"
  mt-queue-insert "$q" T2 T2-b.md "B" ""
  run tail -n1 "$q"
  [[ "$output" == "- [T2](T2-b.md): B" ]]
}

@test "mt-queue-insert inserts immediately before the frontmost task it blocks" {
  q="$BATS_TEST_TMPDIR/queue.md"
  printf '# TODO Queue\n\n- [T1](T1-a.md): A\n- [T3](T3-c.md): C\n' > "$q"
  mt-queue-insert "$q" T2 T2-b.md "B" "T3"
  grep -n "T1\]\|T2\]\|T3\]" "$q" | awk -F: '{print $1}' > "$BATS_TEST_TMPDIR/lines"
  # T2's line number must be less than T3's (inserted before it), greater than T1's
  t1=$(grep -n 'T1\]' "$q" | cut -d: -f1)
  t2=$(grep -n 'T2\]' "$q" | cut -d: -f1)
  t3=$(grep -n 'T3\]' "$q" | cut -d: -f1)
  [ "$t1" -lt "$t2" ]
  [ "$t2" -lt "$t3" ]
}

@test "mt-queue-insert creates queue.md with the canonical header if missing" {
  q="$BATS_TEST_TMPDIR/queue.md"
  mt-queue-insert "$q" T2 T2-b.md "B" ""
  [ -f "$q" ]
  grep -q "TODO Queue" "$q"
  grep -q "T2\]" "$q"
}

# --- end-to-end --dry-run against two real local git repos ------------------

_git_init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
}

@test "--dry-run prints both diffs and mutates neither repo" {
  src="$BATS_TEST_TMPDIR/src-repo"; dst="$BATS_TEST_TMPDIR/dst-repo"
  _git_init_repo "$src"; _git_init_repo "$dst"

  mkdir -p "$src/dev/TODO"
  _mk_task_file "$src/dev/TODO/T20260101-000001-demo.md"
  printf '# TODO Queue\n\n- [T20260101-000001](T20260101-000001-demo.md): Demo task\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base
  src_head="$(git -C "$src" rev-parse HEAD)"

  mkdir -p "$dst/dev/TODO"
  printf '# TODO Queue\n' > "$dst/dev/TODO/queue.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base
  dst_head="$(git -C "$dst" rev-parse HEAD)"

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev/TODO/T20260101-000001-demo.md"* ]]
  [[ "$output" == *"dev/JOURNAL/"*"T20260101-000001"* ]]
  [[ "$output" != *"target-repo:"* ]]   # stripped in the printed target-side content

  # Neither repo was actually mutated.
  [ "$(git -C "$src" rev-parse HEAD)" = "$src_head" ]
  [ "$(git -C "$dst" rev-parse HEAD)" = "$dst_head" ]
  [ -z "$(git -C "$src" status --porcelain)" ]
  [ -z "$(git -C "$dst" status --porcelain)" ]
}

@test "--dry-run hard-fails on a collision without touching either repo" {
  src="$BATS_TEST_TMPDIR/src-repo2"; dst="$BATS_TEST_TMPDIR/dst-repo2"
  _git_init_repo "$src"; _git_init_repo "$dst"

  mkdir -p "$src/dev/TODO"
  _mk_task_file "$src/dev/TODO/T20260101-000001-demo.md"
  printf '# TODO Queue\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base

  mkdir -p "$dst/dev/PARKING"
  touch "$dst/dev/PARKING/T20260101-000001-already-there.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"collis"* ]]
}

@test "--dry-run inserts before the target task the migrated task blocks (not appended)" {
  src="$BATS_TEST_TMPDIR/src-repo4"; dst="$BATS_TEST_TMPDIR/dst-repo4"
  _git_init_repo "$src"; _git_init_repo "$dst"

  mkdir -p "$src/dev/TODO"
  _mk_task_file "$src/dev/TODO/T20260101-000001-demo.md"
  printf '# TODO Queue\n\n- [T20260101-000001](T20260101-000001-demo.md): Demo task\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base

  mkdir -p "$dst/dev/TODO"
  cat > "$dst/dev/TODO/T2-other.md" <<'EOF'
---
estimation: 1h
status: Blocked by T20260101-000001 — waiting on the migrated task
---

# T2: Other
EOF
  printf '# TODO Queue\n\n- [T2](T2-other.md): Other\n' > "$dst/dev/TODO/queue.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"immediately before T2"* ]]
}

@test "--dry-run hard-fails when the task's claimed_by is non-empty" {
  src="$BATS_TEST_TMPDIR/src-repo3"; dst="$BATS_TEST_TMPDIR/dst-repo3"
  _git_init_repo "$src"; _git_init_repo "$dst"

  mkdir -p "$src/dev/TODO"
  _mk_task_file "$src/dev/TODO/T20260101-000001-demo.md" "claimed_by: cc1-somehost:abc123"
  printf '# TODO Queue\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base

  mkdir -p "$dst/dev/TODO"
  printf '# TODO Queue\n' > "$dst/dev/TODO/queue.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"claimed_by"* ]]
}

# --- argument / path safety --------------------------------------------------

@test "migrate-task rejects a task-id that isn't the canonical T<8digits>-<6digits> shape" {
  src="$BATS_TEST_TMPDIR/src-repo5"; dst="$BATS_TEST_TMPDIR/dst-repo5"
  _git_init_repo "$src"; _git_init_repo "$dst"
  mkdir -p "$src/dev/TODO" "$src/dev/PARKING"
  # A parked (not TODO) task, which a path-escaping id could otherwise reach.
  # dev/TODO must exist (even empty) for "dev/TODO/../PARKING" to resolve at
  # all during glob pathname expansion — this is not a fixture nicety, it's
  # what makes the escape reachable in the first place.
  _mk_task_file "$src/dev/PARKING/T20260101-000005-parked.md"
  git -C "$src" add -A && git -C "$src" commit -qm base
  mkdir -p "$dst/dev/TODO"; git -C "$dst" add -A 2>/dev/null; git -C "$dst" commit -qm base --allow-empty

  cd "$src"
  run migrate-task '../PARKING/T20260101-000005' "$dst" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"Demo task"* ]]   # never read the escaped file's content
}

@test "migrate-task hard-fails (not silently picks one) when two files match the id in source TODO" {
  src="$BATS_TEST_TMPDIR/src-repo6"; dst="$BATS_TEST_TMPDIR/dst-repo6"
  _git_init_repo "$src"; _git_init_repo "$dst"
  mkdir -p "$src/dev/TODO"
  _mk_task_file "$src/dev/TODO/T20260101-000001-demo.md"
  _mk_task_file "$src/dev/TODO/T20260101-000001-duplicate.md"
  printf '# TODO Queue\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base
  mkdir -p "$dst/dev/TODO"; printf '# TODO Queue\n' > "$dst/dev/TODO/queue.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -ne 0 ]
}

@test "migrate-task rejects an unrecognized flag instead of silently swallowing it as the target" {
  run migrate-task T20260101-000001 --verbose /some/target
  [ "$status" -ne 0 ]
  [[ "$output" == *"unrecognized"* || "$output" == *"unknown"* ]]
}

@test "migrate-task rejects a stray extra positional argument" {
  run migrate-task T20260101-000001 /some/target extra-arg
  [ "$status" -ne 0 ]
}

@test "--dry-run preserves a title containing a literal backslash-n sequence on one line" {
  src="$BATS_TEST_TMPDIR/src-repo7"; dst="$BATS_TEST_TMPDIR/dst-repo7"
  _git_init_repo "$src"; _git_init_repo "$dst"
  mkdir -p "$src/dev/TODO"
  cat > "$src/dev/TODO/T20260101-000001-demo.md" <<'EOF'
---
estimation: 1h
status: Open
---

# T20260101-000001: Fix C:\new-path handling
EOF
  printf '# TODO Queue\n' > "$src/dev/TODO/queue.md"
  git -C "$src" add -A && git -C "$src" commit -qm base
  mkdir -p "$dst/dev/TODO"; printf '# TODO Queue\n' > "$dst/dev/TODO/queue.md"
  git -C "$dst" add -A && git -C "$dst" commit -qm base

  cd "$src"
  run migrate-task T20260101-000001 "$dst" --dry-run
  [ "$status" -eq 0 ]
  # The queue line must stay a single line — a literal newline here means the
  # backslash-n in the title got escape-interpreted instead of passed through
  # by awk -v. The full title text (both sides of the "\n") must appear
  # together on one line of the printed diff.
  [[ "$output" == *'+- [T20260101-000001](T20260101-000001-demo.md): Fix C:\new-path handling'* ]]
}
