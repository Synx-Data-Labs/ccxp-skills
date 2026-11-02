#!/usr/bin/env bats
# Tests for the "needs a human" marker (T20261102-261809): the shared parser in
# todo/scripts/_lib.sh and the CLI todo/scripts/needs-human.sh.

load test_helper
setup() {
  NH="$REPO_ROOT/todo/scripts/needs-human.sh"
  source "$REPO_ROOT/todo/scripts/_lib.sh"
  export NEEDS_HUMAN_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$NEEDS_HUMAN_ROOT/dev/TODO"
  F="$NEEDS_HUMAN_ROOT/dev/TODO/T20260101-000001-slug.md"
}

_task() { printf -- '---\nstatus: %s\nestimation: 1\nclaimed_by: cc1-abc:123\nclaimed_role: interactive\n---\n\n# T20260101-000001: t\n' "$1" > "$F"; }
_status() { awk 'NR==1&&$0=="---"{n=1;next} n==1&&/^status:/{sub(/^status: ?/,""); print; exit}' "$F"; }

# --- parser (_lib.sh) --------------------------------------------------------

@test "todo-needs-human-kind: each bracketed kind is returned" {
  run todo-needs-human-kind "Open — needs a human [blocked]: x"; [ "$status" -eq 0 ]; [ "$output" = blocked ]
  run todo-needs-human-kind "Design — needs a human [decision]: x"; [ "$output" = decision ]
  run todo-needs-human-kind "In Progress — needs a human [external]: waits: on HashData"; [ "$output" = external ]
}

@test "todo-needs-human-kind: case-insensitive, and legacy unbracketed wording is a decision" {
  run todo-needs-human-kind "Open — Needs A Human [External]: x"; [ "$output" = external ]
  run todo-needs-human-kind "Review — SUPERVISED (needs a human with real access)"; [ "$status" -eq 0 ]; [ "$output" = decision ]
}

@test "todo-needs-human-kind: an unmarked status, an unknown kind and a non-human word are not markers" {
  run todo-needs-human-kind "Open"; [ "$status" -eq 1 ]; [ -z "$output" ]
  run todo-needs-human-kind "Blocked by T20260101-000009"; [ "$status" -eq 1 ]
  run todo-needs-human-kind "Open — needs a human [nonsense]: x"; [ "$output" = decision ]
  run todo-needs-human-kind ""; [ "$status" -eq 1 ]
}

@test "todo-gated: the marker and every legacy human-only word are gated, plain statuses are not" {
  local s
  for s in "Open — needs a human [decision]: x" "In Progress — SUPERVISED (VPN)" "Blocked by T20260101-000009" \
           "Review — BLOCKED on infra" "Open — needs manual QA" "Review — awaiting sign-off"; do
    todo-gated "$s"
  done
  for s in "Open" "Design" "In Progress" "Review"; do
    run todo-gated "$s"; [ "$status" -ne 0 ]
  done
}

# --- CLI ---------------------------------------------------------------------

@test "kind: prints the kind and exits 0 for a marked file, exits 1 for an unmarked one" {
  _task "Open"
  run bash "$NH" kind "$F"; [ "$status" -eq 1 ]
  _task "Open — needs a human [decision]: pick"
  run bash "$NH" kind "$F"; [ "$status" -eq 0 ]; [ "$output" = decision ]
}

@test "kind and mark accept a task id and resolve it under NEEDS_HUMAN_ROOT" {
  _task "Open"
  run bash "$NH" mark T20260101-000001 external "waits on upstream"; [ "$status" -eq 0 ]; [ "$output" = "marked external" ]
  run bash "$NH" kind T20260101-000001; [ "$output" = external ]
  run bash "$NH" kind T20260101-000099; [ "$status" -eq 2 ]
}

@test "mark keeps the leading status and appends the suffix; a second mark replaces it" {
  _task "Design"
  bash "$NH" mark "$F" decision "choose A or B" >/dev/null
  [ "$(_status)" = "Design — needs a human [decision]: choose A or B" ]
  bash "$NH" mark "$F" blocked "needs VPN" >/dev/null
  [ "$(_status)" = "Design — needs a human [blocked]: needs VPN" ]
  # claim fields are untouched without --release
  grep -q '^claimed_by: cc1-abc:123' "$F"
}

@test "mark --release also clears claimed_by and claimed_role" {
  _task "In Progress"
  bash "$NH" mark --release "$F" decision "owner call" >/dev/null
  [ "$(_status)" = "In Progress — needs a human [decision]: owner call" ]
  grep -q '^claimed_by:$' "$F"
  grep -q '^claimed_role:$' "$F"
}

@test "mark validates the kind and requires a reason; a multi-line reason is flattened" {
  _task "Open"
  run bash "$NH" mark "$F" nonsense "x"; [ "$status" -eq 2 ]
  run bash "$NH" mark "$F" decision ""; [ "$status" -eq 2 ]
  bash "$NH" mark "$F" decision $'line one\nline two' >/dev/null
  [ "$(_status)" = "Open — needs a human [decision]: line one line two" ]
  [ "$(_status)" = "$(todo-fm-get "$F" status)" ]
}

@test "mark replaces a folded multi-line status instead of leaving orphan lines" {
  printf -- '---\nstatus: Open — old note that\n  folds onto a second line\nestimation: 1\n---\n# T\n' > "$F"
  bash "$NH" mark "$F" blocked "reason" >/dev/null
  [ "$(grep -c 'second line' "$F")" -eq 0 ]
  grep -q '^estimation: 1$' "$F"
}

@test "clear removes the suffix and restores the leading status; clearing again is a noop" {
  _task "Design"
  bash "$NH" mark "$F" decision "pick" >/dev/null
  run bash "$NH" clear "$F"; [ "$status" -eq 0 ]; [ "$output" = cleared ]
  [ "$(_status)" = "Design" ]
  run bash "$NH" clear "$F"; [ "$status" -eq 1 ]; [ "$output" = noop ]
}

@test "the marked status passes the repo's task-frontmatter lint" {
  _task "Open — needs a human [decision]: pick one: A or B"
  run python3 "$REPO_ROOT/repo-conventions/scripts/lint_tasks.py" --help
  [ "$status" -eq 0 ] || skip "lint_tasks.py has no --help"
  run python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/repo-conventions/scripts')
import lint_tasks as L
assert L.status_head('Open — needs a human [decision]: pick one: A or B') == 'open'
assert L.status_head('Design — needs a human [blocked]: x') == 'design'
"
  [ "$status" -eq 0 ]
}

@test "list: one id/kind/reason line per marked task in dev/TODO, unmarked and queue.md ignored" {
  _task "Open — needs a human [external]: waits on HashData"
  printf -- '---\nstatus: Open\n---\n' > "$NEEDS_HUMAN_ROOT/dev/TODO/T20260101-000002-b.md"
  printf -- '---\nstatus: Review — SUPERVISED (needs a human with VPN)\n---\n' > "$NEEDS_HUMAN_ROOT/dev/TODO/T20260101-000003-c.md"
  echo "- [T20260101-000001](x.md): t" > "$NEEDS_HUMAN_ROOT/dev/TODO/queue.md"
  run bash "$NH" list "$NEEDS_HUMAN_ROOT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'T20260101-000001\texternal\twaits on HashData' ]
  [ "${lines[1]}" = $'T20260101-000003\tdecision\tReview — SUPERVISED (needs a human with VPN)' ]
}

@test "usage text for an unknown command, exit 2" {
  run bash "$NH" bogus; [ "$status" -eq 2 ]
  [[ "$output" == *"needs-human.sh kind"* ]]
}
