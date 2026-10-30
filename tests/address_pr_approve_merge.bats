#!/usr/bin/env bats
# address-pr/scripts/approve-dispatch.sh, wait-merged.sh and slack-text.sh — the §2.d
# approval dispatch + poll + fallback, the §3.3 merge poll and the §3.1 Slack text.
# Offline and instant: a stub gh wrapper (GH_SH) logs every call and serves the review /
# PR state from counters; poll intervals are 0; nothing here can touch GitHub or Slack.

load test_helper
bats_require_minimum_version 1.5.0

APPROVE="$REPO_ROOT/address-pr/scripts/approve-dispatch.sh"
WAIT="$REPO_ROOT/address-pr/scripts/wait-merged.sh"
STEXT="$REPO_ROOT/address-pr/scripts/slack-text.sh"
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB_DIR"
  export STUB_LOG="$STUB_DIR/calls.log"; : > "$STUB_LOG"
  echo 0 > "$STUB_DIR/review_polls"; echo 0 > "$STUB_DIR/state_polls"
  # Stub gh: STUB_WF_RC (workflow view), STUB_RUN_RC (workflow run), STUB_APPROVE_ON (the
  # review poll on which an APPROVED review of $STUB_APPROVED_SHA appears; 0 = never),
  # STUB_API_RC (api POST), STUB_STATES (space-separated pr state per poll, last repeats).
  cat > "$STUB_DIR/gh.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*${GH_TOKEN:+ [GH_TOKEN set: $GH_TOKEN]}" >> "$STUB_LOG"
case "$1 $2" in
  "workflow view") exit "${STUB_WF_RC:-0}" ;;
  "workflow run") exit "${STUB_RUN_RC:-0}" ;;
  "repo view") echo '{"nameWithOwner":"acme/repo"}' ;;
  "api --method") exit "${STUB_API_RC:-0}" ;;
  "pr view")
    case "$*" in
      *reviews*)
        n=$(( $(cat "$STUB_DIR/review_polls") + 1 )); echo "$n" > "$STUB_DIR/review_polls"
        if [ "${STUB_APPROVE_ON:-0}" -gt 0 ] && [ "$n" -ge "${STUB_APPROVE_ON}" ]; then
          echo "{\"reviews\":[{\"state\":\"COMMENTED\",\"commit\":{\"oid\":\"$STUB_APPROVED_SHA\"}},{\"state\":\"APPROVED\",\"commit\":{\"oid\":\"$STUB_APPROVED_SHA\"}}]}"
        else
          echo '{"reviews":[{"state":"APPROVED","commit":{"oid":"0000000000000000000000000000000000000000"}}]}'
        fi ;;
      *state*)
        n=$(( $(cat "$STUB_DIR/state_polls") + 1 )); echo "$n" > "$STUB_DIR/state_polls"
        [ "${STUB_STATE_RC:-0}" = 0 ] || exit 1
        set -- $STUB_STATES; [ "$n" -gt "$#" ] && n=$#
        echo "{\"state\":\"${!n}\"}" ;;
    esac ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 97 ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "token-script $*" >> "$STUB_LOG"\n[ -z "${STUB_TOKEN_FAIL:-}" ] || exit 1\necho tok-SECRET-9\n' > "$STUB_DIR/token.sh"
  export GH_SH="$STUB_DIR/gh.sh" GH_APP_TOKEN_SH="$STUB_DIR/token.sh"
  export STUB_APPROVED_SHA="$SHA"
  export APPROVE_POLL_TRIES=5 APPROVE_POLL_INTERVAL=0 WAIT_MERGED_TRIES=4 WAIT_MERGED_INTERVAL=0
  unset GH_APP_ID GH_APP_PRIVATE_KEY_FILE GH_APP_PRIVATE_KEY
}

approve() { run --separate-stderr bash "$APPROVE" "$@"; }
creds() { export GH_APP_ID=123 GH_APP_PRIVATE_KEY_FILE=/nonexistent/key.pem; }

# --- approve-dispatch ---

@test "approve-dispatch: clean bill dispatches pinned to the sha and approves when the review lands on the first poll" {
  STUB_APPROVE_ON=1 approve 12 "$SHA" --clean-bill
  [ "$status" -eq 0 ]; [ "$output" = "approved via workflow $SHA" ]
  assert_calls "$STUB_LOG" "^workflow run pr-approve.yml -f pr_number=12 -f commit_sha=$SHA\$"
  refute_calls "$STUB_LOG" '^api --method'
}

@test "approve-dispatch: success on the third poll" {
  STUB_APPROVE_ON=3 approve 12 "$SHA" --clean-bill
  [ "$status" -eq 0 ]; [ "$output" = "approved via workflow $SHA" ]
  [ "$(cat "$STUB_DIR/review_polls")" -eq 3 ]
}

@test "approve-dispatch: an approval of a DIFFERENT commit never counts" {
  STUB_APPROVE_ON=1 STUB_APPROVED_SHA="$OTHER" approve 12 "$SHA" --clean-bill
  [ "$status" -eq 11 ]; [ "$output" = "timeout" ]
}

@test "approve-dispatch: no approval within the window is timeout (exit 11), after exactly TRIES polls" {
  approve 12 "$SHA" --clean-bill
  [ "$status" -eq 11 ]; [ "$output" = "timeout" ]
  [ "$(cat "$STUB_DIR/review_polls")" -eq 5 ]
}

@test "approve-dispatch: no fallback without GH_APP_ID or without a key" {
  approve 12 "$SHA" --clean-bill; [ "$status" -eq 11 ]
  GH_APP_ID=1 approve 12 "$SHA" --clean-bill; [ "$status" -eq 11 ]
  GH_APP_PRIVATE_KEY_FILE=/k approve 12 "$SHA" --clean-bill; [ "$status" -eq 11 ]
  refute_calls "$STUB_LOG" '^api --method'
  refute_calls "$STUB_LOG" '^token-script'
}

@test "approve-dispatch: fallback mints a token and posts the pinned APPROVE; the token is never printed" {
  creds
  approve 12 "$SHA" --clean-bill
  [ "$status" -eq 0 ]; [ "$output" = "approved via fallback $SHA" ]
  [[ "$output$stderr" != *tok-SECRET-9* ]]
  assert_calls "$STUB_LOG" "^token-script --repo acme/repo\$"
  assert_calls "$STUB_LOG" "^api --method POST repos/acme/repo/pulls/12/reviews -f event=APPROVE -f commit_id=$SHA -f body=.*local-mint fallback.* \[GH_TOKEN set: tok-SECRET-9\]\$"
}

@test "approve-dispatch: a failing token mint or failing POST ends in timeout, not approved" {
  creds
  STUB_TOKEN_FAIL=1 approve 12 "$SHA" --clean-bill; [ "$status" -eq 11 ]; [ "$output" = "timeout" ]
  STUB_API_RC=1 approve 12 "$SHA" --clean-bill; [ "$status" -eq 11 ]; [ "$output" = "timeout" ]
}

@test "approve-dispatch: a failed dispatch still checks for a landed approval" {
  STUB_RUN_RC=1 STUB_APPROVE_ON=1 approve 12 "$SHA" --clean-bill
  [ "$status" -eq 0 ]; [[ "$stderr" == *"dispatch failed"* ]]
}

@test "approve-dispatch: no pr-approve.yml (or gh unable to tell) is no-workflow, exit 10, nothing dispatched" {
  STUB_WF_RC=1 approve 12 "$SHA" --clean-bill
  [ "$status" -eq 10 ]; [ "$output" = "no-workflow" ]
  refute_calls "$STUB_LOG" '^workflow run'
  creds; STUB_WF_RC=1 approve 12 "$SHA" --clean-bill   # credentials never bypass a missing workflow
  [ "$status" -eq 10 ]
  refute_calls "$STUB_LOG" '^(workflow run|api --method)'
}

@test "approve-dispatch: LGTM triggers the same dispatch and says who" {
  STUB_APPROVE_ON=1 approve 12 "$SHA" --lgtm-by alice
  [ "$status" -eq 0 ]; [[ "$stderr" == *"approval triggered via LGTM by alice"* ]]
  assert_calls "$STUB_LOG" '^workflow run pr-approve.yml'
}

@test "approve-dispatch: LGTM with a finding open is not-eligible (exit 12), nothing dispatched" {
  creds
  approve 12 "$SHA" --lgtm-by alice --findings-open
  [ "$status" -eq 12 ]; [ "$output" = "not-eligible" ]
  [ ! -s "$STUB_LOG" ]
}

@test "approve-dispatch: --dry-run reads but never dispatches, polls or posts" {
  creds
  approve 12 "$SHA" --clean-bill --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == "dry-run: would dispatch pr-approve.yml -f pr_number=12 -f commit_sha=$SHA"* ]]
  [[ "$output" == *"locally minted"* ]]
  refute_calls "$STUB_LOG" '^(workflow run|api --method|pr )'
  refute_calls "$STUB_LOG" '^token-script'
  unset GH_APP_ID GH_APP_PRIVATE_KEY_FILE
  approve 12 "$SHA" --clean-bill --dry-run
  [[ "$output" == *"no App credentials"* ]]
  STUB_WF_RC=1 approve 12 "$SHA" --clean-bill --dry-run; [ "$status" -eq 10 ]
}

@test "approve-dispatch: a missing or contradictory trigger, bad ids and bad intervals are usage errors (exit 2), nothing runs" {
  approve 12 "$SHA"; [ "$status" -eq 2 ]
  approve 12 "$SHA" --clean-bill --lgtm-by alice; [ "$status" -eq 2 ]
  approve 12 "$SHA" --clean-bill --findings-open; [ "$status" -eq 2 ]
  approve 12 "$SHA" --findings-open; [ "$status" -eq 2 ]
  approve 12 "$SHA" --lgtm-by; [ "$status" -eq 2 ]
  approve 12 "$SHA" --lgtm-by ""; [ "$status" -eq 2 ]
  approve 12 "$SHA" --bogus --clean-bill; [ "$status" -eq 2 ]
  approve abc "$SHA" --clean-bill; [ "$status" -eq 2 ]
  approve 12 "${SHA:0:12}" --clean-bill; [ "$status" -eq 2 ]
  approve 12 "" --clean-bill; [ "$status" -eq 2 ]
  approve; [ "$status" -eq 2 ]
  APPROVE_POLL_TRIES=0 approve 12 "$SHA" --clean-bill; [ "$status" -eq 2 ]
  APPROVE_POLL_INTERVAL=x approve 12 "$SHA" --clean-bill; [ "$status" -eq 2 ]
  [ ! -s "$STUB_LOG" ]
}

# --- wait-merged ---

wait_merged() { run --separate-stderr bash "$WAIT" "$@"; }

@test "wait-merged: merged on the first poll" {
  STUB_STATES="MERGED" wait_merged 12
  [ "$status" -eq 0 ]; [ "$output" = "merged" ]
  [ "$(cat "$STUB_DIR/state_polls")" -eq 1 ]
}

@test "wait-merged: waits through OPEN until MERGED" {
  STUB_STATES="OPEN OPEN MERGED" wait_merged 12
  [ "$status" -eq 0 ]; [ "$output" = "merged" ]
  [ "$(cat "$STUB_DIR/state_polls")" -eq 3 ]
}

@test "wait-merged: still OPEN at the end is timeout (exit 11)" {
  STUB_STATES="OPEN" wait_merged 12
  [ "$status" -eq 11 ]; [ "$output" = "timeout open" ]
  [ "$(cat "$STUB_DIR/state_polls")" -eq 4 ]
}

@test "wait-merged: CLOSED without merge stops at once (exit 12)" {
  STUB_STATES="OPEN CLOSED" wait_merged 12
  [ "$status" -eq 12 ]; [ "$output" = "closed" ]
  [ "$(cat "$STUB_DIR/state_polls")" -eq 2 ]
}

@test "wait-merged: unreadable or unknown state is never merged (exit 4)" {
  STUB_STATE_RC=1 STUB_STATES="MERGED" wait_merged 12
  [ "$status" -eq 4 ]; [ -z "$output" ]
  STUB_STATES="WHATEVER" wait_merged 12
  [ "$status" -eq 4 ]; [ -z "$output" ]
}

@test "wait-merged: only reads PR state; never merges or writes" {
  STUB_STATES="OPEN MERGED" wait_merged 12
  refute_calls "$STUB_LOG" '^(pr merge|pr comment|pr edit|api|workflow run)'
}

@test "wait-merged: usage errors exit 2" {
  wait_merged; [ "$status" -eq 2 ]
  wait_merged abc; [ "$status" -eq 2 ]
  wait_merged 12 13; [ "$status" -eq 2 ]
  WAIT_MERGED_TRIES=0 wait_merged 12; [ "$status" -eq 2 ]
  WAIT_MERGED_INTERVAL=-1 wait_merged 12; [ "$status" -eq 2 ]
}

# --- slack-text ---

@test "slack-text: verified template" {
  run --separate-stderr bash "$STEXT" 12 https://github.com/acme/repo/pull/12
  [ "$status" -eq 0 ]
  [ "$output" = "PR #12 is ready to merge — CI green, Claude Code review addressed, test plan verified. https://github.com/acme/repo/pull/12" ]
  run --separate-stderr bash "$STEXT" 12 https://github.com/acme/repo/pull/12 --unverified 0
  [[ "$output" == *"test plan verified."* ]]
}

@test "slack-text: manual-verification template carries the count" {
  run --separate-stderr bash "$STEXT" 12 https://github.com/acme/repo/pull/12 --unverified 3
  [ "$status" -eq 0 ]
  [ "$output" = "PR #12 is ready to merge — CI green, Claude Code review addressed. 3 test plan items need manual verification. https://github.com/acme/repo/pull/12" ]
}

@test "slack-text: bad input is a usage error, nothing printed" {
  for bad in "x https://a/b" "12 not-a-url" "12 ftp://a/b" "12 https://a/b c" "12" "" "12 https://a/b --unverified" "12 https://a/b --unverified -1" "12 https://a/b --unverified x" "12 https://a/b --frob"; do
    run --separate-stderr bash "$STEXT" $bad
    [ "$status" -eq 2 ]; [ -z "$output" ]
  done
  run --separate-stderr bash "$STEXT" 12 $'https://a/b\nINJECT'
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

# --- SKILL.md switchover ---

@test "SKILL.md calls the three scripts and no longer inlines the poll loops" {
  S="$REPO_ROOT/address-pr/SKILL.md"
  grep -q 'address-pr/scripts/approve-dispatch.sh' "$S"
  grep -q 'address-pr/scripts/wait-merged.sh' "$S"
  grep -q 'address-pr/scripts/slack-text.sh' "$S"
  ! grep -q 'seq 1 12' "$S"
}
