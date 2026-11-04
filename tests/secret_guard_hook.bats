#!/usr/bin/env bats
# hooks/secret-guard.sh (+ secret-guard.py) -- PreToolUse(Bash) hook that denies
# command lines carrying a secret. Fake secrets are assembled from fragments so
# no real token-shaped literal sits in this file.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_ROOT/hooks/secret-guard.sh"
  unset CCXP_ALLOW_SECRETS
  export CCXP_SECRET_GUARD_LOG="$BATS_TEST_TMPDIR/overrides.log"
  CWD="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$CWD"
  P1="gh""p_"; BODY="Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56"
  FAKE="${P1}${BODY}"
}

run_hook() {
  jq -n --arg c "$1" --arg d "${2:-$CWD}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | "$HOOK"
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$output"; }

assert_blocked() {
  run run_hook "$1"
  [ "$status" -eq 0 ] || { echo "exit $status for: $1"; return 1; }
  [ "$(decision)" = deny ] || { echo "expected deny: $1 (output: $output)"; return 1; }
}
assert_allowed() {
  run run_hook "$1"
  [ "$status" -eq 0 ] || { echo "exit $status for: $1"; return 1; }
  [ -z "$output" ] || { echo "expected silence: $1 (output: $output)"; return 1; }
}

@test "blocked: token-shaped literals" {
  assert_blocked "curl -H 'Authorization: token $FAKE' https://x.example"
  assert_blocked "echo xo""xb-123456789012-abcdefabcdef"
  assert_blocked "aws s3 ls AKI""AABCDEFGHIJKLMNOP"
  assert_blocked "export API_TOKEN=${BODY}"
  assert_blocked "git clone https://u:s3cretpass@host.example/r.git"
}

@test "blocked: secrets on the command line" {
  assert_blocked "tool --token abc123def456"
  assert_blocked "tool --password=hunter22"
  assert_blocked "tool --token \"\$GH_TOKEN\""
  assert_blocked "mysql password=hunter22"
  assert_blocked "curl -u admin:hunter22 https://x.example"
  assert_blocked "docker login -u me -p hunter22"
  assert_blocked "gh secret set FOO --body hunter22"
}

@test "blocked: echo, env dumps, cat .env and set -x with secrets" {
  assert_blocked 'echo "$GITHUB_TOKEN"'
  assert_blocked 'printf %s "$DB_PASSWORD"'
  assert_blocked 'env'
  assert_blocked 'printenv'
  assert_blocked 'printenv API_TOKEN'
  assert_blocked 'env | grep -i token'
  assert_blocked 'cat .env'
  assert_blocked 'cat ./config/.env.production'
  assert_blocked 'set -x; curl -H "$API_TOKEN" https://x.example'
  assert_blocked 'true && bash -x deploy.sh "$DB_PASSWORD"'
}

@test "allowed: safe forms" {
  assert_allowed 'op run -- deploy.sh'
  assert_allowed 'docker login -u me --password-stdin <<< "$REGISTRY_TOKEN"'
  assert_allowed 'echo "$GITHUB_TOKEN" | docker login --password-stdin'
  assert_allowed 'tool --token-file /run/secrets/t'
  assert_allowed 'tool --token-file "$TOKEN_FILE"'
  assert_allowed 'op inject -i .env.tpl -o .env'
  assert_allowed 'cat .env.tpl'
  assert_allowed 'echo "$TOKEN_PATH"'
  assert_allowed 'env | grep -c PATH'
  assert_allowed 'printenv HOME'
  assert_allowed 'mkdir -p a/b && cp -p x y && ssh -p 22 host true'
  assert_allowed 'git commit -m "document token handling"'
  assert_allowed 'ls -la'
}

@test "deny message is masked, never echoes the value, and names a safe form" {
  run run_hook "curl -H 'Authorization: token $FAKE' https://x.example"
  [ "$(decision)" = deny ]
  msg="$(reason)"
  [[ "$msg" != *"$FAKE"* ]]
  [[ "$msg" != *"$BODY"* ]]
  [[ "$msg" == *"token-literal"* ]]
  [[ "$msg" == *"op run"* ]]
  run run_hook "tool --password=hunter22"
  [[ "$(reason)" != *hunter22* ]]
}

@test "allow-list: matching rule-id:glob:reason entry allows; no reason does not" {
  git -C "$CWD" init -q
  printf 'cmdline-secret:tool --password=*:fixture only\n' >"$CWD/.secret-guard-allow"
  assert_allowed "tool --password=hunter22"
  printf 'cmdline-secret:tool --password=*\n' >"$CWD/.secret-guard-allow"
  assert_blocked "tool --password=hunter22"
  printf 'echo-secret:tool --password=*:wrong rule\n' >"$CWD/.secret-guard-allow"
  assert_blocked "tool --password=hunter22"
}

@test "override: CCXP_ALLOW_SECRETS=1 allows, logs rule ids and never the value" {
  export CCXP_ALLOW_SECRETS=1
  run run_hook "tool --password=hunter22"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$CCXP_SECRET_GUARD_LOG" ]
  grep -q 'rules=cmdline-secret' "$CCXP_SECRET_GUARD_LOG"
  run grep -c hunter22 "$CCXP_SECRET_GUARD_LOG"
  [ "$output" = 0 ]
}

@test "override: a clean command logs nothing" {
  export CCXP_ALLOW_SECRETS=1
  run run_hook "ls"
  [ -z "$output" ]
  [ ! -s "$CCXP_SECRET_GUARD_LOG" ]
}

@test "fails open on unparsable input" {
  run bash -c "echo 'not json' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$(decision)" ]
}

@test "hooks.json registers secret-guard for the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|test("secret-guard.sh"))' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
}
