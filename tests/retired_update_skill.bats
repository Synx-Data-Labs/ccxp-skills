#!/usr/bin/env bats
# Guard: the /ccxp-skills:update skill, its scripts, its auto-update hook and the
# `/agent-pairing update` subcommand were retired (the persona refreshes automatically via
# hooks/persona-check.sh). No doc or script may point users at them again.
# Migration notes may name them on a line that also says "removed" or "retired".

setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; cd "$REPO_ROOT"; }

@test "the update skill, its scripts and the auto-update hook are gone" {
  [ ! -e update ]
  [ ! -e hooks/update-check.sh ]
  run jq -r '[.. | strings] | map(select(contains("update-check"))) | length' hooks/hooks.json
  [ "$output" = 0 ]
  run grep -vE '^(#|$)' hooks/ask-skills.txt
  ! grep -qx update <<<"$output"
}

@test "no doc or script references the retired names (outside dev/ and removal notes)" {
  local pat='ccxp-skills:update|update/scripts|update-check|/agent-pairing update|(^|[^A-Za-z0-9_./-])/update( |$|`)'
  run bash -c 'git ls-files -z -- . ":!dev" ":!tests/retired_update_skill.bats" | xargs -0 grep -nIE "$1" 2>/dev/null | grep -vE "removed|retired" || true' _ "$pat"
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "agent-pairing keeps the internal update engine for the persona hook" {
  grep -q 'agent-pairing.sh" update' hooks/persona-check.sh
  echo '{}' >"$BATS_TEST_TMPDIR/settings.json"
  run bash agent-pairing/scripts/agent-pairing.sh update --dry-run --claude-dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}
