#!/usr/bin/env bats
# Tests for `gcpr-prep.sh sensitivity-check` and its engine
# gcpr/scripts/sensitivity_check.py, plus the alias-before-writing step in the
# intake skills. Offline: fixture git repos under $BATS_TEST_TMPDIR. The names
# below are synthetic; the output must never contain them.

load test_helper
PREP="$REPO_ROOT/gcpr/scripts/gcpr-prep.sh"
TERM1="Zorblax"

setup() {
  R="$(make_fixture_repo "$BATS_TEST_TMPDIR/repo")"
  cd "$R"
  unset SENSITIVE_NAMES_DENYLIST SENSITIVE_NAMES_DENYLIST_FILE
  DL="$BATS_TEST_TMPDIR/denylist"
  printf '# private list\n%s\nQuux Partners\n\n' "$TERM1" > "$DL"
}

_sens() { run bash "$PREP" sensitivity-check "$@"; }
_commit() { git add -A && git commit -q -m "$1"; }

@test "sensitivity-check: no deny-list configured -> warns, SKIPPED, exit 0" {
  echo "talk to $TERM1 tomorrow" > a.md
  _sens
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENSITIVITY=skipped"* ]]
  [[ "$output" == *"WARNING no deny-list configured"* ]]
}

@test "sensitivity-check: unreadable deny-list file and no inline list -> fail-soft" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$BATS_TEST_TMPDIR/missing"
  _sens
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENSITIVITY=skipped"* ]]
}

@test "sensitivity-check: file list hits added lines (tracked and untracked), prints file:line and count only" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  printf 'base\n' > t.md; _commit t
  printf 'base\nmet with %s today\n' "$TERM1" > t.md
  printf 'x\ny\nquux partners agreed\n' > new.txt
  _sens
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIT t.md:2"* ]]
  [[ "$output" == *"HIT new.txt:3"* ]]
  [[ "$output" == *"SENSITIVITY=blocked count=2"* ]]
  [[ "$output" != *"$TERM1"* ]]
  [[ "$output" != *"Quux"* ]]
  [[ "$output" != *"quux"* ]]
}

@test "sensitivity-check: inline list works when no file is set" {
  export SENSITIVE_NAMES_DENYLIST="$(printf 'Foo Corp\n%s\n' "$TERM1")"
  echo "see foo corp deal" > a.md
  _sens
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIT a.md:1"* ]]
}

@test "sensitivity-check: whole-word and case-insensitive" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  printf '%sx and x%s and %ss\n' "$TERM1" "$TERM1" "$TERM1" > a.md
  _sens
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENSITIVITY=clean"* ]]
  printf '(zorblax), ZORBLAX.\n' > b.md
  _sens
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIT b.md:1"* ]]
}

@test "sensitivity-check: pre-existing and removed lines are not flagged" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  printf 'old %s\nkeep\n' "$TERM1" > a.md; _commit old
  printf 'keep\nnew line\n' > a.md
  _sens
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENSITIVITY=clean"* ]]
}

@test "sensitivity-check: --base scans commits, add-then-remove and messages" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  git checkout -q -b feat
  printf 'one\n%s\n' "$TERM1" > a.md; _commit "add a"
  printf 'one\n' > a.md; _commit "drop the name from a"
  echo ok > b.md; _commit "notes from $TERM1 call"
  _sens --base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIT a.md:2 ("* ]]
  [[ "$output" == *"message:1"* ]]
  [[ "$output" != *"$TERM1"* ]]
}

@test "sensitivity-check: --message-file scans drafted text" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  printf 'title\n\nbody about %s\n' "$TERM1" > "$BATS_TEST_TMPDIR/msg"
  _sens --message-file "$BATS_TEST_TMPDIR/msg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HIT message-file:3"* ]]
  [[ "$output" != *"$TERM1"* ]]
}

@test "sensitivity-check: unknown base is a could-not-run (2), not clean" {
  export SENSITIVE_NAMES_DENYLIST_FILE="$DL"
  _sens --base nope
  [ "$status" -eq 2 ]
}

@test "gcpr/SKILL.md runs sensitivity-check beside secrets-check" {
  grep -q 'gcpr-prep.sh sensitivity-check' "$REPO_ROOT/gcpr/SKILL.md"
  grep -q 'SENSITIVE_NAMES_DENYLIST_FILE' "$REPO_ROOT/gcpr/SKILL.md"
}

@test "intake skills tell the agent to alias names before writing" {
  for s in new-task to-task incept; do
    grep -q 'never paste raw email' "$REPO_ROOT/$s/SKILL.md"
    grep -q 'customer A' "$REPO_ROOT/$s/SKILL.md"
  done
}
