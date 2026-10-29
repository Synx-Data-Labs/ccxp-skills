#!/usr/bin/env bats
# hooks/terms-hook.sh -- UserPromptSubmit hook that surfaces the owner's terms (read-only).

load test_helper
HOOK="$REPO_ROOT/hooks/terms-hook.sh"
TERMS="$REPO_ROOT/agent-pairing/scripts/terms.sh"

setup() {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export CCXP_TERMS_FILE="$CLAUDE_CONFIG_DIR/terms.json"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cd "$BATS_TEST_TMPDIR"
}

# prompt text -> hook stdout
run_hook() { jq -cn --arg p "$1" --arg c "$BATS_TEST_TMPDIR" '{prompt: $p, cwd: $c}' | "$HOOK"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }

@test "no terms file and no ccxp-agent default: silent for ordinary and defining prompts" {
  run run_hook "fix the build"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run run_hook "RCA = root cause analysis"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "a known term is expanded in the injected context" {
  bash "$TERMS" add RCA "root cause analysis" >/dev/null
  run run_hook "please start the RCA on job 4"
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = "UserPromptSubmit" ]
  ctx | grep -qF -- '- RCA = root cause analysis'
  ctx | grep -q 'expand these terms'
}

@test "a prompt without known terms or definitions stays silent" {
  bash "$TERMS" add RCA "root cause analysis" >/dev/null
  run run_hook "just a plain sentence with PDF and USA"
  [ -z "$output" ]
}

@test "an explicit definition yields a capture hint with the add and undo commands" {
  bash "$TERMS" add CC "Claude Code" >/dev/null
  run run_hook "from now on RCA means root cause analysis"
  ctx | grep -q 'stated by the owner: RCA = root cause analysis'
  ctx | grep -q "terms.sh' add 'RCA' 'root cause analysis'"
  ctx | grep -q 'noted: RCA = root cause analysis'
  ctx | grep -q "terms.sh' remove 'RCA'"
  # the hook itself never writes
  [ "$(jq -c '.terms | keys' "$CCXP_TERMS_FILE")" = '["CC"]' ]
}

@test "an inferred definition says ask first and gives the add command for after a yes" {
  bash "$TERMS" add CC "Claude Code" >/dev/null
  run run_hook "ENV = production"
  ctx | grep -q 'unsure: ask the owner "remember ENV = production?"'
  ctx | grep -q -- '--origin asked'
}

@test "ccxp-agent as the profile default enables capture hints before any terms.json exists" {
  echo '{"agent":"ccxp-agent"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  run run_hook "RCA (root cause analysis) is our word for it"
  ctx | grep -q 'stated by the owner: RCA'
  [ ! -e "$CCXP_TERMS_FILE" ]
}

@test "an ambiguous term asks one short question and names the choose command" {
  bash "$TERMS" add WTF "what the f**k" >/dev/null
  bash "$TERMS" add WTF "want to find" >/dev/null
  run run_hook "WTF is this"
  ctx | grep -q 'WTF is ambiguous: "what the f\*\*k" | "want to find"'
  ctx | grep -q 'Ask the owner one short question'
  ctx | grep -q "terms.sh' choose 'WTF'"
}

@test "the cwd's repo glossary and repo-scoped terms are honoured" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.claude/rules"
  git init -q "$BATS_TEST_TMPDIR/proj"
  printf -- '- LTV = loan to value\n' > "$BATS_TEST_TMPDIR/proj/.claude/rules/glossary.md"
  bash "$TERMS" add LTV "lifetime value" >/dev/null
  run bash -c "jq -cn --arg p 'what is LTV' --arg c '$BATS_TEST_TMPDIR/proj' '{prompt:\$p,cwd:\$c}' | '$HOOK'"
  ctx | grep -qF -- '- LTV = loan to value'
  run run_hook "what is LTV"
  ctx | grep -qF -- '- LTV = lifetime value'
}

@test "malformed input, empty prompt and a corrupt terms file never fail the prompt" {
  run bash -c "echo 'not json' | '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c "echo '{}' | '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  echo '{{broken' > "$CCXP_TERMS_FILE"
  run run_hook "RCA means root cause analysis"
  [ "$status" -eq 0 ]
  ctx | grep -q 'stated by the owner'
}

@test "hooks.json registers the UserPromptSubmit hook with a timeout and an existing script" {
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json")" = '"${CLAUDE_PLUGIN_ROOT}/hooks/terms-hook.sh"' ]
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$REPO_ROOT/hooks/hooks.json")" = "5" ]
  [ -x "$HOOK" ]
  # the existing PreToolUse hook is untouched
  [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$REPO_ROOT/hooks/hooks.json")" = "Skill" ]
}

@test "only the head of a long prompt is scanned" {
  bash "$TERMS" add RCA "root cause analysis" >/dev/null
  filler=$(head -c 9000 /dev/zero | tr '\0' 'x')
  run run_hook "RCA $filler"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"RCA = root cause analysis"* ]]
  run run_hook "$filler RCA"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
