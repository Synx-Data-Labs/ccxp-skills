#!/usr/bin/env bats
# Tests for address-pr/scripts/auto-pick.sh (T20260919-266165).
#
# Hermetic: GH_SH and TASK_CLAIM_SH are overridden to fixture stub scripts
# under $BATS_TEST_TMPDIR — no real gh/network calls, no real task_claim.sh
# invocation. Each test writes its own stub pair so the PR list and the
# per-PR ownership verdicts are fully controlled.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/address-pr/scripts/auto-pick.sh"

setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
}

# Write a gh-stub that answers `pr list --author @me --state open --json
# number,title,createdAt --jq 'sort_by(.createdAt)'` with the given JSON
# array (already sorted oldest-first, as the real jq filter would produce).
write_gh_stub() {
  local json="$1"
  cat > "$fakebin/gh-stub.sh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "pr list --author @me --state open --json number,title,createdAt --jq sort_by(.createdAt)")
    cat <<'JSON'
$json
JSON
    ;;
  *)
    echo "unhandled gh-stub invocation: \$*" >&2
    exit 1 ;;
esac
STUB
  chmod +x "$fakebin/gh-stub.sh"
}

# Write a task_claim-stub that answers `pr-owner <n>` per a map of
# "number:verdict" pairs, e.g. "1:owned:other 2:mine".
write_claim_stub() {
  local map="$1"
  cat > "$fakebin/claim-stub.sh" <<STUB
#!/usr/bin/env bash
if [ "\$1" != "pr-owner" ]; then
  echo "unhandled claim-stub invocation: \$*" >&2
  exit 1
fi
case "\$2" in
STUB
  local pair num verdict
  for pair in $map; do
    num="${pair%%:*}"
    verdict="${pair#*:}"
    printf '  %s) echo "%s" ;;\n' "$num" "$verdict" >> "$fakebin/claim-stub.sh"
  done
  cat >> "$fakebin/claim-stub.sh" <<'STUB'
  *) echo "unknown" ;;
esac
STUB
  chmod +x "$fakebin/claim-stub.sh"
}

run_auto_pick() {
  run env GH_SH="$fakebin/gh-stub.sh" TASK_CLAIM_SH="$fakebin/claim-stub.sh" bash "$SCRIPT"
}

# Skipped-candidate diagnostics go to stderr by design (stdout stays
# machine-parseable). Redirect stderr *inside* a plain shell function (a
# real redirection bash parses at this point, before bats' own `run`
# merges 2>&1 around whatever it's given) instead of `run --separate-stderr`
# — same portability rationale, and the same pattern, as
# tests/claim_gap.bats's `_cgc_stdout_only`.
_auto_pick_stdout_only() {
  env GH_SH="$fakebin/gh-stub.sh" TASK_CLAIM_SH="$fakebin/claim-stub.sh" bash "$SCRIPT" 2>/dev/null
}

run_auto_pick_stdout_only() {
  run _auto_pick_stdout_only
}

@test "picks the 2nd-oldest when the oldest is owned:<other>" {
  write_gh_stub '[{"number":1,"title":"oldest","createdAt":"2026-06-30T00:00:00Z"},{"number":2,"title":"2nd oldest","createdAt":"2026-07-01T00:00:00Z"}]'
  write_claim_stub "1:owned:Ed 2:mine"

  run_auto_pick
  [ "$status" -eq 0 ]
  [[ "$output" == *'"number":2'* ]]
  [[ "$output" == *'"reason":"mine"'* ]]
  [[ "$output" != *'"number":1'* ]]
}

@test "skips an unknown-verdict oldest PR the same as owned" {
  write_gh_stub '[{"number":1,"title":"flaky","createdAt":"2026-06-30T00:00:00Z"},{"number":2,"title":"free one","createdAt":"2026-07-01T00:00:00Z"}]'
  write_claim_stub "1:unknown 2:free"

  run_auto_pick
  [ "$status" -eq 0 ]
  [[ "$output" == *'"number":2'* ]]
}

@test "still picks the oldest when it is itself pickable (unchanged behavior)" {
  write_gh_stub '[{"number":5,"title":"mine already","createdAt":"2026-06-30T00:00:00Z"},{"number":6,"title":"also open","createdAt":"2026-07-01T00:00:00Z"}]'
  write_claim_stub "5:mine 6:free"

  run_auto_pick
  [ "$status" -eq 0 ]
  [[ "$output" == *'"number":5'* ]]
}

@test "defers (prints nothing on stdout, exit 0) when every open PR is owned by someone else" {
  write_gh_stub '[{"number":1,"title":"a","createdAt":"2026-06-30T00:00:00Z"},{"number":2,"title":"b","createdAt":"2026-07-01T00:00:00Z"}]'
  write_claim_stub "1:owned:Ed 2:owned:Sam"

  run_auto_pick_stdout_only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing, exit 0, when there are no open PRs (unchanged behavior)" {
  write_gh_stub '[]'
  write_claim_stub ""

  run_auto_pick
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "picks an untracked PR (no task mapping) ahead of a later owned one" {
  write_gh_stub '[{"number":10,"title":"no task link","createdAt":"2026-06-30T00:00:00Z"},{"number":11,"title":"owned","createdAt":"2026-07-01T00:00:00Z"}]'
  write_claim_stub "10:untracked 11:owned:Ed"

  run_auto_pick
  [ "$status" -eq 0 ]
  [[ "$output" == *'"number":10'* ]]
  [[ "$output" == *'"reason":"untracked"'* ]]
}

@test "default GH_SH/TASK_CLAIM_SH resolve to the real sibling scripts, not a hardcoded path" {
  ! grep -q '~/\.claude/skills' "$SCRIPT"
  grep -q '/\.\./\.\./_gh" && pwd)/gh\.sh' "$SCRIPT"
  grep -q '/\.\./\.\./_session" && pwd)/task_claim\.sh' "$SCRIPT"
}
