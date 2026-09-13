#!/usr/bin/env bash
# status.sh <task-id> <status-value> — set the Project Status single-select
# field for the given task. Value is one of: Open, Design, Coding, Review,
# Blocked, Parked, Done (case-insensitive).
#
# Best-effort: failures log to stderr but exit 0 so callers don't fail.
# The frontmatter `status:` field in the task file remains the source of
# truth; this is a Project-view mirror.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_lib.sh"

if [ "$#" -lt 2 ]; then
  _session_log "usage: $0 <task-id> <status-value>"
  exit 0
fi

session_set_status "$1" "$2" || _session_log "  ! _session: set_status best-effort failed for $1 → $2 (continuing)"
exit 0
