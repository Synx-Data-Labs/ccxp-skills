#!/usr/bin/env bats
# Tests for _queue/queue.sh — shared queue.md editing used by stage/top/bottom/
# todo sweep/migrate-task.

setup() {
  Q="$BATS_TEST_DIRNAME/../_queue/queue.sh"
  F="$BATS_TEST_TMPDIR/queue.md"
  printf '# TODO Queue\n\nprose\n\n- [T1](T1-a.md): A\n- [T2](T2-b.md): B\n- [T3](T3-c.md): C\n' > "$F"
}

order() { sed -nE 's/^- \[(T[0-9]+)\].*/\1/p' "$F" | xargs; }

@test "has / pos report membership and 1-based entry position" {
  bash "$Q" has "$F" T2
  ! bash "$Q" has "$F" T9
  [ "$(bash "$Q" pos "$F" T3)" = 3 ]
  ! bash "$Q" pos "$F" T9
}

@test "has does not prefix-match a longer id" {
  ! bash "$Q" has "$F" T
}

@test "append adds at the end and is a no-op when already queued" {
  bash "$Q" append "$F" T4 T4-d.md "D"
  bash "$Q" append "$F" T1 T1-a.md "A"
  [ "$(order)" = "T1 T2 T3 T4" ]
  grep -qx -- '- \[T4\](T4-d.md): D' "$F"
}

@test "insert-before puts the task immediately above the target, moving if queued" {
  bash "$Q" insert-before "$F" T4 T4-d.md "D" T2
  [ "$(order)" = "T1 T4 T2 T3" ]
  bash "$Q" insert-before "$F" T3 T3-c.md "C" T1
  [ "$(order)" = "T3 T1 T4 T2" ]
}

@test "insert-before appends when the target is not queued" {
  bash "$Q" insert-before "$F" T4 T4-d.md "D" T99
  [ "$(order)" = "T1 T2 T3 T4" ]
}

@test "top moves/adds as first entry, below the header prose" {
  bash "$Q" top "$F" T3 T3-c.md "C"
  bash "$Q" top "$F" T5 T5-e.md "E"
  [ "$(order)" = "T5 T3 T1 T2" ]
  head -3 "$F" | grep -q "TODO Queue"
  grep -q '^prose$' "$F"
}

@test "bottom moves/adds as last entry" {
  bash "$Q" bottom "$F" T1 T1-a.md "A"
  [ "$(order)" = "T2 T3 T1" ]
}

@test "remove drops only that entry" {
  bash "$Q" remove "$F" T2
  [ "$(order)" = "T1 T3" ]
}

@test "creates the file with a header when missing" {
  rm "$F"
  bash "$Q" append "$F" T1 T1-a.md "A"
  grep -q "TODO Queue" "$F"
  [ "$(order)" = "T1" ]
}

@test "a literal backslash-n in a title stays on one line" {
  bash "$Q" append "$F" T4 T4-d.md 'a\nb'
  grep -qF -- '- [T4](T4-d.md): a\nb' "$F"
}

@test "top on an empty queue appends" {
  printf '# TODO Queue\n' > "$F"
  bash "$Q" top "$F" T1 T1-a.md "A"
  [ "$(order)" = "T1" ]
}

@test "unknown subcommand exits 2" {
  run bash "$Q" bogus
  [ "$status" -eq 2 ]
}

@test "insert-before with itself as target leaves the order unchanged" {
  bash "$Q" insert-before "$F" T2 T2-b.md "B" T2
  [ "$(order)" = "T1 T2 T3" ]
}

@test "edits preserve the queue file mode" {
  chmod 644 "$F"
  bash "$Q" top "$F" T3 T3-c.md "C"
  [ "$(stat -c %a "$F" 2>/dev/null || stat -f %Lp "$F")" = 644 ]
}
