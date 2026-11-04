#!/usr/bin/env bats
# secrets-check/scripts/secrets-check.sh -- pre-PR secret-handling check.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SC="$REPO_ROOT/secrets-check/scripts/secrets-check.sh"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX"
  git -C "$FX" init -q -b main
  git -C "$FX" config user.email t@example.com
  git -C "$FX" config user.name t
  echo base >"$FX/a.txt"
  git -C "$FX" add -A && git -C "$FX" commit -q -m base
  git -C "$FX" checkout -q -b feature
  FAKE="gh""p_Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56"
}

@test "fallback: clean diff passes" {
  echo "hello" >"$FX/b.txt"; git -C "$FX" add -A; git -C "$FX" commit -q -m c
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 0 ]
  [[ "$output" == *clean* ]]
}

@test "fallback: seeded fake token fails and the value is never printed" {
  echo "curl -H 'Authorization: token $FAKE' x" >"$FX/b.sh"; git -C "$FX" add -A; git -C "$FX" commit -q -m c
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 1 ]
  [[ "$output" == *"token-literal"* ]]
  [[ "$output" != *"$FAKE"* ]]
  [[ "$output" != *"Ab12Cd34"* ]]
}

@test "uses the repo lint when scripts/lint-secret-handling.sh exists" {
  mkdir -p "$FX/scripts"
  printf '#!/usr/bin/env bash\necho "repo-lint ran: $*"\nexit 0\n' >"$FX/scripts/lint-secret-handling.sh"
  git -C "$FX" add -A; git -C "$FX" commit -q -m lint
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo-lint ran: --diff main"* ]]
}

@test "the repo lint's failing exit code is propagated" {
  mkdir -p "$FX/scripts"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FX/scripts/lint-secret-handling.sh"
  git -C "$FX" add -A; git -C "$FX" commit -q -m lint
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 1 ]
}

@test "usage: unresolvable base and non-git dir exit 2" {
  cd "$FX"
  run bash "$SC" nope-ref
  [ "$status" -eq 2 ]
  cd "$BATS_TEST_TMPDIR"
  run bash "$SC" main
  [ "$status" -eq 2 ]
}

@test "fallback: an uncommitted and an untracked fake token are both caught" {
  echo "x" >"$FX/tracked.txt"; git -C "$FX" add -A; git -C "$FX" commit -q -m c
  echo "token $FAKE" >>"$FX/tracked.txt"
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 1 ]
  [[ "$output" != *"$FAKE"* ]]
  git -C "$FX" checkout -q -- tracked.txt
  echo "token $FAKE" >"$FX/new-untracked.txt"
  run bash "$SC" main
  [ "$status" -eq 1 ]
}

@test "repo lint mode warns that uncommitted changes are not covered" {
  mkdir -p "$FX/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FX/scripts/lint-secret-handling.sh"
  git -C "$FX" add -A; git -C "$FX" commit -q -m lint
  echo dirty >"$FX/dirty.txt"
  cd "$FX"
  run bash "$SC" main
  [ "$status" -eq 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}
