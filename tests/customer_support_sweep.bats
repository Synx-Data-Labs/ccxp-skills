#!/usr/bin/env bats
# Tests for customer-support/scripts/sweep.sh + `transition.sh autoclose`
# (T20261021-266225): the delivered-timeout. All gh I/O is a fake via CS_GH;
# CS_NOW pins the clock. No real issue is touched.

load test_helper
setup() {
  SWEEP="$REPO_ROOT/customer-support/scripts/sweep.sh"
  TRANS="$REPO_ROOT/customer-support/scripts/transition.sh"
  source "$REPO_ROOT/customer-support/scripts/label_names.sh"
  cd "$BATS_TEST_TMPDIR"
  export CS_GH="$BATS_TEST_TMPDIR/gh-stub.sh"
  export CS_NOW
  CS_NOW=$(jq -n '"2026-10-20T00:00:00Z" | fromdateiso8601')
  cat > gh-stub.sh <<'STUB'
#!/usr/bin/env bash
echo "$*" >> gh-calls.log
if [[ "$1" == "api" ]]; then
  n=$(sed -E 's#.*issues/([0-9]+)/timeline.*#\1#' <<<"$*")
  cat "tl-$n.json"
elif [[ "$1" == "issue" && "$2" == "list" ]]; then
  cat list.json
elif [[ "$1" == "issue" && "$2" == "view" ]]; then
  n="$3"
  jq -c '{labels: [.[] | select(.number=='"$n"') | .labels[]]}' list.json
fi
STUB
  chmod +x gh-stub.sh
}

# _issue <n> <labels-csv> <timeline-json>
_issue() {
  local n="$1" labels="$2" tl="$3" arr
  arr=$(jq -nc --arg l "$labels" '$l | split(",") | map({name: .})')
  [[ -f list.json ]] || echo '[]' > list.json
  jq -c --argjson n "$n" --argjson l "$arr" '. + [{number: $n, labels: $l}]' list.json > list.tmp && mv list.tmp list.json
  echo "$tl" > "tl-$n.json"
}

_labeled() { echo "{\"event\":\"labeled\",\"label\":{\"name\":\"$CS_L_DELIVERED\"},\"actor\":{\"login\":\"${2:-eng}\"},\"created_at\":\"$1\"}"; }
_comment() { echo "{\"event\":\"commented\",\"actor\":{\"login\":\"$1\"},\"created_at\":\"$2\",\"body\":\"${3:-hi}\"}"; }

@test "old delivered issue is eligible: dry-run reports WOULD CLOSE and writes nothing" {
  _issue 30 "delivered,severity:2" "[$(_labeled 2026-10-01T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support
  [ "$status" -eq 0 ]
  [[ "$output" == *"#30: WOULD CLOSE (delivered 19d ago)"* ]]
  [[ "$output" == *"dry-run"* ]]
  run cat gh-calls.log
  [[ "$output" != *"issue close"* ]]
  [[ "$output" != *"issue comment"* ]]
  [[ "$output" != *"issue edit"* ]]
}

@test "too young (13d) is skipped; --days overrides the threshold" {
  _issue 31 "delivered" "[$(_labeled 2026-10-07T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#31: SKIP too young (13d < 14d)"* ]]
  run bash "$SWEEP" acme/synxdb-support --days 7
  [[ "$output" == *"#31: WOULD CLOSE"* ]]
}

@test "--days below 1 is rejected" {
  run bash "$SWEEP" acme/synxdb-support --days 0
  [ "$status" -eq 2 ]
  run bash "$SWEEP" acme/synxdb-support --days abc
  [ "$status" -eq 2 ]
}

@test "blocked and needs-upstream issues are skipped" {
  # Dirty issues carrying a stale stacked blocked/needs-upstream next to delivered.
  _issue 1 "${CS_L_DELIVERED},${CS_L_BLOCKED}" "[$(_labeled 2026-09-01T00:00:00Z)]"
  _issue 2 "${CS_L_DELIVERED},${CS_L_NEEDS_UPSTREAM}" "[$(_labeled 2026-09-01T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#1: SKIP ${CS_L_BLOCKED}"* ]]
  [[ "$output" == *"#2: SKIP ${CS_L_NEEDS_UPSTREAM}"* ]]
  [[ "$output" != *"WOULD CLOSE (delivered"* ]]
}

@test "a comment by someone other than the delivering account flags it for a human" {
  _issue 3 "delivered" "[$(_labeled 2026-10-01T00:00:00Z eng),$(_comment customer 2026-10-05T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#3: FLAG needs human: comment by customer after delivery"* ]]
  [[ "$output" == *"1 flagged"* ]]
}

@test "comments by the delivering account (and our own marker) do not block the close" {
  _issue 4 "delivered" "[$(_labeled 2026-10-01T00:00:00Z eng),$(_comment eng 2026-10-02T00:00:00Z),$(_comment bot 2026-10-03T00:00:00Z '<!-- cs-autoclose -->')]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#4: WOULD CLOSE"* ]]
}

@test "a comment BEFORE the delivered label is ignored; the last labeled event sets the clock" {
  _issue 5 "delivered" "[$(_comment customer 2026-09-01T00:00:00Z),$(_labeled 2026-09-05T00:00:00Z),$(_labeled 2026-10-15T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#5: SKIP too young (5d < 14d)"* ]]
}

@test "reopened after delivery is flagged, not re-closed" {
  _issue 6 "delivered" "[$(_labeled 2026-10-01T00:00:00Z),{\"event\":\"reopened\",\"actor\":{\"login\":\"support\"},\"created_at\":\"2026-10-10T00:00:00Z\"}]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#6: FLAG needs human: reopened after delivery"* ]]
}

@test "paginated (--slurp) timeline output is flattened" {
  _issue 7 "delivered" "[[$(_labeled 2026-10-01T00:00:00Z)],[$(_comment customer 2026-10-05T00:00:00Z)]]"
  run bash "$SWEEP" acme/synxdb-support
  [[ "$output" == *"#7: FLAG"* ]]
}

@test "--apply goes through transition.sh autoclose: comment (marked) then close, delivered kept" {
  _issue 30 "delivered" "[$(_labeled 2026-10-01T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"#30: CLOSED"* ]]
  run cat gh-calls.log
  [[ "$output" == *"issue comment 30"*"Auto-closed (not accepted)"*"NOT an acceptance"*"reopen"* ]]
  [[ "$output" == *"<!-- cs-autoclose -->"* ]]
  [[ "$output" == *"issue close 30 --repo acme/synxdb-support --reason completed"* ]]
  [[ "$output" != *"--remove-label"* ]]
  c=$(grep -n "issue comment 30" gh-calls.log | head -1 | cut -d: -f1)
  x=$(grep -n "issue close 30" gh-calls.log | head -1 | cut -d: -f1)
  [ "$c" -lt "$x" ]
}

@test "autoclose is idempotent on retry: marker already present skips the comment" {
  _issue 8 "delivered" "[$(_labeled 2026-10-01T00:00:00Z),$(_comment bot 2026-10-20T00:00:00Z '<!-- cs-autoclose -->')]"
  run bash "$TRANS" autoclose acme/synxdb-support 8
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" != *"issue comment"* ]]
  [[ "$output" == *"issue close 8"* ]]
}

@test "direct transition.sh autoclose re-verifies: too young is refused, nothing written" {
  _issue 9 "delivered" "[$(_labeled 2026-10-19T00:00:00Z)]"
  run bash "$TRANS" autoclose acme/synxdb-support 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"* ]]
  run cat gh-calls.log
  [[ "$output" != *"issue close"* ]]
  [[ "$output" != *"issue comment"* ]]
}

@test "direct autoclose refuses --days 0, a foreign comment, and a non-delivered issue" {
  _issue 10 "delivered" "[$(_labeled 2026-10-19T00:00:00Z)]"
  run bash "$TRANS" autoclose acme/synxdb-support 10 --days 0
  [ "$status" -ne 0 ]
  _issue 11 "delivered" "[$(_labeled 2026-10-01T00:00:00Z),$(_comment customer 2026-10-05T00:00:00Z)]"
  run bash "$TRANS" autoclose acme/synxdb-support 11
  [ "$status" -eq 1 ]
  _issue 12 "in-progress" "[]"
  run bash "$TRANS" autoclose acme/synxdb-support 12
  [ "$status" -eq 1 ]
  run cat gh-calls.log
  [[ "$output" != *"issue close"* ]]
}

@test "accept stays identity-gated (autoclose did not weaken it)" {
  _issue 13 "delivered" "[$(_labeled 2026-10-01T00:00:00Z)]"
  run bash "$TRANS" accept acme/synxdb-support 13 --actor eng --allowed "support1,support2"
  [ "$status" -ne 0 ]
  run cat gh-calls.log
  [[ "$output" != *"issue close"* ]]
}

@test "a second dry-run after the issue is closed lists nothing (closed issues are not in the open list)" {
  echo '[]' > list.json
  run bash "$SWEEP" acme/synxdb-support
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 would close"* ]]
}

@test "marker from an EARLIER delivery cycle does not suppress the comment on a second timeout" {
  _issue 14 "delivered" "[$(_labeled 2026-08-01T00:00:00Z),$(_comment bot 2026-08-20T00:00:00Z '<!-- cs-autoclose -->'),$(_labeled 2026-10-01T00:00:00Z)]"
  run bash "$TRANS" autoclose acme/synxdb-support 14
  [ "$status" -eq 0 ]
  run cat gh-calls.log
  [[ "$output" == *"issue comment 14"* ]]
}

@test "--days with a leading zero is normalised, not an octal error" {
  _issue 15 "delivered" "[$(_labeled 2026-10-01T00:00:00Z)]"
  run bash "$SWEEP" acme/synxdb-support --days 08
  [ "$status" -eq 0 ]
  [[ "$output" == *"#15: WOULD CLOSE"* ]]
}

@test "sweep finds a delivered issue under the new name and the old alias alike (status:delivered / delivered)" {
  _issue 40 "$CS_L_DELIVERED" "[$(_labeled 2026-10-01T00:00:00Z)]"
  _issue 41 "delivered" "[$(_labeled 2026-10-01T00:00:00Z)]"
  _issue 42 "$CS_L_TRIAGED" "[]"
  run bash "$SWEEP" acme/synxdb-support
  [ "$status" -eq 0 ]
  [[ "$output" == *"#40: WOULD CLOSE"* ]]
  [[ "$output" == *"#41: WOULD CLOSE"* ]]
  [[ "$output" != *"#42"* ]]
}
