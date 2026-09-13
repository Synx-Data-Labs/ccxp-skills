#!/usr/bin/env bash
# set-pr-ref.sh <task-id> <pr-url-or-shortform> — append "(<repo>#<num>)" to
# the task's issue title so the Project board surfaces the task->PR mapping at
# a glance. Project items are issue-backed, so this edits the issue title and
# the board inherits it.
#
#   set-pr-ref.sh T20260510-285938 https://github.com/your-org/ccxp-skills/pull/35
#   set-pr-ref.sh T20260510-285938 ccxp-skills#35
#
# Idempotent: re-running with the same PR ref is a no-op. Best-effort: any
# failure logs to stderr but exits 0 so callers never break. The task file's
# frontmatter `status:` stays the source of truth; this only annotates the board.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_lib.sh"

if [ "$#" -lt 2 ]; then
  _session_log "usage: $0 <task-id> <pr-url-or-shortform>"
  exit 0
fi

session_append_pr_ref "$1" "$2" \
  || _session_log "  ! _session: set-pr-ref best-effort failed for $1 ($2) (continuing)"
exit 0
