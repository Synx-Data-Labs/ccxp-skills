#!/usr/bin/env bash
# ci-triage.sh <run-id-or-url> [--context N] — compact CI-failure summary
# (T20260719-204917, Factor 9 "compact errors into the context window").
#
# Replaces the hand-rolled `grep -iE "error:|Error [0-9]|##\[error\]"` pattern
# repeated verbatim across this session (T20260718-206307's gpbackup failure,
# T20260629-281129's Phase 330 failures x2, the validate-manifest invariant
# failure) with ONE shared, tested tool. Reusable by /rca, /labrun-rca, and ad
# hoc manual debugging — /rca's own log-extraction step now delegates here.
#
# Pulls the run's failed jobs/steps via `gh run view --json jobs`, then pulls
# ONLY the failed-step log (`gh run view --log-failed` — already far smaller
# than the full multi-thousand-line log), then extracts a BOUNDED window
# around each error-pattern line (grep -C, which already merges overlapping
# windows and separates disjoint ones with `--`) instead of dumping the raw
# log. A hard line cap backstops runs with pathologically many matches.
#
# Usage:
#   bash ~/.claude/skills/_gh/ci-triage.sh 29670112823
#   bash ~/.claude/skills/_gh/ci-triage.sh https://github.com/OWNER/REPO/actions/runs/29670112823
#   bash ~/.claude/skills/_gh/ci-triage.sh 29670112823 --context 8
#
# Must run from the target repo's clone (gh resolves against $PWD's origin,
# same assumption as every other _gh/_session/_taskid script).

set -uo pipefail

# gh wrapper — DI seam via CI_TRIAGE_GH (tests inject a stub here), mirroring
# _taskid/url.sh's taskid-gh; defaults to the account-aware wrapper.
CI_TRIAGE_GH="${CI_TRIAGE_GH:-}"

ci_triage_gh() {
  if [ -n "$CI_TRIAGE_GH" ]; then
    "$CI_TRIAGE_GH" "$@"
  elif [ -x "$HOME/.claude/skills/_gh/gh.sh" ]; then
    bash "$HOME/.claude/skills/_gh/gh.sh" "$@"
  else
    gh "$@"
  fi
}

# --- pure helpers -------------------------------------------------------------

ci_triage_parse_run_id() {
  # $1 run-id-or-url → the numeric run id, or empty (+ nonzero) if unparseable.
  local input="${1:-}"
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    printf '%s' "$input"; return 0
  fi
  if [[ "$input" =~ /runs/([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"; return 0
  fi
  return 1
}

ci_triage_extract_windows() {
  # $1 log text  $2 context lines (default 5) → line-numbered context windows
  # around error-pattern matches, via `grep -C` (already merges overlapping
  # windows and separates disjoint groups with `--`) — not a hand-rolled
  # windowing reimplementation.
  local log="$1" ctx="${2:-5}"
  printf '%s\n' "$log" | grep -n -E -C "$ctx" \
    '##\[error\]|Error:|error:|FAILED|fatal:|not ok|make.*Error' || true
}

# --- job/step summary ----------------------------------------------------------

ci_triage_failed_jobs_json() {
  # $1 run-id → JSON array of {name, steps:[...]} for failed jobs, or "[]".
  local run_id="$1"
  ci_triage_gh run view "$run_id" --json jobs \
    --jq '[.jobs[] | select(.conclusion=="failure") | {name: .name, steps: [.steps[] | select(.conclusion=="failure") | .name]}]' \
    2>/dev/null || printf '[]'
}

ci_triage_render_jobs() {
  # $1 jobs-json → one line per failed job + its failed step names, or a
  # "(none found)" note. Falls back gracefully if python3 can't parse it.
  local json="$1"
  if [ -z "$json" ] || [ "$json" = "[]" ]; then
    printf '  (none found via gh api — run may not have failed, or jobs unavailable)\n'
    return 0
  fi
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    jobs = json.load(sys.stdin)
except Exception:
    jobs = []
if not jobs:
    print("  (none found via gh api)")
for j in jobs:
    steps = ", ".join(j.get("steps") or []) or "(no failed step recorded)"
    print("  - {}: {}".format(j.get("name", "?"), steps))
' 2>/dev/null || printf '  (jobs JSON present but unparseable)\n'
}

# --- main -----------------------------------------------------------------------

ci_triage_main() {
  local raw="${1:-}" ctx=5
  [ -n "$raw" ] || { echo "usage: ci-triage.sh <run-id-or-url> [--context N]" >&2; return 64; }
  shift || true
  if [ "${1:-}" = "--context" ] && [ -n "${2:-}" ]; then
    ctx="$2"
  fi

  local run_id
  run_id="$(ci_triage_parse_run_id "$raw")" || {
    echo "ci-triage: could not parse a run id from '$raw'" >&2
    return 2
  }

  printf 'CI triage: run %s\n' "$run_id"
  printf 'Failed jobs:\n'
  ci_triage_render_jobs "$(ci_triage_failed_jobs_json "$run_id")"

  local log
  log="$(ci_triage_gh run view "$run_id" --log-failed 2>/dev/null)" || log=""
  if [ -z "$log" ]; then
    printf '\n(no failed-step log available)\n'
    return 0
  fi

  local windows
  windows="$(ci_triage_extract_windows "$log" "$ctx")"
  if [ -z "$windows" ]; then
    printf '\n(no error-pattern lines found in the failed-step log)\n'
    return 0
  fi

  local total cap=200
  total="$(printf '%s\n' "$windows" | grep -c .)"
  printf '\nError context (+/-%s lines around matches):\n' "$ctx"
  if [ "${total:-0}" -gt "$cap" ] 2>/dev/null; then
    printf '%s\n' "$windows" | head -n "$cap"
    printf '... [truncated: %s of %s lines shown]\n' "$cap" "$total"
  else
    printf '%s\n' "$windows"
  fi
  return 0
}

# Run only when executed directly (not when sourced — tests source this).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ci_triage_main "$@"
fi
