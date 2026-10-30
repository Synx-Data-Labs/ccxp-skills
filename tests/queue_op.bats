#!/usr/bin/env bats
# Tests for _queue/queue-op.sh (stage|top|bottom) and its per-skill wrappers
# top.sh, bottom.sh, stage.sh. Offline, fixture dev/TODO trees under
# $BATS_TEST_TMPDIR; never touches a real repo's tasks.

load test_helper
QOP="$REPO_ROOT/_queue/queue-op.sh"
A=T20000101-000001
B=T20000101-000002
C=T20000101-000003
D=T20000101-000004
E=T20000101-000005
F=T20000101-000006

setup() {
  R="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$R" >/dev/null
  cd "$R"
}

# _task <id> [status] [extra frontmatter line]; slug is always "t"
_task() {
  printf -- '---\nestimation: 1\nstatus: %s\n%s\n---\n\n# %s: Title of %s\n' "${2:-Open}" "${3:-}" "$1" "$1" > "$R/dev/TODO/$1-t.md"
}
# _queue <id>...: queue order
_queue() {
  { printf '# TODO Queue\n\nProse line.\n\n'; local i; for i in "$@"; do printf -- '- [%s](%s-t.md): Title of %s\n' "$i" "$i" "$i"; done; } > "$R/dev/TODO/queue.md"
}
_ids() { grep -oE '^- \[T[0-9-]+' "$R/dev/TODO/queue.md" | sed 's/^- \[//' | paste -sd' ' -; }
_commit() { git -C "$R" add -A && git -C "$R" commit -q -m fixture; }
_qop() { run bash "$QOP" "$@" --repo "$R"; }

@test "usage errors exit 2" {
  run bash "$QOP"; [ "$status" -eq 2 ]
  run bash "$QOP" bogus "$A"; [ "$status" -eq 2 ]
  run bash "$QOP" top --repo "$R"; [ "$status" -eq 2 ]
  run bash "$QOP" top --repo "$R" notanid; [ "$status" -eq 2 ]
  run bash "$QOP" top --repo "$R" --nope "$A"; [ "$status" -eq 2 ]
  run bash "$QOP" top --repo "$R" "$A" --before; [ "$status" -eq 2 ]
  run bash "$QOP" bottom --repo "$R" --before "$B" "$A"; [ "$status" -eq 2 ]
  run bash "$QOP" stage --repo "$R" --before "$B" "$A"; [ "$status" -eq 2 ]
  run bash "$QOP" top --repo "$BATS_TEST_TMPDIR/nope" "$A"; [ "$status" -eq 2 ]
}

@test "top: first-listed wins slot 1, others pushed down; adds an unqueued id" {
  for i in $A $B $C $D; do _task $i; done
  _queue $A $B $C
  _qop top $D $C
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$D $C $A $B" ]
  [[ "$output" == *"New queue order:"* ]]
  [[ "$output" == *"1. $D: Title of $D"* ]]
  [[ "$output" == *"CHANGED=1"* ]]
}

@test "top: already first and unchanged is CHANGED=0, exit 0, and idempotent" {
  for i in $A $B; do _task $i; done
  _queue $A $B
  _qop top $A
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGED=0"* ]]
  _qop top $B; [ "$(_ids)" = "$B $A" ]
  _qop top $B; [ "$(_ids)" = "$B $A" ]
  [[ "$output" == *"CHANGED=0"* ]]
}

@test "top: pulls the blocker chain up, blocker first, with annotations" {
  _task $A; _task $B Open; _task $C "Blocked by $B"; _task $D "Blocked by $C - waiting"
  _queue $A $B $C $D
  _qop top $D
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$B $C $D $A" ]
  [[ "$output" == *"1. $B: Title of $B [blocker of $C, pulled up]"* ]]
  [[ "$output" == *"2. $C: Title of $C [blocker of $D, pulled up]"* ]]
  [[ "$output" == *"3. $D: Title of $D"* ]]
}

@test "top: blocker status is case-insensitive; a blocker outside dev/TODO is ignored" {
  _task $A; _task $B "blocked by $A"; _task $C "Blocked by T20000101-999999"
  _queue $B $A $C
  _qop top $B; [ "$(_ids)" = "$A $B $C" ]
  _qop top $C; [ "$(_ids)" = "$C $A $B" ]
}

@test "top: a chain of exactly 10 hops is fine, 11 hops exits 4 and leaves the queue" {
  local i prev ids=()
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    id="$(printf 'T20000101-0001%02d' "$i")"; ids+=("$id")
  done
  for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
    if [ "$i" -lt 11 ]; then _task "${ids[$i]}" "Blocked by ${ids[$((i+1))]}"; else _task "${ids[$i]}"; fi
  done
  _queue "${ids[@]}"
  _qop top "${ids[1]}"          # 10 hops (ids[2]..ids[11])
  [ "$status" -eq 0 ]
  _queue "${ids[@]}"
  _qop top "${ids[0]}"          # 11 hops
  [ "$status" -eq 4 ]
  [ "$(_ids)" = "${ids[*]}" ]
}

@test "top: a blocker cycle exits 4 and changes nothing" {
  _task $A "Blocked by $B"; _task $B "Blocked by $A"; _task $C
  _queue $C $A $B
  _qop top $A
  [ "$status" -eq 4 ]
  [ "$(_ids)" = "$C $A $B" ]
}

@test "top: unknown id exits 1 and leaves the queue untouched, even mid-list" {
  _task $A; _task $B
  _queue $A $B
  _qop top $B T20000101-999999
  [ "$status" -eq 1 ]
  [ "$(_ids)" = "$A $B" ]
}

@test "top: unresolvable id runs the clone-locality diagnosis (closed in JOURNAL)" {
  _task $A; _queue $A
  : > "$R/dev/JOURNAL/2000-01-01-T20000101-999999-gone.md"
  _qop top T20000101-999999
  [ "$status" -eq 1 ]
  [[ "$output" == *"T20000101-999999"* ]]
}

@test "top: two files for one id is ambiguous (exit 1)" {
  _task $A; cp "$R/dev/TODO/$A-t.md" "$R/dev/TODO/$A-other.md"; _queue $A
  _qop top $A
  [ "$status" -eq 1 ]
}

@test "top --before: batch lands in given order immediately above the target" {
  for i in $A $B $C $D $E; do _task $i; done
  _queue $A $B $C $D
  _qop top $E $C --before $B
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $E $C $B $D" ]
  [[ "$output" == *"New order around $B:"* ]]
  [[ "$output" == *"4. $B: Title of $B"* ]]
}

@test "top --before: blocker chain is expanded ahead of the task, above the target" {
  _task $A; _task $B; _task $C "Blocked by $D"; _task $D; _task $E
  _queue $A $B $C $E
  _qop top $C --before $E
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $B $D $C $E" ]
  [[ "$output" == *"[blocker of $C, pulled up]"* ]]
}

@test "top --before: target must resolve and be queued (exit 1), and may not be in the chain (exit 4)" {
  _task $A; _task $B; _task $C "Blocked by $B"
  _queue $A $C
  _qop top $A --before $B; [ "$status" -eq 1 ]
  _qop top $A --before T20000101-999999; [ "$status" -eq 1 ]
  _queue $A $B $C
  _qop top $C --before $B; [ "$status" -eq 4 ]
  [ "$(_ids)" = "$A $B $C" ]
}

@test "bottom: first-listed wins the very last slot; adds an unqueued id" {
  for i in $A $B $C $D; do _task $i; done
  _queue $A $B $C
  _qop bottom $D $A
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$B $C $A $D" ]
  [[ "$output" == *"New queue order (tail):"* ]]
  [[ "$output" == *"CHANGED=1"* ]]
  _qop bottom $D; [[ "$output" == *"CHANGED=0"* ]]
}

@test "bottom: unknown id exits 1 and leaves the queue untouched" {
  _task $A; _task $B; _queue $A $B
  _qop bottom $A T20000101-999999
  [ "$status" -eq 1 ]
  [ "$(_ids)" = "$A $B" ]
}

@test "stage: appends a missing task; second run is a no-op exit 3" {
  _task $A; _task $B; _queue $A
  _qop stage $B
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $B" ]
  [[ "$output" == *"$B: appended at position 2 of 2"* ]]
  [[ "$output" == *"CHANGED=1"* ]]
  _qop stage $B
  [ "$status" -eq 3 ]
  [[ "$output" == *"$B: already at position 2 of 2 — no change"* ]]
  [[ "$output" == *"CHANGED=0"* ]]
  [ "$(_ids)" = "$A $B" ]
}

@test "stage: never moves an already-queued task" {
  for i in $A $B $C; do _task $i; done
  _task $A Open "blocks: $C"
  _queue $C $B
  _qop stage $B $A
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $C $B" ]
  [[ "$output" == *"$B: already at position 2"* ]]
}

@test "stage: inserts before the frontmost queued task it blocks (blocks: field)" {
  for i in $A $B $C $D; do _task $i; done
  _task $D Open "blocks: $C, $B"
  _queue $A $B $C
  _qop stage $D
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $D $B $C" ]
  [[ "$output" == *"$D: inserted at position 2 of 4, immediately before $B (it blocks $B)"* ]]
}

@test "stage: inserts before a queued task whose status says Blocked by it" {
  _task $A; _task $B "Blocked by $D - notes"; _task $C "Blocked by $A and $D"; _task $D
  _queue $A $C $B
  _qop stage $D
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $D $C $B" ]
}

@test "stage: blocks-detection ignores prose mentions and unqueued targets" {
  _task $A; _task $B Open "related: $A"; _task $C "Open"; _task $D Open "blocks: $C"
  printf 'Blocked by %s in prose\n' $D >> "$R/dev/TODO/$B-t.md"
  _queue $B
  _qop stage $D
  [ "$(_ids)" = "$B $D" ]
}

@test "stage: a batch is processed in order against the updated queue" {
  _task $A; _task $B Open "blocks: $A"; _task $C Open "blocks: $B"
  _queue $A
  _qop stage $B $C
  [ "$status" -eq 0 ]
  [ "$(_ids)" = "$C $B $A" ]
}

@test "stage: unknown id exits 1 and writes nothing (all-or-nothing)" {
  _task $A; _task $B; _queue $A
  _qop stage $B T20000101-999999
  [ "$status" -eq 1 ]
  [ "$(_ids)" = "$A" ]
}

@test "stage: creates queue.md with the header when it is missing" {
  _task $A; rm "$R/dev/TODO/queue.md"
  _qop stage $A
  [ "$status" -eq 0 ]
  grep -q '^# TODO Queue' "$R/dev/TODO/queue.md"
  [ "$(_ids)" = "$A" ]
}

@test "stage: title comes from the H1, falling back to the slug" {
  _task $A; printf -- '---\nstatus: Open\n---\n\nno heading\n' > "$R/dev/TODO/$B-my-slug.md"
  _queue
  _qop stage $A $B
  grep -qx -- "- \[$A\]($A-t.md): Title of $A" "$R/dev/TODO/queue.md"
  grep -qx -- "- \[$B\]($B-my-slug.md): my-slug" "$R/dev/TODO/queue.md"
}

@test "UNTRACKED lists only task files git does not track yet" {
  _task $A; _queue $A; _commit
  _task $B
  _qop stage $A $B
  [[ "$output" == *"UNTRACKED=dev/TODO/$B-t.md"* ]]
  [[ "$output" != *"UNTRACKED=dev/TODO/$A"* ]]
  _qop top $A
  [[ "$output" == *$'\nUNTRACKED=' ]]
}

@test "--dry-run prints the result but writes nothing" {
  _task $A; _task $B; _queue $A
  _qop stage $B --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"$B: appended at position 2 of 2"* ]]
  [[ "$output" == *"CHANGED=1"* ]]
  [ "$(_ids)" = "$A" ]
}

@test "lines other than queue entries are left alone" {
  _task $A; _task $B; _queue $A
  _qop top $B
  head -n 4 "$R/dev/TODO/queue.md" | grep -q '^Prose line.$'
}

@test "wrappers top.sh, bottom.sh and stage.sh bind the verb" {
  for i in $A $B $C; do _task $i; done
  _queue $A $B
  run bash "$REPO_ROOT/stage/scripts/stage.sh" $C --repo "$R"; [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $B $C" ]
  run bash "$REPO_ROOT/top/scripts/top.sh" $C --repo "$R"; [ "$status" -eq 0 ]
  [ "$(_ids)" = "$C $A $B" ]
  run bash "$REPO_ROOT/bottom/scripts/bottom.sh" $C --repo "$R"; [ "$status" -eq 0 ]
  [ "$(_ids)" = "$A $B $C" ]
}
