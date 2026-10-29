#!/usr/bin/env bats
# Tests for agent-pairing/scripts/trash.sh (send to ~/.Trash instead of rm).

load test_helper
TRASH="$REPO_ROOT/agent-pairing/scripts/trash.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CCXP_TRASH_BIN=""   # default: exercise the mv fallback; the fake-binary tests set it
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work" || return 1
  WORK="$(pwd -P)"
  PHOME="$(cd -P "$HOME" && pwd -P)"
}

batch_of() { sed -n 's/^TRASH //p' <<<"$output"; }

# A stand-in for /usr/bin/trash: moves the file into $HOME/.Trash and prints the -v line.
fake_trash() {
  cat > "$BATS_TEST_TMPDIR/faketrash" <<'EOT'
#!/usr/bin/env bash
[ "$1" = "-v" ] && [ "$2" = "-s" ] && [ "$3" = "--" ] || exit 64
[ -z "${FAKE_TRASH_FAIL:-}" ] || exit 1
mkdir -p "$HOME/.Trash"
mv "$4" "$HOME/.Trash/$(basename "$4")" && echo "# Moved \"$4\" to \"$HOME/.Trash/$(basename "$4")\""
EOT
  chmod +x "$BATS_TEST_TMPDIR/faketrash"
  export CCXP_TRASH_BIN="$BATS_TEST_TMPDIR/faketrash"
}

@test "fallback: moves a file under ~/.Trash/<stamp>-<label>/files/<abs path> and writes the manifest" {
  echo hi > a.txt
  run bash "$TRASH" --label demo a.txt
  [ "$status" -eq 0 ]
  [ ! -e a.txt ]
  b="$(batch_of)"
  [[ "$b" == "$PHOME/.Trash/"[0-9]*-demo ]]
  [ "$(cat "$b/files$WORK/a.txt")" = "hi" ]
  [ "$(cat "$b/MANIFEST.tsv")" = "$(printf '%s\t%s\tmv' "$WORK/a.txt" "$b/files$WORK/a.txt")" ]
}

@test "moves several paths, directories included; relative and absolute both work" {
  mkdir -p d/sub; echo 1 > d/sub/f; echo 2 > g
  run bash "$TRASH" d "$WORK/g"
  [ "$status" -eq 0 ]
  b="$(batch_of)"
  [ -f "$b/files$WORK/d/sub/f" ]
  [ -f "$b/files$WORK/g" ]
  [ ! -e d ] && [ ! -e g ]
  [ "$(wc -l < "$b/MANIFEST.tsv" | tr -d ' ')" = "2" ]
}

@test "dry-run moves nothing and creates no trash dir" {
  echo x > a
  run bash "$TRASH" --dry-run a
  [ "$status" -eq 0 ]
  [ -f a ]
  [ ! -e "$HOME/.Trash" ]
  [[ "$output" == *"would move: $WORK/a"* ]]
  [[ "$output" == *"TRASH (dry-run)"* ]]
}

@test "two runs in the same second never collide or overwrite" {
  echo 1 > a; run bash "$TRASH" --label x a; b1="$(batch_of)"
  echo 2 > a; run bash "$TRASH" --label x a; b2="$(batch_of)"
  [ "$b1" != "$b2" ]
  [ "$(cat "$b1/files$WORK/a")" = "1" ]
  [ "$(cat "$b2/files$WORK/a")" = "2" ]
}

@test "a symlink is moved as a link, its target is untouched" {
  echo t > target; ln -s target link
  run bash "$TRASH" link
  [ "$status" -eq 0 ]
  b="$(batch_of)"
  [ -L "$b/files$WORK/link" ]
  [ -f target ]
  [ ! -L link ]
}

@test "a missing path fails with exit 2 and moves nothing" {
  echo x > a
  run bash "$TRASH" a nope
  [ "$status" -eq 2 ]
  [ -f a ]
  [ ! -e "$HOME/.Trash" ]
}

@test "refuses /, HOME, a parent of HOME, the trash dir and items inside it" {
  mkdir -p "$HOME/.Trash/old"
  for p in / // "$HOME" "$(dirname "$HOME")" "$HOME/.Trash" "$HOME/.Trash/old" "$HOME/.trash/old"; do
    run bash "$TRASH" "$p"
    [ "$status" -eq 2 ]
  done
  [ -d "$HOME/.Trash/old" ]
}

@test "a path covered by another given path is skipped, not failed" {
  mkdir d; echo 1 > d/f
  run bash "$TRASH" d d/f d
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip (already covered)"* ]]
  [ ! -e d ]
}

@test "usage errors: no paths, unknown option, newline in path" {
  run bash "$TRASH"; [ "$status" -eq 2 ]
  run bash "$TRASH" --bogus a; [ "$status" -eq 2 ]
  run bash "$TRASH" -- $'a\nb'; [ "$status" -eq 2 ]
}

@test "label is sanitized; leading-dash names work after --" {
  echo x > ./-weird
  run bash "$TRASH" --label 'a b/../c' -- ./-weird
  [ "$status" -eq 0 ]
  [[ "$(batch_of)" == *-a-b-..-c ]]
}

@test "primary mover: item lands in ~/.Trash, manifest records the tool's destination" {
  fake_trash
  echo hi > a.txt
  run bash "$TRASH" a.txt
  [ "$status" -eq 0 ]
  [ ! -e a.txt ]
  [ "$(cat "$HOME/.Trash/a.txt")" = "hi" ]
  b="$(batch_of)"
  [ "$(cat "$b/MANIFEST.tsv")" = "$(printf '%s\t%s\ttrash' "$WORK/a.txt" "$HOME/.Trash/a.txt")" ]
}

@test "primary mover failing falls back to mv for that item" {
  fake_trash
  export FAKE_TRASH_FAIL=1
  echo hi > a.txt
  run bash "$TRASH" a.txt
  [ "$status" -eq 0 ]
  b="$(batch_of)"
  [ -f "$b/files$WORK/a.txt" ]
  [[ "$(cat "$b/MANIFEST.tsv")" == *$'\tmv' ]]
}

@test "dry-run with the primary mover touches nothing" {
  fake_trash
  echo hi > a.txt
  run bash "$TRASH" --dry-run a.txt
  [ "$status" -eq 0 ]
  [ -f a.txt ]
  [ ! -e "$HOME/.Trash" ]
}
