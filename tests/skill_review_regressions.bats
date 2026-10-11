#!/usr/bin/env bats
# Regression guards for the 2026-09-28 skill-review §1 prose bugs
# (T20261010-355951). Prose-only skills have no script to unit-test, so each
# case asserts the broken wording stays gone and the fixed contract stays in.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "drive: Phase 1.5 sets no EXIT trap (per-call shell would delete the clone)" {
  run grep -n "^trap 'rm -rf" "$REPO_ROOT/drive/SKILL.md"
  [ "$status" -ne 0 ]
  grep -q "No \`trap\` and no shell variables across calls" "$REPO_ROOT/drive/SKILL.md"
}

@test "slack: no SKILL.md prefixes SLACK_WEBHOOK_URL=\"\$SLACK_WEBHOOK_URL_<X>\" (expands before .env load)" {
  run grep -rEn 'SLACK_WEBHOOK_URL="\$SLACK_WEBHOOK_URL_' "$REPO_ROOT" --include=SKILL.md
  # the one allowed mention is slack/SKILL.md explaining why NOT to do it
  [ "$(printf '%s\n' "$output" | grep -vc '^'"$REPO_ROOT"'/slack/SKILL.md')" -eq 0 ]
}

@test "autopilot: WAITING is its own backed-off bucket, not Progress" {
  grep -q '^- \*\*Waiting\*\*' "$REPO_ROOT/autopilot/SKILL.md"
  grep -q 'waiting_count' "$REPO_ROOT/autopilot/SKILL.md"
  run grep -n 'resolves \*\*without further `/drive` action\*\*' "$REPO_ROOT/autopilot/SKILL.md"
  [ "$status" -ne 0 ]
}

@test "top: --before processes the expanded list forward (blocker stays ahead of its task)" {
  block="$(sed -n '/^\*\*`--before` mode\.\*\*/,/^### 4\./p' "$REPO_ROOT/top/SKILL.md")"
  [[ "$block" == *"for id in expanded_id_list"* ]]
  [[ "$block" != *"for id in reversed"* ]]
}

@test "incept: never runs a --fix lint, scoped paths only" {
  run grep -n -- '--fix' "$REPO_ROOT/incept/SKILL.md"
  [ "$status" -ne 0 ]
}

@test "gcpr: no hardcoded model in the Co-Authored-By trailer; Review flip precedes the commit" {
  run grep -n 'Co-Authored-By: Claude Opus' "$REPO_ROOT/gcpr/SKILL.md"
  [ "$status" -ne 0 ]
  grep -q 'before Step 4, not here' "$REPO_ROOT/gcpr/SKILL.md"
}

@test "rca + labrun-rca: delegated RCA does not also post to the channel root" {
  grep -q -- '--no-post' "$REPO_ROOT/rca/SKILL.md"
  grep -q -- '/rca <run-id> --no-post' "$REPO_ROOT/labrun-rca/SKILL.md"
}

@test "email-triage: read-only is a policy, not a claim about the connector" {
  run grep -n 'connector is read-only' "$REPO_ROOT/email-triage/SKILL.md"
  [ "$status" -ne 0 ]
  grep -q 'by policy' "$REPO_ROOT/email-triage/SKILL.md"
}
