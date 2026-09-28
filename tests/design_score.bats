#!/usr/bin/env bats
# Tests for design-score/scripts/score.sh — the deterministic design-doc scorer
# that gates /focus Phase 2 → Phase 3 (T20260609-204303 D3).
#
# The scorer reads a task/design file written against
# repo-conventions/templates/design-doc.md and emits a 0–100 score with a
# per-check breakdown, exiting 0 iff score >= threshold (default 70).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCORE="$REPO_ROOT/design-score/scripts/score.sh"
FIX="$SCRIPT_DIR/fixtures/design-score"

# Extract the integer score from a --json run's output.
json_score() {
  jq -r '.score' <<<"$1"
}

@test "score.sh exists and is executable-by-bash" {
  [ -f "$SCRIPT_DIR/../design-score/scripts/score.sh" ]
}

@test "complete code-class design PASSES (score >= 85, exit 0)" {
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$status" -eq 0 ]
  local score
  score="$(json_score "$output")"
  [ "$score" -ge 85 ]
  [ "$(jq -r '.pass' <<<"$output")" = "true" ]
  [ "$(jq -r '.kind' <<<"$output")" = "code" ]
}

@test "complete design auto-detects as code-class (has Root cause / code paths)" {
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' <<<"$output")" = "code" ]
}

@test "poor design FAILS (score < 70, exit 1)" {
  run bash "$SCORE" "$FIX/poor.md" --json
  [ "$status" -eq 1 ]
  local score
  score="$(json_score "$output")"
  [ "$score" -lt 70 ]
  [ "$(jq -r '.pass' <<<"$output")" = "false" ]
}

@test "human-readable output shows a per-check breakdown and a total" {
  run bash "$SCORE" "$FIX/complete.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"C1"* ]]
  [[ "$output" == *"C7"* ]]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"Total"* || "$output" == *"TOTAL"* ]]
}

@test "removing alternatives-rejected docks ~6 (C7)" {
  run bash "$SCORE" "$FIX/complete.md" --json
  local with_alt
  with_alt="$(json_score "$output")"

  # Strip the alternatives-rejected block from the Plan section.
  local stripped="$BATS_TEST_TMPDIR/no_alt.md"
  grep -v -i -e 'alternatives considered and rejected' \
            -e 'rejected:' \
            -e 'reject' "$FIX/complete.md" > "$stripped"
  run bash "$SCORE" "$stripped" --json
  local without_alt
  without_alt="$(json_score "$output")"

  local delta=$(( with_alt - without_alt ))
  [ "$delta" -ge 5 ]
  [ "$delta" -le 8 ]
}

@test "C7 contributes exactly 6 when alternatives-rejected is present" {
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checks.C7' <<<"$output")" -eq 6 ]
}

@test "docs-class clean fixture PASSES with full code-only credit" {
  run bash "$SCORE" "$FIX/docs_clean.md" --kind docs --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' <<<"$output")" = "docs" ]
  [ "$(jq -r '.checks.C3' <<<"$output")" -eq 10 ]
  local score
  score="$(json_score "$output")"
  [ "$score" -ge 85 ]
}

@test "docs-class with stubbed code-only sections gets the padding penalty" {
  run bash "$SCORE" "$FIX/docs_clean.md" --kind docs --json
  local clean
  clean="$(json_score "$output")"

  run bash "$SCORE" "$FIX/docs_padded.md" --kind docs --json
  local padded
  padded="$(json_score "$output")"

  # Padding deducts 5 on C3 (code-only stubs in a docs task).
  [ "$(jq -r '.checks.C3' <<<"$output")" -eq 5 ]
  [ "$padded" -lt "$clean" ]
  local dock=$(( clean - padded ))
  [ "$dock" -ge 5 ]
}

@test "--kind override forces classification (code over auto docs)" {
  # docs_clean would auto-detect docs; --kind code forces code-class scoring,
  # which costs C3 (no Root cause / Repo file references present).
  run bash "$SCORE" "$FIX/docs_clean.md" --kind code --json
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ "$(jq -r '.kind' <<<"$output")" = "code" ]
  [ "$(jq -r '.checks.C3' <<<"$output")" -eq 0 ]
}

@test "--threshold changes the pass/fail boundary" {
  # poor.md is well under 70; with a very low threshold it should pass.
  run bash "$SCORE" "$FIX/poor.md" --threshold 5 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.threshold' <<<"$output")" -eq 5 ]
  [ "$(jq -r '.pass' <<<"$output")" = "true" ]

  # complete.md is well above 70; an impossible threshold should fail it.
  run bash "$SCORE" "$FIX/complete.md" --threshold 101 --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.pass' <<<"$output")" = "false" ]
}

@test "placeholder text (TODO) incurs a penalty" {
  # poor.md contains a TODO; assert the placeholder check reports a negative dock.
  run bash "$SCORE" "$FIX/poor.md" --json
  local pen
  pen="$(jq -r '.checks.placeholder' <<<"$output")"
  [ "$pen" -lt 0 ]
}

@test "placeholders inside fenced code blocks are NOT penalized" {
  # complete.md has a fenced reproduction block; it should carry no placeholder
  # penalty (no TBD/TODO/FIXME outside code/comments).
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$(jq -r '.checks.placeholder' <<<"$output")" -eq 0 ]
}

@test "placeholder tokens inside inline-code spans are NOT penalized" {
  # A doc that DISCUSSES the markers (TODO/FIXME/TBD/???/<...>) inside `inline
  # code` must not be docked — only real placeholders in prose count. Without the
  # inline-code-span exclusion these tokens leak into the prose scan.
  run bash "$SCORE" "$FIX/inline_code_placeholders.md" --json
  [ "$(jq -r '.checks.placeholder' <<<"$output")" -eq 0 ]
}

@test "frontmatter completeness: complete fixture earns full C1 (20)" {
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$(jq -r '.checks.C1' <<<"$output")" -eq 20 ]
}

@test "frontmatter: bare priority (no rationale) and missing related dock C1" {
  # poor.md has a bare 'P2' priority and no 'related:' field.
  run bash "$SCORE" "$FIX/poor.md" --json
  local c1
  c1="$(jq -r '.checks.C1' <<<"$output")"
  [ "$c1" -lt 20 ]
}

@test "done-criteria mapping: complete fixture maps all items (C5 = 16)" {
  run bash "$SCORE" "$FIX/complete.md" --json
  [ "$(jq -r '.checks.C5' <<<"$output")" -eq 16 ]
}

@test "missing file errors cleanly with non-zero exit" {
  run bash "$SCORE" "$FIX/does-not-exist.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* || "$output" == *"No such"* || "$output" == *"Error"* ]]
}

@test "no arguments prints usage and exits non-zero" {
  run bash "$SCORE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

@test "JSON output is well-formed and carries all required keys" {
  run bash "$SCORE" "$FIX/complete.md" --json
  run jq -e '.score, .threshold, .pass, .kind, .checks' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "score.sh is sourceable without executing its main (function-wrapped)" {
  run bash -c "source '$SCORE'; type design-score >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
