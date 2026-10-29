#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Denies plain file deletion (rm, unlink,
# find -delete / -exec rm, xargs rm) and points the agent at
# agent-pairing/scripts/trash.sh. Deletes whose targets all sit under /tmp,
# /private/tmp or $TMPDIR are allowed. The analysis lives in rm-guard.py.
#
# - Deny is a JSON permissionDecision "deny" on stdout (exit 0), like skill-ask.sh's "ask".
# - Fails OPEN: no python3, a crash or an unparsable command prints one line on
#   stderr and allows the call.
# - Escape hatch: CCXP_ALLOW_RM=1 in the environment of the Claude Code process.
set -uo pipefail

function rm-guard() {
  local dir out rc
  if [[ "${CCXP_ALLOW_RM:-}" == 1 ]]; then cat >/dev/null; return 0; fi
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! command -v python3 >/dev/null 2>&1; then
    cat >/dev/null
    echo "rm-guard: python3 not found; allowing the command" >&2
    return 0
  fi
  out="$(python3 -I "$dir/rm-guard.py")"; rc=$?
  if (( rc != 0 )); then
    echo "rm-guard: analyzer exited $rc; allowing the command" >&2
    return 0
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rm-guard "$@"
fi
