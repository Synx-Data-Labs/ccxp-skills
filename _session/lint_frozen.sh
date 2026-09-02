#!/usr/bin/env bash
# _session/lint_frozen.sh — probe whether a task file's CURRENT (unedited)
# frontmatter is "lint-frozen": it already fails the changed-mode
# `lint_tasks.py` check, so ANY frontmatter edit on it (a /drive claim, a close,
# an IPM `scheduled:` bump) would fail the whole-file `Lint task frontmatter`
# check until the maintainer-owned schema fork (T20260626-353630) lands.
#
# Used by:
#   - /todo next  (step 4 "Exclude") — drop frozen candidates from the ranking,
#     so the picker never recommends a task /drive could only abandon at claim
#     time (the wasted-claim-cycle class — see T20260629-185057, PR #1812).
#   - /drive      (Phase 1 claim guard) — refuse to open an un-mergeable claim PR
#     for a frozen task (backstop for the explicit-id path that skips /todo next).
#
# This is the PICK-PATH ANALOGUE of the IPM drain-gate exemption
# (_ipm_drain_is_lint_frozen, build-pipeline-repo T20260628-951477) — SAME
# probe primitive (`lint_tasks.py --changed`), OPPOSITE fail-safe:
#
#   CONTRACT — lint_frozen_is_frozen <task-file> [repo-path]
#     return 0 = FROZEN     → exclude from picker / refuse claim
#     return 1 = CLAIMABLE  → lint-clean, OR unclassifiable (no file, no linter,
#                             no verdict line). The pick-path safe default is
#                             CLAIMABLE — never hide pickable work. (The drain
#                             gate's safe default is the opposite — BLOCKING —
#                             so it never silently drains an item off a closing
#                             iteration.)
#
# Test hook: LINT_FROZEN_IDS (whitespace-separated task IDs) short-circuits the
# real lint with an explicit frozen set, so BATS stays hermetic (no task files,
# no python) — mirrors the drain gate's IPM_DRAIN_FROZEN_IDS.
#
# Interim only — the durable fix is T20260626-353630 (relax the lint_tasks.py
# estimation grammar + allowlist the load-bearing fields). Once it lands the
# frozen set empties and every probe returns CLAIMABLE; keep this helper anyway
# (cheap, and it guards against future schema drift).

set -uo pipefail

# Path to the frontmatter linter (override via LINT_TASKS_PY for tests /
# non-default checkouts — e.g. CI, where ~/.claude/skills does not exist).
_lint_frozen_lint_tasks_py() {
  printf '%s\n' "${LINT_TASKS_PY:-${HOME}/.claude/skills/repo-conventions/scripts/lint_tasks.py}"
}

# Extract a T<8>-<6> task id from a path or string; empty if none.
_lint_frozen_task_id() {
  printf '%s\n' "${1:-}" | sed -n 's/.*\(T[0-9]\{8\}-[0-9]\{6\}\).*/\1/p' | head -1
}

# lint_frozen_is_frozen <task-file> [repo-path]
#   return 0 = FROZEN ; return 1 = CLAIMABLE (clean OR unclassifiable: fail-safe)
lint_frozen_is_frozen() {
  local file="${1:-}" repo_path="${2:-.}" tid lint out base verdict_line

  # Test injection: an explicit frozen set short-circuits the real lint so BATS
  # stays hermetic (no task files, no python).
  if [ -n "${LINT_FROZEN_IDS:-}" ]; then
    tid="$(_lint_frozen_task_id "$file")"
    [ -n "$tid" ] || return 1                      # no id ⇒ claimable (fail-safe)
    case " ${LINT_FROZEN_IDS} " in
      *" ${tid} "*) return 0 ;;                    # listed ⇒ frozen
      *)            return 1 ;;                    # not listed ⇒ claimable
    esac
  fi

  [ -n "$file" ] && [ -f "$file" ] || return 1     # no file ⇒ claimable (fail-safe)
  lint="$(_lint_frozen_lint_tasks_py)"
  [ -f "$lint" ] || return 1                       # no linter ⇒ claimable (fail-safe)

  out="$(python3 "$lint" --changed "$file" "$repo_path" 2>/dev/null)" || true
  base="$(basename "$file")"
  # lint_tasks.py prints a per-file verdict line ("✅ <path>" / "❌ <path>") then
  # indented reason lines. Read THIS file's own verdict (the drain-gate-proven
  # approach) so a multi-file lint context can't mis-attribute a verdict.
  verdict_line="$(printf '%s\n' "$out" | grep -F "$base" | head -1)"
  [ -n "$verdict_line" ] || return 1               # no verdict ⇒ claimable (fail-safe)
  case "$verdict_line" in
    *"❌"*) return 0 ;;                            # ❌ ⇒ frozen
    *)      return 1 ;;                            # ✅ / anything else ⇒ claimable
  esac
}

_lint_frozen_usage() {
  printf 'usage: lint_frozen.sh is-frozen <task-file> [repo-path]\n' >&2
  printf '  exit 0 = frozen (exclude/refuse claim), 1 = claimable\n' >&2
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    is-frozen) shift; lint_frozen_is_frozen "$@" ;;
    -h|--help) _lint_frozen_usage ;;
    *)         _lint_frozen_usage; exit 64 ;;
  esac
fi
