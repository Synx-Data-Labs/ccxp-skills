#!/usr/bin/env bats
# Tests for address-pr/scripts/has-lgtm.sh (T20261012-255195).
#
# Pure decision tests use --from-json (normalized input); one hermetic
# live-path test overrides GH_SH with a stub (no network).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/address-pr/scripts/has-lgtm.sh"

# mk <comments-json-array> — writes normalized input; pushedAt is 10:00.
mk() {
  printf '{"author":"alice","pushedAt":"2026-10-12T10:00:00Z","comments":%s}' "$1" \
    > "$BATS_TEST_TMPDIR/in.json"
}

# c <login> <iso-time> <body> — one comment object.
c() { jq -nc --arg l "$1" --arg t "$2" --arg b "$3" '{login:$l,createdAt:$t,body:$b}'; }

go() { run bash "$SCRIPT" --from-json "$BATS_TEST_TMPDIR/in.json"; }

@test "author LGTM after push qualifies and prints the login" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "case-insensitive and punctuation tolerated" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'lgtm!')]"
  go
  [ "$status" -eq 0 ]
}

@test "short thanks tail tolerated" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM, thanks')]"
  go
  [ "$status" -eq 0 ]
}

@test "LGTM on first non-empty line with more text below qualifies" {
  mk "[$(c alice 2026-10-12T11:00:00Z $'\n\nLGTM\n\nsee you Monday')]"
  go
  [ "$status" -eq 0 ]
}

@test "non-author LGTM does not count" {
  mk "[$(c bob 2026-10-12T11:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "bot LGTM does not count" {
  mk '[{"login":"alice[bot]","createdAt":"2026-10-12T11:00:00Z","body":"LGTM"}]'
  jq '.author="alice[bot]"' "$BATS_TEST_TMPDIR/in.json" > "$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$BATS_TEST_TMPDIR/in.json"
  go
  [ "$status" -eq 1 ]
}

@test "the Claude Code review comment never counts even if it starts like LGTM" {
  mk "[$(c alice 2026-10-12T11:00:00Z $'**Claude Code review:** (sha: abc)\nLGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "LGTM before the latest push is stale" {
  mk "[$(c alice 2026-10-12T09:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "LGTM at the exact push instant is stale (strictly after required)" {
  mk "[$(c alice 2026-10-12T10:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "LGTM but ... does not count" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM but fix the typo first')]"
  go
  [ "$status" -eq 1 ]
}

@test "not LGTM does not count" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'not LGTM yet')]"
  go
  [ "$status" -eq 1 ]
}

@test "quoted reply does not count" {
  mk "[$(c alice 2026-10-12T11:00:00Z '> LGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "fenced code block does not count" {
  mk "[$(c alice 2026-10-12T11:00:00Z $'```\nLGTM\n```')]"
  go
  [ "$status" -eq 1 ]
}

@test "LGTM only in a later line does not count" {
  mk "[$(c alice 2026-10-12T11:00:00Z $'Thoughts:\nLGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "later hold revokes an earlier LGTM" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM'),$(c alice 2026-10-12T12:00:00Z 'hold on, do not merge')]"
  go
  [ "$status" -eq 1 ]
}

@test "later changes requested revokes" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM'),$(c alice 2026-10-12T12:00:00Z 'changes requested: rename it')]"
  go
  [ "$status" -eq 1 ]
}

@test "LGTM after a hold re-qualifies" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'hold'),$(c alice 2026-10-12T12:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 0 ]
}

@test "a hold before the push is irrelevant, the later LGTM stands" {
  mk "[$(c alice 2026-10-12T08:00:00Z 'hold'),$(c alice 2026-10-12T11:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 0 ]
}

@test "ordering is by timestamp, not array order" {
  mk "[$(c alice 2026-10-12T12:00:00Z 'hold'),$(c alice 2026-10-12T11:00:00Z 'LGTM')]"
  go
  [ "$status" -eq 1 ]
}

@test "unrelated author chatter between does not revoke" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM'),$(c alice 2026-10-12T12:00:00Z 'thanks for the review')]"
  go
  [ "$status" -eq 0 ]
}

@test "no comments is a plain no" {
  mk '[]'
  go
  [ "$status" -eq 1 ]
}

@test "missing or malformed input is a fail-safe error" {
  run bash "$SCRIPT" --from-json "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
  echo 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  run bash "$SCRIPT" --from-json "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
}

@test "no argument is a usage error" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "live path: normalizes issue comments, reviews and review comments via GH_SH" {
  cat > "$BATS_TEST_TMPDIR/gh-stub.sh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view 7 --json author,commits,comments,reviews")
    cat <<'JSON'
{"author":{"login":"alice"},
 "commits":[{"committedDate":"2026-10-12T09:00:00Z"},{"committedDate":"2026-10-12T10:00:00Z"}],
 "comments":[{"author":{"login":"alice"},"body":"nice","createdAt":"2026-10-12T10:30:00Z"}],
 "reviews":[{"author":{"login":"alice"},"body":"LGTM","submittedAt":"2026-10-12T11:00:00Z"}]}
JSON
    ;;
  "api --paginate repos/{owner}/{repo}/pulls/7/comments?per_page=100")
    echo '[{"user":{"login":"alice"},"body":"hold","created_at":"2026-10-12T10:45:00Z"}]' ;;
  "api --paginate repos/{owner}/{repo}/issues/7/timeline?per_page=100")
    echo '[{"event":"head_ref_force_pushed","created_at":"2026-10-12T10:50:00Z"}]' ;;
  *) echo "unhandled: $*" >&2; exit 1 ;;
esac
STUB
  run env GH_SH="$BATS_TEST_TMPDIR/gh-stub.sh" bash "$SCRIPT" 7
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "--after raises the lower bound (LGTM must postdate our pushback)" {
  mk "[$(c alice 2026-10-12T11:00:00Z 'LGTM')]"
  run bash "$SCRIPT" --from-json "$BATS_TEST_TMPDIR/in.json" --after 2026-10-12T11:30:00Z
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" --from-json "$BATS_TEST_TMPDIR/in.json" --after 2026-10-12T10:30:00Z
  [ "$status" -eq 0 ]
}

@test "app/ bot author never counts" {
  printf '{"author":"app/x","pushedAt":"2026-10-12T10:00:00Z","comments":[{"login":"app/x","createdAt":"2026-10-12T11:00:00Z","body":"LGTM"}]}' > "$BATS_TEST_TMPDIR/in.json"
  go
  [ "$status" -eq 1 ]
}

@test "missing author is a fail-safe error" {
  echo '{"pushedAt":"2026-10-12T10:00:00Z","comments":[]}' > "$BATS_TEST_TMPDIR/in.json"
  go
  [ "$status" -eq 2 ]
}
