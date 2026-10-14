#!/usr/bin/env bats
# hooks/skill-ask.sh -- PreToolUse(Skill) hook returning permissionDecision "ask"
# for skills listed in hooks/ask-skills.txt (T20261012-352228).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_ROOT/hooks/skill-ask.sh"
}

run_hook() { printf '{"tool_name":"Skill","tool_input":{"skill":"%s"}}' "$1" | "$HOOK"; }

@test "listed skill (bare name) -> ask" {
  run run_hook autopilot
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = ask ]
}

@test "listed skill (plugin-qualified name) -> ask" {
  run run_hook ccxp-skills:autopilot
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = ask ]
}

@test "unlisted skill -> silent no-opinion" {
  run run_hook drive
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed/absent skill field -> silent" {
  run bash -c "echo '{}' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hooks.json registers the script on the Skill matcher" {
  run jq -r '.hooks.PreToolUse[0].matcher' "$REPO_ROOT/hooks/hooks.json"
  [ "$output" = Skill ]
  grep -q 'hooks/skill-ask.sh' "$REPO_ROOT/hooks/hooks.json"
}

@test "every ask-listed skill is model-visible (disable-model-invocation: false)" {
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    grep -q '^disable-model-invocation: false$' "$REPO_ROOT/$line/SKILL.md"
  done < "$REPO_ROOT/hooks/ask-skills.txt"
}
