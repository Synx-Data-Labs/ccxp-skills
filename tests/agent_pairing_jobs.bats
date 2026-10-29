#!/usr/bin/env bats
# Tests for agent-pairing/scripts/job-{launch,status,resume}.sh using a fake
# `claude` shim on PATH -- no real Claude runs (T20261022-349299).

load test_helper
setup() {
  D="$REPO_ROOT/agent-pairing/scripts"
  export CCXP_JOBS_DIR="$BATS_TEST_TMPDIR/jobs"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  export CCXP_JOB_STOP_WAIT=1
  export FAKE_LOG="$BATS_TEST_TMPDIR/claude.log"
  export FAKE_AGENTS_JSON="$BATS_TEST_TMPDIR/agents.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/work"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "PWD=$PWD"; for a in "$@"; do echo "ARG=$a"; done; echo "--"; } >> "$FAKE_LOG"
case "$1" in
  agents) cat "$FAKE_AGENTS_JSON" ;;
  stop) jq --arg id "$2" 'map(if .id==$id then .status=null else . end)' "$FAKE_AGENTS_JSON" > "$FAKE_AGENTS_JSON.n" && mv "$FAKE_AGENTS_JSON.n" "$FAKE_AGENTS_JSON"; echo "stopped $2" ;;
  --bg) if [ -n "${FAKE_UNTRUSTED:-}" ]; then echo "Workspace not trusted. Run claude once"; else echo "backgrounded · ab12cd34 · x"; fi ;;
  --resume) echo "backgrounded · ab12cd34" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  PROMPT="$BATS_TEST_TMPDIR/p.md"
  printf 'Goal: do a thing.\nNEEDS INPUT: convention.\n' > "$PROMPT"
}

settings() { cat "$CCXP_JOBS_DIR/$1/settings.json"; }

@test "launch: name jN-slug, prints id, safe defaults, prompt last after --" {
  run bash "$D/job-launch.sh" 52 "Remove pr-approve.yml!" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work" --add-dir /x/clone
  [ "$status" -eq 0 ]
  [[ "$output" == "JOB 52 name=j52-remove-pr-approve-yml id=ab12cd34 "* ]]
  grep -q '^ARG=--bg$' "$FAKE_LOG"
  grep -q '^ARG=j52-remove-pr-approve-yml$' "$FAKE_LOG"
  grep -q '^ARG=dontAsk$' "$FAKE_LOG"
  grep -q '^ARG=claude$' "$FAKE_LOG"
  grep -q "^PWD=.*work$" "$FAKE_LOG"
  # the prompt is the final arg, preceded by `--` (add-dir is variadic)
  tail -4 "$FAKE_LOG" | grep -q '^ARG=--$'
  grep -q '^NEEDS INPUT: convention\.$' "$FAKE_LOG"
  [ "$(settings j52-remove-pr-approve-yml | jq -r '.permissions.deny | index("Bash(git push *)") != null')" = true ]
  [ "$(settings j52-remove-pr-approve-yml | jq -r '.permissions.deny | index("Bash(gh pr merge *)") != null')" = true ]
  [ "$(settings j52-remove-pr-approve-yml | jq -r '.crossSessionInbound')" = accept ]
  [ "$(ls -l "$CCXP_JOBS_DIR/j52-remove-pr-approve-yml/settings.json" | cut -c1-10)" = "-rw-------" ]
  [ "$(jq -r .id "$CCXP_JOBS_DIR/j52-remove-pr-approve-yml/job.json")" = ab12cd34 ]
}

@test "launch: quoted authorization turns into allow rules and drops those denies" {
  cat >> "$PROMPT" <<'EOF'

## Authorization
> "yes, push the branch and merge it"
allow: push
allow: pr-merge
EOF
  run bash "$D/job-launch.sh" 7 "Ship it" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work"
  [ "$status" -eq 0 ]
  s="$(settings j7-ship-it)"
  [ "$(jq -r '.permissions.allow | index("Bash(git push *)") != null' <<< "$s")" = true ]
  [ "$(jq -r '.permissions.deny | index("Bash(git push *)") == null' <<< "$s")" = true ]
  [ "$(jq -r '.permissions.deny | index("Bash(gh workflow run *)") != null' <<< "$s")" = true ]
}

@test "launch: allow lines without a quoted user line are refused, nothing launched" {
  printf '\n## Authorization\nallow: push\n' >> "$PROMPT"
  run bash "$D/job-launch.sh" 8 "x" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no quoted"* ]]
  [ ! -e "$FAKE_LOG" ]
}

@test "launch: unknown authorization token is refused" {
  printf '\n## Authorization\n> "ok"\nallow: rm-rf\n' >> "$PROMPT"
  run bash "$D/job-launch.sh" 9 "x" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown authorization token"* ]]
}

@test "launch: --env passes by name; value is in the 0600 settings only, never argv or stdout" {
  export PROBE_NONSECRET=sentinel-value-123
  run bash "$D/job-launch.sh" 3 "env" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work" --env PROBE_NONSECRET
  [ "$status" -eq 0 ]
  [[ "$output" != *sentinel-value-123* ]]
  run grep -q sentinel-value-123 "$FAKE_LOG"
  [ "$status" -ne 0 ]
  [ "$(settings j3-env | jq -r .env.PROBE_NONSECRET)" = sentinel-value-123 ]
}

@test "launch: --env of an unset variable fails" {
  unset NOPE_VAR || true
  run bash "$D/job-launch.sh" 3 "env" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work" --env NOPE_VAR
  [ "$status" -ne 0 ]
  [[ "$output" == *"not set"* ]]
}

@test "launch: untrusted workspace gives exit 3 and a hint" {
  FAKE_UNTRUSTED=1 run bash "$D/job-launch.sh" 4 "t" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a trusted workspace"* ]]
}

@test "launch: rejects bad number and empty prompt" {
  run bash "$D/job-launch.sh" abc "t" "$PROMPT"
  [ "$status" -ne 0 ]
  : > "$BATS_TEST_TMPDIR/empty.md"
  run bash "$D/job-launch.sh" 1 "t" "$BATS_TEST_TMPDIR/empty.md"
  [ "$status" -ne 0 ]
}

mk_agents() {
  cat > "$FAKE_AGENTS_JSON" <<EOF
[{"id":"aa000001","name":"j52-remove-pr-approve","state":"blocked","status":"waiting","waitingFor":"permission prompt","sessionId":"aa000001-0000","cwd":"$BATS_TEST_TMPDIR/work"},
 {"id":"bb000002","name":"j53-nightly","state":"done","status":"idle","sessionId":"bb000002-1111","cwd":"$BATS_TEST_TMPDIR/work"},
 {"id":"cc000003","name":"some other session","state":"working","status":"busy","sessionId":"cc","cwd":"/"}]
EOF
}

@test "status: lists only jN- jobs with state and waitingFor" {
  mk_agents
  run bash "$D/job-status.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#52 j52-remove-pr-approve blocked/waiting waiting:permission_prompt aa000001"* ]]
  [[ "$output" == *"#53 j53-nightly done/idle bb000002"* ]]
  [[ "$output" != *"some other"* ]]
  run bash "$D/job-status.sh" 53
  [ "$(wc -l <<< "$output" | tr -d ' ')" = 1 ]
}

@test "status --report: prints the last assistant text from the transcript" {
  mk_agents
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"
  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"NEEDS INPUT: which repo?"}]}}' \
    > "$CLAUDE_CONFIG_DIR/projects/p/bb000002-1111.jsonl"
  run bash "$D/job-status.sh" 53 --report
  [ "$status" -eq 0 ]
  [[ "$output" == *"NEEDS INPUT: which repo?" ]]
}

@test "resume: stops the live process then resumes the same session with no flags, from the job cwd" {
  mk_agents
  run bash "$D/job-resume.sh" 53 "use repo foo"
  [ "$status" -eq 0 ]
  grep -q '^ARG=stop$' "$FAKE_LOG"
  tail -5 "$FAKE_LOG" | grep -q '^ARG=--resume$'
  grep -q '^ARG=bb000002-1111$' "$FAKE_LOG"
  grep -q '^ARG=use repo foo$' "$FAKE_LOG"
  # resume call carries no flag besides --resume/--bg
  run bash -c "tail -7 '$FAKE_LOG' | grep -E '^ARG=--(name|settings|agent|model|permission-mode)'"
  [ "$status" -ne 0 ]
  grep -q "^PWD=.*work$" "$FAKE_LOG"
}

@test "resume: refuses a job waiting on a permission prompt" {
  mk_agents
  run bash "$D/job-resume.sh" 52 "yes"
  [ "$status" -eq 4 ]
  [[ "$output" == *"claude attach aa000001"* ]]
  run grep -q '^ARG=--resume$' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "resume: unknown job fails" {
  mk_agents
  run bash "$D/job-resume.sh" 99 "x"
  [ "$status" -ne 0 ]
}

@test "launch: --allow of a default-denied rule is refused (only Authorization lifts a deny)" {
  run bash "$D/job-launch.sh" 5 "x" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work" --allow 'Bash(git push *)'
  [ "$status" -ne 0 ]
  [[ "$output" == *"lifts a default deny"* ]]
  [ ! -e "$FAKE_LOG" ]
}

@test "launch: bad --env name is a clean error" {
  run bash "$D/job-launch.sh" 5 "x" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work" --env 'a b'
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad --env name"* ]]
}

@test "resume: aborts when the process is still live after stop" {
  mk_agents
  # shim whose stop does not clear the status
  sed -i.bak 's/^  stop).*/  stop) echo "stopped $2" ;;/' "$BATS_TEST_TMPDIR/bin/claude"
  run bash "$D/job-resume.sh" 53 "x"
  [ "$status" -eq 5 ]
  run grep -q '^ARG=--resume$' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "resume: a dash-leading answer is not parsed as a flag" {
  mk_agents
  run bash "$D/job-resume.sh" 53 "--name evil"
  [ "$status" -eq 0 ]
  grep -q '^ARG= --name evil$' "$FAKE_LOG"
}

@test "launch: default allow-list lets a job run trash.sh (delete-by-trash), not rm" {
  run bash "$D/job-launch.sh" 8 "Tidy" "$PROMPT" --cwd "$BATS_TEST_TMPDIR/work"
  [ "$status" -eq 0 ]
  s="$(settings j8-tidy)"
  [ "$(jq -r '.permissions.allow | index("Bash(bash */agent-pairing/scripts/trash.sh *)") != null' <<< "$s")" = true ]
  [ "$(jq -r '[.permissions.allow[] | select(test("rm"))] | length' <<< "$s")" = 0 ]
}
