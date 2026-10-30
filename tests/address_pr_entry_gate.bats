#!/usr/bin/env bats
# address-pr/scripts/entry-gate.sh — the §1 / §1.3 / §1.6 entry decision.
# Offline: the shared fake gh, plus stubs for pr-owner, pr_task_id and auto-pick.

load test_helper
bats_require_minimum_version 1.5.0

GATE="$REPO_ROOT/address-pr/scripts/entry-gate.sh"

setup() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  echo 'me' > "$FX/api_user_jq_login.txt"
  echo '{"author":{"login":"me"},"headRefName":"t20000101-000001-thing"}' > "$FX/pr_view_12_json_author_headRefName.json"
  fake_gh "$FX"
  printf '#!/usr/bin/env bash\nexec gh "$@"\n' > "$BATS_TEST_TMPDIR/gh-sh.sh"
  export GH_SH="$BATS_TEST_TMPDIR/gh-sh.sh"
  # stubs: STUB_OWNER is the pr-owner answer (a call is logged), STUB_TASK the pr_task_id answer
  cat > "$BATS_TEST_TMPDIR/claim.sh" <<'STUB'
#!/usr/bin/env bash
echo "pr-owner $2" >> "$STUB_LOG"
printf '%s' "${STUB_OWNER-}"
exit "${STUB_OWNER_RC:-0}"
STUB
  printf '#!/usr/bin/env bash\nprintf "%%s" "${STUB_TASK-}"\n' > "$BATS_TEST_TMPDIR/taskid.sh"
  cat > "$BATS_TEST_TMPDIR/pick.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_PICK-}"
STUB
  export TASK_CLAIM_SH="$BATS_TEST_TMPDIR/claim.sh" PR_TASK_ID_SH="$BATS_TEST_TMPDIR/taskid.sh" AUTO_PICK_SH="$BATS_TEST_TMPDIR/pick.sh"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"; : > "$STUB_LOG"
  export STUB_TASK=T20000101-000001
}

# gate <arg> -> $status, $output (stdout only)
gate() { run --separate-stderr bash "$GATE" "$@"; }
field() { printf '%s' "$output" | jq -r ".$1"; }

@test "ours and claimed by this clone: proceed (0) with the full JSON" {
  STUB_OWNER=mine gate 12
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"number":12,"task_id":"T20000101-000001","author":"me","verdict":"mine","head_ref":"t20000101-000001-thing"}' ]
}

@test "untracked (no task) proceeds with an empty task_id" {
  STUB_OWNER=untracked STUB_TASK= gate 12
  [ "$status" -eq 0 ]; [ "$(field verdict)" = untracked ]; [ "$(field task_id)" = "" ]
}

@test "free -> 10 and new -> 11 (claim first); the verdict says which" {
  STUB_OWNER=free gate 12; [ "$status" -eq 10 ]; [ "$(field verdict)" = free ]
  STUB_OWNER=new gate 12;  [ "$status" -eq 11 ]; [ "$(field verdict)" = new ]
}

@test "owned by another session defers (21) and keeps the owner in the verdict" {
  STUB_OWNER='owned:cc1-host:abcd' gate 12
  [ "$status" -eq 21 ]; [ "$(field verdict)" = 'owned:cc1-host:abcd' ]
}

@test "unknown, empty, garbage or failing pr-owner never proceeds (22)" {
  local o
  for o in unknown "" "mine-ish" "owned:" "MINE" "free extra"; do
    STUB_OWNER="$o" gate 12
    [ "$status" -eq 22 ] || { echo "owner '$o' -> $status"; return 1; }
    [ "$(field verdict)" = unknown ]
  done
  STUB_OWNER=mine STUB_OWNER_RC=1 gate 12; [ "$status" -eq 22 ]   # a failing pr-owner call is unknown even if it printed a verdict
}

@test "a foreign author is 20, and pr-owner is never consulted" {
  echo '{"author":{"login":"alice"},"headRefName":"x"}' > "$FX/pr_view_12_json_author_headRefName.json"
  STUB_OWNER=mine gate 12
  [ "$status" -eq 20 ]; [ "$(field verdict)" = foreign ]; [ "$(field author)" = alice ]
  [ ! -s "$STUB_LOG" ]
}

@test "an empty or missing author is foreign (fail closed)" {
  echo '{"author":{"login":""},"headRefName":"x"}' > "$FX/pr_view_12_json_author_headRefName.json"
  STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  echo '{"author":null}' > "$FX/pr_view_12_json_author_headRefName.json"
  STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  echo 'not json' > "$FX/pr_view_12_json_author_headRefName.json"
  STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  [ ! -s "$STUB_LOG" ]
}

@test "an unreadable gh login or a failing gh pr view is foreign (20)" {
  FAKE_GH_FAIL='^api user' STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  echo '' > "$FX/api_user_jq_login.txt"
  STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  echo 'me' > "$FX/api_user_jq_login.txt"
  FAKE_GH_FAIL='^pr view' STUB_OWNER=mine gate 12; [ "$status" -eq 20 ]
  [ ! -s "$STUB_LOG" ]
}

@test "a PR URL is reduced to its number; query, fragment and trailing slash are tolerated" {
  echo 'acme/repo' > "$FX/repo_view_json_nameWithOwner_jq_nameWithOwner.txt"
  STUB_OWNER=mine gate https://github.com/acme/repo/pull/12; [ "$status" -eq 0 ]; [ "$(field number)" = 12 ]
  STUB_OWNER=mine gate 'https://github.com/acme/repo/pull/12/files?x=1#y'; [ "$status" -eq 0 ]; [ "$(field number)" = 12 ]
  grep -q '^pr-owner 12$' "$STUB_LOG"
}

@test "a PR URL for another repo, or when this repo is unreadable, is refused (2) before any gate" {
  echo 'acme/repo' > "$FX/repo_view_json_nameWithOwner_jq_nameWithOwner.txt"
  STUB_OWNER=mine gate https://github.com/acme/other/pull/12
  [ "$status" -eq 2 ]; [ -z "$output" ]; [[ "$stderr" == *"acme/other"*"acme/repo"* ]]
  FAKE_GH_FAIL='^repo view' STUB_OWNER=mine gate https://github.com/acme/repo/pull/12; [ "$status" -eq 2 ]
  STUB_OWNER=mine gate https://github.com/ACME/Repo/pull/12; [ "$status" -eq 0 ]   # case-insensitive
  [ ! -s "$STUB_LOG" ] || [ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 1 ]
}

@test "- auto-picks: the picked number is gated, nothing picked is exit 1" {
  STUB_PICK='{"number":12,"title":"t","createdAt":"x","reason":"mine"}' STUB_OWNER=mine gate -
  [ "$status" -eq 0 ]; [ "$(field number)" = 12 ]
  STUB_PICK= gate -
  [ "$status" -eq 1 ]; [ -z "$output" ]
  STUB_PICK='garbage' gate -; [ "$status" -eq 1 ]
}

@test "usage errors exit 2" {
  gate; [ "$status" -eq 2 ]
  gate 12 13; [ "$status" -eq 2 ]
  gate abc; [ "$status" -eq 2 ]
  gate '12;ls'; [ "$status" -eq 2 ]
  gate https://github.com/acme/repo/issues/12; [ "$status" -eq 2 ]
}

@test "the gate is read-only: no write-shaped gh call" {
  STUB_OWNER=free gate 12
  refute_calls "$FAKE_GH_LOG" '^(pr (merge|comment|edit|review)|workflow run|api .*(-X|--method|-f))'
}

@test "address-pr SKILL.md runs entry-gate and the exit-code list covers every code" {
  grep -q 'address-pr/scripts/entry-gate.sh' "$REPO_ROOT/address-pr/SKILL.md"
  local c
  for c in 10 11 20 21 22; do grep -qE "^- \`$c\` " "$REPO_ROOT/address-pr/SKILL.md" || { echo "no entry for exit $c"; return 1; }; done
}
