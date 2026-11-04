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
  assert_blocked "mysql -u root -phunter22 db"
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

commit_allow() {
  git -C "$CWD" init -q
  git -C "$CWD" config user.email t@example.com; git -C "$CWD" config user.name t
  printf '%s\n' "$1" >"$CWD/.secret-guard-allow"
  git -C "$CWD" add .secret-guard-allow && git -C "$CWD" commit -q -m allow
}

@test "allow-list: committed rule-id:glob:reason entry allows and logs the hit" {
  commit_allow 'cmdline-secret:tool --password=*:fixture only'
  assert_allowed "tool --password=hunter22"
  grep -q 'allow-list rules=cmdline-secret' "$CCXP_SECRET_GUARD_LOG"
}

@test "allow-list: glob may contain colons; reason is taken after the last colon" {
  commit_allow 'cmdline-secret:curl -u admin:*:fixture'
  assert_allowed "curl -u admin:hunter22 https://x.example"
}

@test "allow-list: missing reason or wrong rule allows nothing" {
  commit_allow 'cmdline-secret:tool --password=*'
  assert_blocked "tool --password=hunter22"
  commit_allow 'echo-secret:tool --password=*:wrong rule'
  assert_blocked "tool --password=hunter22"
}

@test "allow-list: an untracked or locally modified file is ignored (agent cannot grant itself a pass)" {
  git -C "$CWD" init -q
  printf 'cmdline-secret:tool --password=*:self-granted\n' >"$CWD/.secret-guard-allow"
  assert_blocked "tool --password=hunter22"
  commit_allow 'echo-secret:nothing:x'
  printf 'cmdline-secret:tool --password=*:self-granted\n' >"$CWD/.secret-guard-allow"
  assert_blocked "tool --password=hunter22"
}

@test "an inherited SECRET_GUARD_REPORT_ONLY env var does not disable denies" {
  export SECRET_GUARD_REPORT_ONLY=1
  assert_blocked "tool --password=hunter22"
}

@test "no false positives on quoted text, grep patterns and BuildKit secrets" {
  assert_allowed 'git commit -m "fix --token handling"'
  assert_allowed 'echo "use --token foo"'
  assert_allowed 'grep -- --password docs.md'
  assert_allowed 'docker buildx build --secret id=npmrc,src=$HOME/.npmrc .'
  assert_allowed 'gh pr create --title t --body "mentions --password abc"'
}

@test "echo-secret: stderr echo, nested echo, lowercase names and here-strings are caught" {
  assert_blocked 'echo "$GH_TOKEN" 2>&1'
  assert_blocked 'echo $GH_TOKEN >&2'
  assert_blocked 'echo $GH_TOKEN | tee /dev/stderr'
  assert_blocked 'if true; then echo "$GH_TOKEN"; fi'
  assert_blocked '( echo $my_token )'
  assert_blocked 'echo "a; $GH_TOKEN"'
  assert_blocked 'cat <<< "$GH_TOKEN"'
  assert_blocked 'echo "$NPM_AUTH"'
  assert_allowed 'echo "$GH_TOKEN" > /tmp/t.file'
}

@test "quote-aware: prose in commit/PR text never trips the non-token rules" {
  assert_allowed "git commit -m 'never echo \$TOKEN'"
  assert_allowed 'git commit -m "docs: curl -u user:pass x"'
  assert_allowed 'gh pr create --body "avoid docker login -p secret"'
  assert_allowed 'git commit -m "docs: postgres://u:pw@host"'
  assert_allowed 'grep -rn "echo $TOKEN" .'
  assert_allowed 'echo "${TOKEN:+set}"'
  assert_allowed 'echo "$TOKENS_USED $TOKENIZER_X"'
  assert_allowed 'GOOGLE_APPLICATION_CREDENTIALS=service-account-key.json cmd'
  assert_allowed 'TOKEN_NAME=my-long-token-name-xyz cmd'
}

@test "heredoc bodies are data: an apostrophe there does not hide a later flag" {
  assert_blocked "$(printf 'cat <<EOF > f\ndon'"'"'t\nEOF\ncmd --token abc123def456')"
  assert_allowed "$(printf 'git commit -F - <<EOF\nnever echo $TOKEN\nEOF')"
}

@test "pipes: a text command earlier in a pipeline does not hide a later secret flag" {
  assert_blocked 'echo x | gh auth login --token abc123def456'
  assert_blocked 'git log | xargs cmd --password hunter22'
  assert_blocked 'ssh host "cmd --password hunter22"'
  assert_blocked "bash -c 'cmd --token abc123def456'"
}

@test "more shapes: env prefix, -e NAME=literal, curl variants, .env readers, xtrace" {
  assert_blocked 'GH_TOKEN=abcdef123456 gh api user'
  assert_blocked 'docker run -e POSTGRES_PASSWORD=mysecretpw img'
  assert_blocked 'curl -su admin:hunter22 https://x.example'
  assert_blocked 'curl --user=admin:hunter22 https://x.example'
  assert_blocked 'cat .env .env.local'
  assert_blocked 'cat .env.example .env'
  assert_blocked 'head -n 3 .env'
  assert_blocked 'grep PASSWORD .env'
  assert_blocked 'echo $TOKEN | base64'
  assert_blocked 'echo $TOKEN | sed s/a/b/'
  assert_blocked 'echo "a > b" $GH_TOKEN'
  assert_blocked 'set -o xtrace; curl -H "$API_TOKEN" x'
  assert_allowed 'cat .env.example'
  assert_allowed 'echo "$GH_TOKEN" | gh auth login --with-token'
}

@test "deny message shows a length for non-token values, never the value" {
  run run_hook "tool --password=hunter22"
  [[ "$(reason)" == *"(8 chars)"* ]]
  [[ "$(reason)" != *hunter* ]]
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
