#!/usr/bin/env bash
# pr_task_id.sh <pr-number> — echo the task ID associated with a PR,
# or empty string if not derivable.
#
# Tries three signals in order, accepts the first match:
#   1. Branch name (`t<id>-<slug>` per dev/guidelines.md)
#   2. PR body `Task:` link (cross-repo /gcpr convention)
#   3. PR commit messageHeadline scan
#
# Used by /address-pr to correlate an arbitrary PR number back to its task
# file (and thus its Project item). Quiet on miss — callers skip the
# Project update when correlation fails.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_lib.sh"

if [ "$#" -lt 1 ]; then
  _session_log "usage: $0 <pr-number>"
  exit 0
fi

session_pr_task_id "$1"
exit 0
