#!/usr/bin/env bats
# hooks/terms-hook.sh -- UserPromptSubmit hook that surfaces the owner's terms (read-only).

load test_helper
HOOK="$REPO_ROOT/hooks/terms-hook.sh"
TERMS="$REPO_ROOT/agent-pairing/scripts/terms.sh"

setup() {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/profile"
  export CCXP_WTF_FILE="$CLAUDE_CONFIG_DIR/wtf.json"
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
  ctx | grep -qF -- '- rca = root cause analysis'
  ctx | grep -q 'expand these terms'
  ctx | grep -q 'Several meanings for one term are normal'
}

@test "a prompt without known terms or definitions stays silent" {
  bash "$TERMS" add RCA "root cause analysis" >/dev/null
  run run_hook "just a plain sentence with PDF and USA"
  [ -z "$output" ]
}

@test "an explicit definition yields a capture hint with the add and undo commands" {
  bash "$TERMS" add CC "Claude Code" >/dev/null
  run run_hook "from now on RCA means root cause analysis"
  ctx | grep -q 'stated by the owner: rca = root cause analysis'
  ctx | grep -q "terms.sh' add 'rca' 'root cause analysis'"
  ctx | grep -q 'noted: rca = root cause analysis'
  ctx | grep -q "terms.sh' remove 'rca'"
  # the hook itself never writes
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE")" = '["cc"]' ]
}

@test "an inferred definition says ask first and gives the add command for after a yes" {
  bash "$TERMS" add CC "Claude Code" >/dev/null
  run run_hook "ENV = production"
  ctx | grep -q 'unsure: ask the owner "remember env = production?"'
  ctx | grep -q -- '--origin asked'
}

@test "ccxp-agent as the profile default enables capture hints before any wtf.json exists" {
  echo '{"agent":"ccxp-agent"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  run run_hook "RCA (root cause analysis) is our word for it"
  ctx | grep -q 'stated by the owner: rca'
  [ ! -e "$CCXP_WTF_FILE" ]
}

@test "several meanings are listed together, no question is asked" {
  bash "$TERMS" add CC "Claude Code" >/dev/null
  bash "$TERMS" add CC "concurrency control" >/dev/null
  run run_hook "what is cc here"
  ctx | grep -qF -- '- cc = Claude Code / concurrency control'
  ! ctx | grep -qi 'ambiguous'
  ! ctx | grep -q 'Ask the owner one short question'
  ! ctx | grep -q "terms.sh' choose"
  ctx | grep -q 'Several meanings for one term are normal'
}

@test "a context-matched meaning leads and is named when the term has several" {
  bash "$TERMS" add CC "Claude Code" --default >/dev/null
  bash "$TERMS" add CC "carbon copy" --context email >/dev/null
  run run_hook "draft the email and CC bob"
  ctx | grep -qF -- '- cc = carbon copy / Claude Code (here: carbon copy)'
  run run_hook "just CC it"
  ctx | grep -qF -- '- cc = Claude Code / carbon copy'
  ! ctx | grep -qF '(here:'
}

@test "terms match case-insensitively and are shown lowercase" {
  bash "$TERMS" add qbo "quickbooks online" >/dev/null
  run run_hook "export from Qbo and QBO"
  [ "$(ctx | grep -cF -- '- qbo = quickbooks online')" = "1" ]
}

@test "a legacy terms.json (not yet migrated) enables capture hints" {
  printf '{"version":1,"terms":{}}\n' > "$CLAUDE_CONFIG_DIR/terms.json"
  run run_hook "RCA means root cause analysis"
  ctx | grep -q 'stated by the owner: rca = root cause analysis'
}

@test "CCXP_TERMS_FILE alone still points the hook at the store" {
  unset CCXP_WTF_FILE
  export CCXP_TERMS_FILE="$BATS_TEST_TMPDIR/alias/store.json"
  bash "$TERMS" add RCA "root cause analysis" >/dev/null
  [ -f "$CCXP_TERMS_FILE" ]
  run run_hook "start the RCA"
  ctx | grep -qF -- '- rca = root cause analysis'
}

@test "the cwd's repo glossary and repo-scoped terms are honoured" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.claude/rules"
  git init -q "$BATS_TEST_TMPDIR/proj"
  printf -- '- LTV = loan to value\n' > "$BATS_TEST_TMPDIR/proj/.claude/rules/glossary.md"
  bash "$TERMS" add LTV "lifetime value" >/dev/null
  run bash -c "jq -cn --arg p 'what is LTV' --arg c '$BATS_TEST_TMPDIR/proj' '{prompt:\$p,cwd:\$c}' | '$HOOK'"
  ctx | grep -qF -- '- ltv = loan to value'
  run run_hook "what is LTV"
  ctx | grep -qF -- '- ltv = lifetime value'
}

@test "malformed input, empty prompt and a corrupt wtf file never fail the prompt" {
  run bash -c "echo 'not json' | '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c "echo '{}' | '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  echo '{{broken' > "$CCXP_WTF_FILE"
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
  [[ "$(ctx)" == *"rca = root cause analysis"* ]]
  run run_hook "$filler RCA"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
