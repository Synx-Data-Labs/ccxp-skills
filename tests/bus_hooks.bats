#!/usr/bin/env bats
# hooks/hooks.json bus entries (T20261123-596451): shape, timeouts, and the inert / silent-failure contract.

load test_helper

HOOKS="$REPO_ROOT/hooks/hooks.json"

setup() {
  umask 077
  export CCXP_BUS_ROOT="$BATS_TEST_TMPDIR/bus" HOME="$BATS_TEST_TMPDIR/h" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  P="$BATS_TEST_TMPDIR/profiles"; mkdir -p "$HOME" "$P/plain" "$P/work" "$P/home"
  unset CCXP_BUS_NAME CCXP_BUS_SESSION BUS_TEST_CRASH
  export CCXP_BUS_SESSION_PID="$$"
}

# the command string of the bus hook for <event> whose command ends with <verb>
hook_cmd() { jq -r --arg e "$1" --arg v "$2" '[.hooks[$e][].hooks[] | select(.command | contains("_bus/bus.sh")) | select(.command | endswith($v))][0].command' "$HOOKS"; }
# run a hook command string as the harness would, in profile <p>, with <stdin>
run_hook() { local p="$1" in="$2" cmd="$3"; run bash -c "printf '%s' '$in' | CLAUDE_CONFIG_DIR='$P/$p' sh -c '$cmd'"; }

@test "hooks.json is valid JSON and still lists the earlier hooks first" {
  jq -e . "$HOOKS" >/dev/null
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$HOOKS")" = '"${CLAUDE_PLUGIN_ROOT}/hooks/terms-hook.sh"' ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS")" = '"${CLAUDE_PLUGIN_ROOT}/hooks/persona-check.sh"' ]
}

@test "SessionStart registers and delivers with a 5 s timeout, then starts an async watcher" {
  [ "$(jq -r '.hooks.SessionStart[1].matcher' "$HOOKS")" = 'startup|resume' ]
  [ "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$HOOKS")" = '"${CLAUDE_PLUGIN_ROOT}/_bus/bus.sh" deliver --register' ]
  [ "$(jq -r '.hooks.SessionStart[1].hooks[0].timeout' "$HOOKS")" = 5 ]
  [ "$(jq -r '.hooks.SessionStart[1].hooks[1] | [.command, .async, .asyncRewake, .timeout] | join("|")' "$HOOKS")" \
     = '"${CLAUDE_PLUGIN_ROOT}/_bus/bus.sh" watch|true|true|28800' ]
}

@test "UserPromptSubmit delivers with a 5 s timeout and Stop re-arms an async watcher" {
  [ "$(hook_cmd UserPromptSubmit deliver)" = '"${CLAUDE_PLUGIN_ROOT}/_bus/bus.sh" deliver' ]
  [ "$(jq -r '.hooks.UserPromptSubmit[1].hooks[0].timeout' "$HOOKS")" = 5 ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0] | [.command, .async, .asyncRewake, .timeout] | join("|")' "$HOOKS")" \
     = '"${CLAUDE_PLUGIN_ROOT}/_bus/bus.sh" watch|true|true|28800' ]
}

@test "the watcher gives up before the hook timeout" {
  [ "$(grep -o 'BUS_WATCH_SECS:-[0-9]*' "$REPO_ROOT/_bus/bus.sh")" = 'BUS_WATCH_SECS:-28740' ]
}

@test "every bus hook command points at an executable script" {
  [ -x "$REPO_ROOT/_bus/bus.sh" ]
  [ "$(jq -r '[.. | objects | select(.command? | strings | contains("_bus/bus.sh"))] | length' "$HOOKS")" = 4 ]
}

@test "inert: with no bus config every bus hook is silent and exits 0" {
  for ev in 'SessionStart deliver --register' 'SessionStart watch' 'UserPromptSubmit deliver' 'Stop watch'; do
    set -- $ev
    cmd="$(jq -r --arg e "$1" --arg v "$2" '[.hooks[$e][].hooks[] | select(.command | contains("_bus/bus.sh"))][] | select(.command | contains($v)) | .command' "$HOOKS" | head -n 1)"
    run_hook plain '{"hook_event_name":"'"$1"'","session_id":"s"}' "$cmd"
    [ "$status" -eq 0 ]; [ -z "$output" ]
  done
  [ ! -e "$CCXP_BUS_ROOT" ]
}

@test "a configured profile delivers through the hook command with the right event name" {
  CLAUDE_CONFIG_DIR="$P/home" bash "$REPO_ROOT/_bus/bus.sh" init --name home >/dev/null
  CLAUDE_CONFIG_DIR="$P/work" bash "$REPO_ROOT/_bus/bus.sh" init --name work >/dev/null
  run_hook work '{"hook_event_name":"SessionStart","session_id":"s"}' "$(hook_cmd SessionStart '--register')"
  [ "$status" -eq 0 ]
  CLAUDE_CONFIG_DIR="$P/home" bash "$REPO_ROOT/_bus/bus.sh" send --to work "hello" >/dev/null
  run_hook work '{"hook_event_name":"UserPromptSubmit","session_id":"s"}' "$(hook_cmd UserPromptSubmit deliver)"
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = UserPromptSubmit ]
  [ "$(jq -r .systemMessage <<<"$output")" = "ccxp bus: 1 note from home" ]
}

@test "any failure is a silent exit 0: unusable root, broken registry, no jq" {
  CLAUDE_CONFIG_DIR="$P/work" bash "$REPO_ROOT/_bus/bus.sh" init --name work >/dev/null
  cmd="$(hook_cmd UserPromptSubmit deliver)"
  printf 'not a directory' > "$CCXP_BUS_ROOT.file"
  CCXP_BUS_ROOT="$CCXP_BUS_ROOT.file" run_hook work '{"hook_event_name":"UserPromptSubmit"}' "$cmd"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  printf '{garbage' > "$CCXP_BUS_ROOT/agents.json"; chmod 600 "$CCXP_BUS_ROOT/agents.json"
  run_hook work '{"hook_event_name":"UserPromptSubmit"}' "$cmd"
  [ "$status" -eq 0 ]
  nojq="$BATS_TEST_TMPDIR/nojq"; mkdir -p "$nojq"
  for t in bash sh cat dirname basename tr sed od ps stat tail head wc date mkdir chmod mv rm kill id cut sleep mktemp grep df mount; do
    p="$(command -v $t)" && ln -sf "$p" "$nojq/$t"
  done
  run env PATH="$nojq" CLAUDE_CONFIG_DIR="$P/work" bash "$REPO_ROOT/_bus/bus.sh" deliver </dev/null
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
