#!/usr/bin/env bats
# address-pr/scripts/review-state.sh and post-review.sh — the §2.d reviewed-SHA
# dedup and the pinned review comment. Offline: shared fake gh keyed on argv.

load test_helper
bats_require_minimum_version 1.5.0

STATE="$REPO_ROOT/address-pr/scripts/review-state.sh"
POST="$REPO_ROOT/address-pr/scripts/post-review.sh"
HEAD1=1111111111111111111111111111111111111111
HEAD2=2222222222222222222222222222222222222222

setup() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  echo '{"login":"me"}' > "$FX/api_user.json"
  echo "{\"headRefOid\":\"$HEAD1\"}" > "$FX/pr_view_12_json_headRefOid.json"
  echo '[]' > "$FX/api_paginate_repos_owner_repo_issues_12_comments_per_page_100.json"
  echo 'https://github.com/acme/repo/pull/12#issuecomment-1' > "$FX/pr_comment_12.txt"
  fake_gh "$FX"
  printf '#!/usr/bin/env bash\nexec gh "$@"\n' > "$BATS_TEST_TMPDIR/gh-sh.sh"
  export GH_SH="$BATS_TEST_TMPDIR/gh-sh.sh"
  REPORT="$BATS_TEST_TMPDIR/report.md"
  printf 'Finding: `rm -rf $HOME` is unsafe.\nUse "quotes" and $(subshell).\n' > "$REPORT"
}

comments() { printf '%s' "$1" > "$FX/api_paginate_repos_owner_repo_issues_12_comments_per_page_100.json"; }
# rc <login> <body> -> one comment object
rc() { jq -nc --arg l "$1" --arg b "$2" '{user:{login:$l},body:$b}'; }
state() { run --separate-stderr bash "$STATE" "$@"; }

# --- review-state ---

@test "review-state: no review comment yet needs a review of the head" {
  state 12
  [ "$status" -eq 0 ]; [ "$output" = "needs-review $HEAD1" ]
}

@test "review-state: our latest review of exactly the head is reviewed" {
  comments "[$(rc me "**Claude Code review:** (sha: $HEAD1)"$'\n\nclean bill')]"
  state 12
  [ "$status" -eq 0 ]; [ "$output" = "reviewed $HEAD1" ]
}

@test "review-state: a review of an older commit, or a newer head, needs a review" {
  comments "[$(rc me "**Claude Code review:** (sha: $HEAD2)"$'\n\nx')]"
  state 12; [ "$output" = "needs-review $HEAD1" ]
}

@test "review-state: only OUR latest marker comment counts" {
  comments "[$(rc me "**Claude Code review:** (sha: $HEAD1)"), $(rc me "**Claude Code review:** (sha: $HEAD2)")]"
  state 12; [ "$output" = "needs-review $HEAD1" ]            # the later one wins
  comments "[$(rc alice "**Claude Code review:** (sha: $HEAD1)")]"
  state 12; [ "$output" = "needs-review $HEAD1" ]            # someone else's marker is ignored
  comments "[$(rc me "not a review (sha: $HEAD1)")]"
  state 12; [ "$output" = "needs-review $HEAD1" ]            # no marker
}

@test "review-state: the sha is read from the header line only, never from the body" {
  comments "[$(rc me "**Claude Code review:** pending"$'\n\n'"mentions (sha: $HEAD1) in text")]"
  state 12; [ "$output" = "needs-review $HEAD1" ]
}

@test "review-state: a sha prefix of the head is not enough" {
  comments "[$(rc me "**Claude Code review:** (sha: ${HEAD1:0:12})")]"
  state 12; [ "$output" = "needs-review $HEAD1" ]
}

@test "review-state: paginated comment arrays are merged (the latest review can be on page 2)" {
  printf '%s\n%s\n' "[$(rc me "**Claude Code review:** (sha: $HEAD2)")]" "[$(rc me "**Claude Code review:** (sha: $HEAD1)")]" \
    > "$FX/api_paginate_repos_owner_repo_issues_12_comments_per_page_100.json"
  state 12; [ "$status" -eq 0 ]; [ "$output" = "reviewed $HEAD1" ]
}

@test "review-state: any gh failure or unusable data is exit 3 and never reviewed" {
  FAKE_GH_FAIL='^api user' state 12; [ "$status" -eq 3 ]; [ -z "$output" ]
  FAKE_GH_FAIL='^pr view' state 12; [ "$status" -eq 3 ]; [ -z "$output" ]
  FAKE_GH_FAIL='^api --paginate' state 12; [ "$status" -eq 3 ]; [ -z "$output" ]
  echo '{"headRefOid":""}' > "$FX/pr_view_12_json_headRefOid.json"
  state 12; [ "$status" -eq 3 ]
  echo "{\"headRefOid\":\"$HEAD1\"}" > "$FX/pr_view_12_json_headRefOid.json"
  echo '{"login":""}' > "$FX/api_user.json"
  state 12; [ "$status" -eq 3 ]
  echo '{"login":"me"}' > "$FX/api_user.json"
  comments 'not json'
  state 12; [ "$status" -eq 3 ]
}

@test "review-state: usage errors exit 2 and nothing is written to GitHub" {
  state; [ "$status" -eq 2 ]
  state abc; [ "$status" -eq 2 ]
  state 1 2; [ "$status" -eq 2 ]
  state 12
  refute_calls "$FAKE_GH_LOG" '^(pr (merge|comment|edit|review)|workflow run)'
}

# --- post-review ---

post() { run --separate-stderr bash "$POST" "$@"; }

@test "post-review: posts the pinned header, a blank line, then the report verbatim via stdin" {
  FAKE_GH_STDIN=1 post 12 "$HEAD1" "$REPORT"
  [ "$status" -eq 0 ]; [ "$output" = "posted $HEAD1" ]
  assert_calls "$FAKE_GH_LOG" '^pr comment 12 --body-file -$'
  expected="$(printf '**Claude Code review:** (sha: %s)\n\n' "$HEAD1"; cat "$REPORT")"
  [ "$(cat "$FAKE_GH_LOG.stdin")" = "$expected" ]
  # the report's $ and backticks reached gh unexpanded
  grep -qF 'rm -rf $HOME' "$FAKE_GH_LOG.stdin"; grep -qF '$(subshell)' "$FAKE_GH_LOG.stdin"
}

@test "post-review: a posted comment is recognised by review-state afterwards" {
  FAKE_GH_STDIN=1 post 12 "$HEAD1" "$REPORT"
  body="$(cat "$FAKE_GH_LOG.stdin")"
  comments "[$(rc me "$body")]"
  state 12; [ "$output" = "reviewed $HEAD1" ]
}

@test "post-review: an empty, whitespace-only or missing report is refused (2), nothing posted" {
  : > "$BATS_TEST_TMPDIR/empty.md"; printf ' \n\t\n' > "$BATS_TEST_TMPDIR/ws.md"
  post 12 "$HEAD1" "$BATS_TEST_TMPDIR/empty.md"; [ "$status" -eq 2 ]
  post 12 "$HEAD1" "$BATS_TEST_TMPDIR/ws.md"; [ "$status" -eq 2 ]
  post 12 "$HEAD1" "$BATS_TEST_TMPDIR/nope.md"; [ "$status" -eq 2 ]
  refute_calls "$FAKE_GH_LOG" '^pr comment'
}

@test "post-review: a stale head is refused (3), nothing posted" {
  post 12 "$HEAD2" "$REPORT"
  [ "$status" -eq 3 ]; [[ "$stderr" == *"stale"* ]]
  refute_calls "$FAKE_GH_LOG" '^pr comment'
}

@test "post-review: gh failing to read the head or to post is exit 4 and never reported as posted" {
  FAKE_GH_FAIL='^pr view' post 12 "$HEAD1" "$REPORT"; [ "$status" -eq 4 ]; [[ "$output" != posted* ]]
  FAKE_GH_FAIL='^pr comment' post 12 "$HEAD1" "$REPORT"; [ "$status" -eq 4 ]; [[ "$output" != posted* ]]
  echo '{"headRefOid":""}' > "$FX/pr_view_12_json_headRefOid.json"
  post 12 "$HEAD1" "$REPORT"; [ "$status" -eq 4 ]
}

@test "post-review: --dry-run checks everything, prints the comment and posts nothing" {
  post 12 "$HEAD1" "$REPORT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "**Claude Code review:** (sha: $HEAD1)"* ]]
  refute_calls "$FAKE_GH_LOG" '^pr comment'
  post 12 "$HEAD2" "$REPORT" --dry-run; [ "$status" -eq 3 ]
  post 12 "$HEAD1" "$BATS_TEST_TMPDIR/nope.md" --dry-run; [ "$status" -eq 2 ]
}

@test "post-review: usage errors exit 2 (bad number, short sha, missing args, unknown flag)" {
  post; [ "$status" -eq 2 ]
  post abc "$HEAD1" "$REPORT"; [ "$status" -eq 2 ]
  post 12 abc123 "$REPORT"; [ "$status" -eq 2 ]
  post 12 "$HEAD1"; [ "$status" -eq 2 ]
  post 12 "$HEAD1" "$REPORT" --force; [ "$status" -eq 2 ]
}

@test "address-pr SKILL.md calls review-state.sh and post-review.sh" {
  grep -q 'address-pr/scripts/review-state.sh' "$REPO_ROOT/address-pr/SKILL.md"
  grep -q 'address-pr/scripts/post-review.sh' "$REPO_ROOT/address-pr/SKILL.md"
}
