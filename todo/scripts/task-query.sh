#!/usr/bin/env bash
# Filter and group dev/TODO tasks by time / place / person / event
# (T20261114-380745). Read-only; see task_query.py for the flags.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${CCXP_ROUTINES_PROFILE_FILE:-}" ] && [ -f "$HERE/../../_session/profile-dir.sh" ]; then
  # shellcheck source=../../_session/profile-dir.sh
  . "$HERE/../../_session/profile-dir.sh"
  [ -z "${CCXP_PROFILE_DIR:-}" ] || export CCXP_ROUTINES_PROFILE_FILE="$CCXP_PROFILE_DIR/ccxp-routines.yml"
fi
exec python3 -I "$HERE/task_query.py" "$@"
