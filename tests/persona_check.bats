#!/usr/bin/env bats
# Tests for hooks/persona-check.sh (SessionStart + UserPromptSubmit: automatic refresh of the installed ccxp-agent persona).
# The hook runs from a temp copy of the plugin tree and the profile is a temp dir -- the real ~/.claude* is never touched.

load test_helper

setup() {
  PLUG="$BATS_TEST_TMPDIR/plugin"
  P="$BATS_TEST_TMPDIR/profile"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$PLUG/hooks" "$PLUG/agent-pairing/assets" "$PLUG/agent-pairing/scripts" "$P/agents" "$WORK/dev"
  cp "$REPO_ROOT/hooks/persona-check.sh" "$PLUG/hooks/"
  cp "$REPO_ROOT/agent-pairing/scripts/agent-pairing.sh" "$PLUG/agent-pairing/scripts/"
  HOOK="$PLUG/hooks/persona-check.sh"
  echo "persona v2" > "$PLUG/agent-pairing/assets/ccxp-agent.md"
  echo "persona v1" > "$P/agents/ccxp-agent.md"
  echo '{"agent":"ccxp-agent","env":{"K":"v"}}' > "$P/settings.json"
  export CLAUDE_CONFIG_DIR="$P"
  unset CCXP_PERSONA_AUTO_REFRESH
}

run_hook() { run bash -c "printf '{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$WORK\"}' | bash '$HOOK'"; }
run_prompt() { run bash -c "printf '{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\",\"cwd\":\"$WORK\"}' | bash '$HOOK'"; }
baks() { ls "$P/agents" | grep -c '^ccxp-agent.md.bak-' || true; }

@test "differing persona: refreshed once with a .bak and one message, then silent" {
  run_hook; [ "$status" -eq 0 ]
  jq -e '.systemMessage | test("refreshed") and test("bak")' <<<"$output" >/dev/null
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$output" >/dev/null
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v2" ]
  [ "$(cat "$P/agents/ccxp-agent.md.bak-"*)" = "persona v1" ]
  [ "$(stat -c %a "$P/ccxp-persona-check.json" 2>/dev/null || stat -f %Lp "$P/ccxp-persona-check.json")" = 600 ]
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(baks)" = 1 ]
}

@test "message does not demand a restart" {
  run_hook
  jq -e '.systemMessage | test("usually") and (test("ends") | not)' <<<"$output" >/dev/null
}

@test "same hash is not refreshed again (hand edit after the refresh is kept)" {
  run_hook; [ -n "$output" ]
  echo "my hand edit" > "$P/agents/ccxp-agent.md"
  run_hook; [ -z "$output" ]
  run_prompt; [ -z "$output" ]
  [ "$(cat "$P/agents/ccxp-agent.md")" = "my hand edit" ]
  [ "$(baks)" = 1 ]
}

@test "changed bundled content refreshes again" {
  run_hook; [ -n "$output" ]
  echo "persona v3" > "$PLUG/agent-pairing/assets/ccxp-agent.md"
  run_hook; [ -n "$output" ]
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v3" ]
  [ "$(baks)" = 2 ]
}

@test "UserPromptSubmit refreshes a mid-session stale persona once, with UserPromptSubmit output" {
  run_prompt; [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.systemMessage | test("refreshed"))' <<<"$output" >/dev/null
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v2" ]
  run_prompt; [ -z "$output" ]
  run_hook; [ -z "$output" ]
  [ "$(baks)" = 1 ]
}

@test "identical content is silent and writes no state" {
  cp "$PLUG/agent-pairing/assets/ccxp-agent.md" "$P/agents/ccxp-agent.md"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  run_prompt; [ -z "$output" ]
  [ ! -e "$P/ccxp-persona-check.json" ]
}

@test "missing persona file is silent" {
  rm "$P/agents/ccxp-agent.md"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -e "$P/agents/ccxp-agent.md" ]
}

@test "profile not using ccxp-agent is silent and untouched" {
  echo '{"env":{}}' > "$P/settings.json"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  echo '{"agent":"other"}' > "$P/settings.json"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v1" ]
}

@test "off switch via env" {
  CCXP_PERSONA_AUTO_REFRESH=0 run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v1" ]
  [ "$(baks)" = 0 ]
}

@test "off switch via state file" {
  echo '{"autoRefresh":false}' > "$P/ccxp-persona-check.json"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  run_prompt; [ -z "$output" ]
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v1" ]
}

@test "autopilot busy state no longer blocks the refresh" {
  printf '{"status":"on","busy_since":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/dev/.autopilot-state.json"
  run_hook
  [ "$(cat "$P/agents/ccxp-agent.md")" = "persona v2" ]
}

@test "failed refresh gives a manual-fallback notice once, no retry loop" {
  rm "$PLUG/agent-pairing/scripts/agent-pairing.sh"
  run_hook; [ "$status" -eq 0 ]
  jq -e '.systemMessage | test("failed") and test("/agent-pairing update")' <<<"$output" >/dev/null
  run_prompt; [ -z "$output" ]
}

@test "hooks.json registers persona-check.sh on SessionStart(startup) and UserPromptSubmit" {
  jq -e '[.hooks.SessionStart[] | select(.matcher == "startup") | .hooks[].command | select(contains("persona-check.sh"))] | length == 1' "$REPO_ROOT/hooks/hooks.json" >/dev/null
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command | select(contains("persona-check.sh"))] | length == 1' "$REPO_ROOT/hooks/hooks.json" >/dev/null
  [ -x "$REPO_ROOT/hooks/persona-check.sh" ]
}
