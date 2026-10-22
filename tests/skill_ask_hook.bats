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

@test "every skill listed in ask-skills.txt gets an ask (bare and qualified)" {
  local n=0 s
  while IFS= read -r s; do
    s="${s%%#*}"; s="${s//[[:space:]]/}"
    [ -n "$s" ] || continue
    n=$((n+1))
    run run_hook "$s"
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = ask ]
    run run_hook "ccxp-skills:$s"
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = ask ]
  done <"$REPO_ROOT/hooks/ask-skills.txt"
  [ "$n" -ge 7 ]
}

@test "every skill listed in ask-skills.txt exists as a skill directory" {
  local s
  while IFS= read -r s; do
    s="${s%%#*}"; s="${s//[[:space:]]/}"
    [ -n "$s" ] || continue
    [ -f "$REPO_ROOT/$s/SKILL.md" ] || { echo "missing skill: $s"; return 1; }
  done <"$REPO_ROOT/hooks/ask-skills.txt"
}

@test "hooks.json: every command quotes \${CLAUDE_PLUGIN_ROOT} (survives a space in the path)" {
  # Unquoted placeholder word-splits on a space in the install path.
  run jq -r '[.. | objects | select(has("command")) | .command] | .[]' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r cmd; do
    # Every occurrence must sit inside double quotes: strip quoted spans, none may remain.
    stripped="$(sed -E 's/"[^"]*"//g' <<<"$cmd")"
    [[ "$stripped" != *'${CLAUDE_PLUGIN_ROOT}'* ]] || { echo "unquoted: $cmd"; false; }
    [[ "$cmd" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  done <<<"$output"
}

@test "hooks.json: the quoted command runs the hook from a root with a space" {
  d="$BATS_TEST_TMPDIR/plug in"; mkdir -p "$d/hooks"
  cp "$HOOK" "$REPO_ROOT/hooks/ask-skills.txt" "$d/hooks/"
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json")"
  run env CLAUDE_PLUGIN_ROOT="$d" sh -c "printf '%s' '{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"autopilot\"}}' | $cmd"
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = ask ]
}
