#!/usr/bin/env bats
# Tests for todo/scripts/todo-sweep.sh (plan + apply). Offline, fixture
# dev/TODO trees under $BATS_TEST_TMPDIR; never touches a real repo's tasks.

load test_helper
SWEEP="$REPO_ROOT/todo/scripts/todo-sweep.sh"
A=T20000101-000001
B=T20000101-000002
C=T20000101-000003
D=T20000101-000004

setup() {
  export TODAY=2000-02-03
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/dev/TODO" "$R/dev/JOURNAL" "$R/dev/PARKING"
  cd "$R"
}

# _task <id> <slug> <status> [extra body]
_task() {
  printf -- '---\nestimation: 1\nstatus: %s\n---\n\n# %s: Title of %s\n\n%s\n' "$3" "$1" "$2" "${4:-}" > "$R/dev/TODO/$1-$2.md"
}
# _queue <id>... (queue order; slug is always "t")
_queue() {
  { printf '# TODO Queue\n\nProse line.\n\n'; local i; for i in "$@"; do printf -- '- [%s](%s-t.md): Title of t\n' "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
}
_ids() { grep -oE '^- \[T[0-9-]+' "$R/dev/TODO/queue.md" | sed 's/^- \[//' | paste -sd' ' -; }
_sw() { run bash "$SWEEP" "$@" --root "$R"; }

@test "plan: usage errors exit 2" {
  run bash "$SWEEP"; [ "$status" -eq 2 ]
  run bash "$SWEEP" bogus; [ "$status" -eq 2 ]
  run bash "$SWEEP" apply --root "$R"; [ "$status" -eq 2 ]
  run bash "$SWEEP" apply --phase 9 --root "$R"; [ "$status" -eq 2 ]
  run bash "$SWEEP" apply --phase 1 --supersede "$A:$B" --root "$R"; [ "$status" -eq 2 ]
  run bash "$SWEEP" plan --dry-run --root "$R"; [ "$status" -eq 2 ]
  run bash "$SWEEP" plan --root "$R/nope"; [ "$status" -eq 2 ]
}

@test "plan: missing queue fails closed (exit 4)" {
  _task $A t Open
  _sw plan
  [ "$status" -eq 4 ]
}

@test "plan: duplicate queue entry or duplicate task id exits 4" {
  _task $A t Open
  _queue $A $A
  _sw plan; [ "$status" -eq 4 ]
  _queue $A
  cp "$R/dev/TODO/$A-t.md" "$R/dev/TODO/$A-other.md"
  _sw plan; [ "$status" -eq 4 ]
}

@test "plan: malformed queue entry exits 4" {
  _task $A t Open
  _queue $A
  printf -- '- [%s] no link\n' "$B" >> "$R/dev/TODO/queue.md"
  _sw plan; [ "$status" -eq 4 ]
}

@test "plan: clean tree exits 3 with no output" {
  _task $A t Open; _task $B t Design
  _queue $A $B
  _sw plan
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "plan: ADD and REMOVE, title strips the id prefix" {
  _task $A t Open; _task $B t Open
  _queue $A $C
  _sw plan
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ADD\t'"$B"$'\t'"$B-t.md"$'\tTitle of t'* ]]
  [[ "$output" == *$'REMOVE\t'"$C"$'\t'"$C-t.md"* ]]
}

@test "plan: UNBLOCK when every blocker has left dev/TODO, Design if a design section exists" {
  _task $A t "Blocked by $B — waiting on infra"
  _task $C t "Blocked by $D" $'## Design\n\nthing'
  _queue $A $C
  _sw plan
  [[ "$output" == *$'UNBLOCK\t'"$A"$'\tOpen\t'"$B"* ]]
  [[ "$output" == *$'UNBLOCK\t'"$C"$'\tDesign\t'"$D"* ]]
}

@test "plan: a blocker still in dev/TODO is not stale; one stale of two is not unblocked" {
  _task $A t "Blocked by $B, $C"
  _task $B t Open
  _queue $B $A
  _sw plan
  [ "$status" -eq 3 ]
}

@test "plan: ORDER_VIOLATION only when the blocker is queued behind the blocked task" {
  _task $A t "Blocked by $B"; _task $B t Open
  _queue $A $B
  _sw plan
  [ "$output" = "$(printf 'ORDER_VIOLATION\t%s\t%s' "$B" "$A")" ]
  _queue $B $A
  _sw plan
  [ "$status" -eq 3 ]
}

@test "plan: ordering counts tasks ADD would append" {
  _task $A t "Blocked by $B"; _task $B t Open
  _queue $A
  _sw plan
  [[ "$output" == *$'ADD\t'"$B"* ]]
  [[ "$output" == *$'ORDER_VIOLATION\t'"$B"$'\t'"$A"* ]]
}

@test "plan: CLOSE_DONE for Done in dev/TODO, status prefix only" {
  _task $A t Done; _task $B t "Open — Done soon"
  _queue $A $B
  _sw plan
  [ "$output" = "$(printf 'CLOSE_DONE\t%s\t%s-t.md' "$A" "$A")" ]
}

@test "plan: SUPERSEDE_CANDIDATE only on an explicit cross-reference, not in code fences or struck lines" {
  _task $A t Open "Note: absorbed by $C for now."
  _task $B t Open $'```\nsuperseded by '"$C"$'\n```\nAlso related to '"$C"
  _task $D t Open "- ~~superseded by $C~~"
  _queue $A $B $D
  _sw plan
  [ "$status" -eq 0 ]
  [[ "$output" == *$'SUPERSEDE_CANDIDATE\t'"$A"$'\t'"$C"$'\t'* ]]
  [[ "$output" != *"$B"$'\t'"$C"* ]]
  [[ "$output" != *$'SUPERSEDE_CANDIDATE\t'"$D"* ]]
  [[ "$output" != *$'SUPERSEDE_CANDIDATE\t'"$B"* ]]
}

@test "plan is read-only" {
  _task $A t Done; _task $B t "Blocked by $C"
  _queue $A $D
  before="$(find "$R" -type f | sort | xargs cat | cksum)"
  _sw plan
  after="$(find "$R" -type f | sort | xargs cat | cksum)"
  [ "$before" = "$after" ]
}

@test "apply phase 1: syncs membership, keeps existing order and prose, idempotent" {
  _task $A t Open; _task $B t Open; _task $C t Open
  _queue $C $D $A
  _sw apply --phase 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADDED $B"* ]]
  [[ "$output" == *"REMOVED $D"* ]]
  [ "$(_ids)" = "$C $A $B" ]
  grep -q '^Prose line.$' dev/TODO/queue.md
  _sw apply --phase 1
  [ "$status" -eq 3 ]
  [ "$(_ids)" = "$C $A $B" ]
}

@test "apply: --dry-run prints DRY-RUN lines and writes nothing" {
  _task $A t "Blocked by $D"; _task $B t Done
  _queue $A $B
  before="$(find "$R" -type f | sort | xargs cat | cksum)"
  for p in 1 2 3a; do _sw apply --phase $p --dry-run; [[ "$status" -eq 0 || "$status" -eq 3 ]]; done
  _sw apply --phase 2 --dry-run
  [[ "$output" == DRY-RUN\ UNBLOCKED* ]]
  after="$(find "$R" -type f | sort | xargs cat | cksum)"
  [ "$before" = "$after" ]
}

@test "apply phase 2: unblocks, preserves notes, strikes dependency lines, links the journal file" {
  printf -- '---\nstatus: Done\n---\n# x\n' > "dev/JOURNAL/2000-01-02-$B-t.md"
  _task $A t "Blocked by $B — waiting on infra" $'## Dependencies\n\n- **'"$B"$'** — the thing\n- **'"$C"$'** — other\n\n## Notes\n\nmentions '"$B"
  _queue $A
  _sw apply --phase 2
  [ "$status" -eq 0 ]
  grep -q '^status: Open — waiting on infra$' dev/TODO/$A-t.md
  grep -q "^- ~~\*\*$B\*\* — the thing~~ ✅ Done (see dev/JOURNAL/2000-01-02-$B-t.md)$" dev/TODO/$A-t.md
  grep -q "^- \*\*$C\*\* — other$" dev/TODO/$A-t.md
  grep -q "^mentions $B$" dev/TODO/$A-t.md
  head -1 dev/TODO/$A-t.md | grep -qx -- '---'
  _sw apply --phase 2
  [ "$status" -eq 3 ]
}

@test "apply phase 2: no journal file -> Resolved wording, Design when a design section exists" {
  _task $A t "Blocked by $B" $'## Design\n\nx\n\n## Dependencies\n\n- '"$B"
  _queue $A
  _sw apply --phase 2
  grep -q '^status: Design$' dev/TODO/$A-t.md
  grep -q "^- ~~$B~~ ✅ Resolved (no longer in dev/TODO)$" dev/TODO/$A-t.md
}

@test "apply phase 2: moves the blocker immediately before the blocked task, not to the top" {
  _task $A t Open; _task $B t "Blocked by $C"; _task $C t Open; _task $D t Open
  _queue $A $B $D $C
  _sw apply --phase 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOVED $C before $B"* ]]
  [ "$(_ids)" = "$A $C $B $D" ]
  _sw apply --phase 2
  [ "$status" -eq 3 ]
}

@test "apply phase 2: blockers sharing a target keep their relative order" {
  _task $A t "Blocked by $B, $C"; _task $B t Open; _task $C t Open; _task $D t Open
  _queue $A $D $C $B
  _sw apply --phase 2
  [ "$(_ids)" = "$C $B $A $D" ]
}

@test "apply phase 2: chain converges to a topological order" {
  _task $A t "Blocked by $B"; _task $B t "Blocked by $C"; _task $C t Open
  _queue $A $B $C
  _sw apply --phase 2
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$C $B $A" ]
}

@test "apply phase 2: a blocking cycle fails closed (exit 4)" {
  _task $A t "Blocked by $B"; _task $B t "Blocked by $A"
  _queue $A $B
  _sw apply --phase 2
  [ "$status" -eq 4 ]
  [ "$(_ids)" = "$A $B" ]
}

@test "apply phase 2: dry run reflects earlier moves without touching the queue" {
  _task $A t "Blocked by $B"; _task $B t "Blocked by $C"; _task $C t Open
  _queue $A $B $C
  _sw apply --phase 2 --dry-run
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $B $C" ]
}

@test "apply phase 3a: closes a Done task, journal move, queue line removed, idempotent" {
  _task $A t Done; _task $B t Open
  _queue $A $B
  _sw apply --phase 3a
  [ "$status" -eq 0 ]
  [ ! -e dev/TODO/$A-t.md ]
  [ -e "dev/JOURNAL/$TODAY-$A-t.md" ]
  grep -q "^## Closed ($TODAY)$" "dev/JOURNAL/$TODAY-$A-t.md"
  grep -q '^marked Done$' "dev/JOURNAL/$TODAY-$A-t.md"
  [ "$(_ids)" = "$B" ]
  _sw apply --phase 3a
  [ "$status" -eq 3 ]
}

@test "apply phase 3a: uses git mv when the file is tracked, keeps a single Closed section" {
  make_fixture_repo "$R" >/dev/null 2>&1 || git init -q "$R"
  git_identity "$R"
  _task $A t Done $'## Closed (1999-01-01)\n\nearlier'
  _queue $A
  git add -A && git commit -qm fixture
  _sw apply --phase 3a
  [ "$status" -eq 0 ]
  git status --porcelain | grep -q "^R.*dev/JOURNAL/$TODAY-$A-t.md"
  [ "$(grep -c '^## Closed (' "dev/JOURNAL/$TODAY-$A-t.md")" -eq 1 ]
}

@test "apply phase 3a: supersede closes only confirmed candidates" {
  _task $A t Open "absorbed by $C"; _task $B t Open "superseded by $C"
  _queue $A $B
  _sw apply --phase 3a
  [ "$status" -eq 3 ]
  _sw apply --phase 3a --supersede "$A:$C"
  [ "$status" -eq 0 ]
  [ -e "dev/JOURNAL/$TODAY-$A-t.md" ]
  [ -e dev/TODO/$B-t.md ]
  grep -q "^superseded by $C$" "dev/JOURNAL/$TODAY-$A-t.md"
  [ "$(_ids)" = "$B" ]
}

@test "apply phase 3a: --supersede that is not a candidate fails closed, nothing written" {
  _task $A t Done; _task $B t Open "plain text"
  _queue $A $B
  _sw apply --phase 3a --supersede "$B:$C"
  [ "$status" -eq 4 ]
  [ -e dev/TODO/$A-t.md ]
  [ "$(_ids)" = "$A $B" ]
}

@test "apply phase 3a: existing journal target fails closed, nothing moved" {
  _task $A t Done; _task $B t Done
  _queue $A $B
  : > "dev/JOURNAL/$TODAY-$B-t.md"
  _sw apply --phase 3a
  [ "$status" -eq 4 ]
  [ -e dev/TODO/$A-t.md ]
  [ "$(_ids)" = "$A $B" ]
}

@test "full sweep over a drifted tree converges: second pass of every phase exits 3" {
  _task $A t "Blocked by $D" ; _task $B t Done; _task $C t "Blocked by $A"
  _queue $C $A
  for p in 1 2 3a; do _sw apply --phase $p; [ "$status" -eq 0 ]; done
  for p in 1 2 3a; do _sw apply --phase $p; [ "$status" -eq 3 ]; done
  _sw plan
  [ "$status" -eq 3 ]
  [ "$(_ids)" = "$A $C" ]
}

# ---- park (apply an owner-approved list) ----------------------------------

@test "park: sets Parked, adds the section, moves to PARKING, drops the queue line" {
  _task $A t Open; _task $B t Open; _queue $A $B
  _sw park "$A:stale: nobody wants this"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARKED $A -> dev/PARKING/$A-t.md"* ]]
  [ ! -e "$R/dev/TODO/$A-t.md" ]
  grep -qx 'status: Parked' "$R/dev/PARKING/$A-t.md"
  grep -qx '## Parked (2000-02-03)' "$R/dev/PARKING/$A-t.md"
  grep -qx 'stale: nobody wants this' "$R/dev/PARKING/$A-t.md"
  [ "$(_ids)" = "$B" ]
  [ -e "$R/dev/TODO/$B-t.md" ]
}

@test "park: second run skips the already parked id and exits 3" {
  _task $A t Open; _queue $A
  _sw park "$A:why"; [ "$status" -eq 0 ]
  _sw park "$A:why"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SKIPPED $A"* ]]
  [ "$(grep -c '^## Parked' "$R/dev/PARKING/$A-t.md")" -eq 1 ]
}

@test "park: --dry-run changes nothing" {
  _task $A t Open; _queue $A
  _sw park "$A:why" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN PARKED $A"* ]]
  [ -e "$R/dev/TODO/$A-t.md" ]
  [ "$(_ids)" = "$A" ]
}

@test "park: unknown id or existing target fails closed (exit 4), parking nothing" {
  _task $A t Open; _task $B t Open; _queue $A $B
  _sw park "$A:why" "$C:why"; [ "$status" -eq 4 ]
  [ -e "$R/dev/TODO/$A-t.md" ]
  : > "$R/dev/PARKING/$B-t.md"
  _sw park "$A:why" "$B:why"; [ "$status" -eq 4 ]
  [ -e "$R/dev/TODO/$A-t.md" ]
  [ "$(_ids)" = "$A $B" ]
}

@test "park: uses git mv for a tracked task and bad args exit 2" {
  git init -q "$R"; git_identity "$R"
  _task $A t Open; _queue $A
  git -C "$R" add -A; git -C "$R" commit -q -m init
  _sw park "$A:why"; [ "$status" -eq 0 ]
  git -C "$R" status --porcelain | grep -q "^R.*$A-t.md"
  run bash "$SWEEP" park --root "$R"; [ "$status" -eq 2 ]
  run bash "$SWEEP" park --root "$R" "$A"; [ "$status" -eq 2 ]
  run bash "$SWEEP" plan --root "$R" "$A:why"; [ "$status" -eq 2 ]
}

@test "park: a repeated id is parked once (first reason wins); a stale queue line for a parked id is dropped" {
  _task $A t Open; _task $B t Open; _queue $A $B
  _sw park "$A:first" "$A:second"
  [ "$status" -eq 0 ]
  grep -qx 'first' "$R/dev/PARKING/$A-t.md"
  ! grep -q second "$R/dev/PARKING/$A-t.md"
  mv "$R/dev/TODO/$B-t.md" "$R/dev/PARKING/$B-t.md"
  _queue $B
  _sw park "$B:why"
  [ "$status" -eq 3 ]
  [ -z "$(_ids)" ]
}
