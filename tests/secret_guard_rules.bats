#!/usr/bin/env bats
# Drift guard: the rule ids hooks/secret-guard.py mirrors must exist in the hub
# repo's scripts/lint-secret-handling.sh header (vendored in
# tests/fixtures/lint-secret-handling.header, refreshed by hand when the hub
# script's rule ids change).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every rule id the hook mirrors exists in the lint header" {
  ids=$(python3 -I -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"RULE_IDS = \(([^)]*)\)", src)
print(" ".join(re.findall(r"\"([a-z-]+)\"", m.group(1))))
' "$REPO_ROOT/hooks/secret-guard.py")
  [ -n "$ids" ]
  for id in $ids; do
    run grep -E "^#[[:space:]]+${id}( |$)" "$REPO_ROOT/tests/fixtures/lint-secret-handling.header"
    [ "$status" -eq 0 ] || { echo "rule id missing from lint header: $id"; return 1; }
  done
}

@test "hook docstring lists exactly the RULE_IDS" {
  for id in token-literal cmdline-secret echo-secret env-dump set-x-secret; do
    run grep -c "^  $id " "$REPO_ROOT/hooks/secret-guard.py"
    [ "$output" = 1 ] || { echo "docstring entry missing: $id"; return 1; }
  done
}
