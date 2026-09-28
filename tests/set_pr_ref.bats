#!/usr/bin/env bats
# Tests for _session/set-pr-ref.sh — append "(<repo>#<num>)" to a task's
# issue title so the Project board shows the task->PR mapping.
#
# The pure logic (PR-ref parsing, suffix construction, the idempotency
# decision) lives in _session/_lib.sh and is tested directly by sourcing it.
# The GraphQL I/O (_session_find_issue_for_task / _session_update_issue_title)
# is integration surface — for the high-level session_append_pr_ref tests we
# stub those two functions so no network call fires.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # _lib.sh is a pure library (no dispatch block), so sourcing is side-effect-free.
  source "$REPO_ROOT/_session/_lib.sh"
}

# --- session_parse_pr_ref (pure) --------------------------------------------

@test "parse_pr_ref: short form ccxp-skills#35" {
  run session_parse_pr_ref "ccxp-skills#35"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ccxp-skills\t35')" ]
}

@test "parse_pr_ref: full PR URL" {
  run session_parse_pr_ref "https://github.com/your-org/ccxp-skills/pull/35"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ccxp-skills\t35')" ]
}

@test "parse_pr_ref: full PR URL with trailing path" {
  run session_parse_pr_ref "https://github.com/your-org/ccxp-skills/pull/35/files"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ccxp-skills\t35')" ]
}

@test "parse_pr_ref: owner/repo#num keeps only repo" {
  run session_parse_pr_ref "your-org/ccxp-skills#35"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ccxp-skills\t35')" ]
}

@test "parse_pr_ref: garbage -> non-zero, empty output" {
  run session_parse_pr_ref "not-a-ref"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "parse_pr_ref: bare #num (no repo) -> non-zero" {
  run session_parse_pr_ref "#35"
  [ "$status" -ne 0 ]
}

# --- session_pr_ref_suffix (pure) -------------------------------------------

@test "pr_ref_suffix: builds (repo#num) from short form" {
  run session_pr_ref_suffix "ccxp-skills#35"
  [ "$status" -eq 0 ]
  [ "$output" = "(ccxp-skills#35)" ]
}

@test "pr_ref_suffix: builds (repo#num) from URL" {
  run session_pr_ref_suffix "https://github.com/your-org/example-website.com/pull/59"
  [ "$status" -eq 0 ]
  [ "$output" = "(example-website.com#59)" ]
}

@test "pr_ref_suffix: garbage -> non-zero" {
  run session_pr_ref_suffix "garbage"
  [ "$status" -ne 0 ]
}

# --- session_append_pr_ref (gh I/O stubbed) ---------------------------------

@test "append_pr_ref: appends suffix when title lacks it" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'ISSUE_ID\tT20260510-285938: Append PR ref'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "ccxp-skills#35"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "T20260510-285938: Append PR ref (ccxp-skills#35)" ]
}

@test "append_pr_ref: idempotent — does not re-append when suffix present" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'ISSUE_ID\tT20260510-285938: Append PR ref (ccxp-skills#35)'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "ccxp-skills#35"
  [ "$status" -eq 0 ]
  # No update mutation should have been issued.
  [ ! -s "$CALLS" ]
}

@test "append_pr_ref: a different PR ref still appends (re-PR'd task)" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'ISSUE_ID\tT20260510-285938: Append PR ref (ccxp-skills#35)'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "ccxp-skills#36"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "T20260510-285938: Append PR ref (ccxp-skills#35) (ccxp-skills#36)" ]
}

@test "append_pr_ref: #3 is NOT a substring-hit inside a #35 title (paren delimits)" {
  # Regression guard: the idempotency check is *"(repo#num)"* — the closing
  # paren must keep (ccxp-skills#3) from matching ...(ccxp-skills#35), so #3
  # still appends rather than being silently swallowed as already-present.
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'ISSUE_ID\tT20260510-285938: Append PR ref (ccxp-skills#35)'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "ccxp-skills#3"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "T20260510-285938: Append PR ref (ccxp-skills#35) (ccxp-skills#3)" ]
}

@test "append_pr_ref: empty pr ref -> non-zero, no lookup" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'should-not-be-called\n' >> "$CALLS"; printf 'ISSUE_ID\tTitle'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" ""
  [ "$status" -ne 0 ]
  # Empty-ref guard fires before any issue lookup.
  [ ! -s "$CALLS" ]
}

@test "append_pr_ref: no matching issue -> non-zero, no mutation" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { return 1; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "ccxp-skills#35"
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "append_pr_ref: unparseable PR ref -> non-zero, no lookup" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  _session_find_issue_for_task() { printf 'should-not-be-called\n' >> "$CALLS"; printf 'ISSUE_ID\tTitle'; }
  _session_update_issue_title() { printf '%s\n' "$2" >> "$CALLS"; }
  run session_append_pr_ref "T20260510-285938" "garbage"
  [ "$status" -ne 0 ]
  # Parse fails before any issue lookup.
  [ ! -s "$CALLS" ]
}

@test "append_pr_ref: empty task id -> non-zero" {
  run session_append_pr_ref "" "ccxp-skills#35"
  [ "$status" -ne 0 ]
}

# --- _session_find_issue_for_task (only the two gh seams stubbed) ------------
# These drive the REAL matcher + pagination loop, stubbing only:
#   _session_resolve_project  -> set _SESSION_PROJECT_ID
#   _session_gh               -> echo a canned GraphQL JSON payload
# so the title-prefix selection (the silent-corruption risk) is covered.

@test "find_issue: colon-suffix title matches; longer-prefix sibling is skipped" {
  _session_resolve_project() { _SESSION_PROJECT_ID=PROJ; }
  _session_gh() {
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"id":"ISSUE_LONG","title":"T20260510-2859380: longer-id task"}},
  {"content":{"id":"ISSUE_MATCH","title":"T20260510-285938: the real task"}}
]}}}}
JSON
  }
  run _session_find_issue_for_task "T20260510-285938"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ISSUE_MATCH\tT20260510-285938: the real task')" ]
}

@test "find_issue: space-suffix title variant matches" {
  _session_resolve_project() { _SESSION_PROJECT_ID=PROJ; }
  _session_gh() {
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"id":"ISSUE_SP","title":"T20260510-285938 standalone-space title"}}
]}}}}
JSON
  }
  run _session_find_issue_for_task "T20260510-285938"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ISSUE_SP\tT20260510-285938 standalone-space title')" ]
}

@test "find_issue: prefix-collision-only page -> non-zero, empty (the guard)" {
  _session_resolve_project() { _SESSION_PROJECT_ID=PROJ; }
  _session_gh() {
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"id":"ISSUE_LONG","title":"T20260510-2859380: longer-id task"}}
]}}}}
JSON
  }
  run _session_find_issue_for_task "T20260510-285938"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "find_issue: no matching item -> non-zero, empty" {
  _session_resolve_project() { _SESSION_PROJECT_ID=PROJ; }
  _session_gh() {
    cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"id":"OTHER","title":"T20260101-000001: unrelated task"}}
]}}}}
JSON
  }
  run _session_find_issue_for_task "T20260510-285938"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "find_issue: match found on the second page (pagination + cursor)" {
  _session_resolve_project() { _SESSION_PROJECT_ID=PROJ; }
  _session_gh() {
    # The cursor value arrives as a standalone "cursor=..." arg only on page 2+.
    local a has_cursor=
    for a in "$@"; do case "$a" in cursor=*) has_cursor=1;; esac; done
    if [ -n "$has_cursor" ]; then
      cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"id":"ISSUE_P2","title":"T20260510-285938: found on page two"}}
]}}}}
JSON
    else
      cat <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},"nodes":[
  {"content":{"id":"OTHER","title":"T20260101-000001: unrelated"}}
]}}}}
JSON
    fi
  }
  run _session_find_issue_for_task "T20260510-285938"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ISSUE_P2\tT20260510-285938: found on page two')" ]
}
