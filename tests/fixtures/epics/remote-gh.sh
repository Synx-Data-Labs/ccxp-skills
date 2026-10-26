#!/usr/bin/env bash
# Stub for TASKID_GH: serves `gh api repos/<o>/<r>/contents/<path>` from the
# fixture tree $REMOTE_FIXTURE/<o>/<r>/<path>. A directory path lists its file
# names (honouring `--jq .[].name`); a file path prints the file (raw). Any
# other call, or a missing path, exits 1. Calls are logged to $REMOTE_GH_LOG.
set -uo pipefail
if [ -n "${REMOTE_GH_LOG:-}" ]; then printf '%s\n' "$*" >> "$REMOTE_GH_LOG"; fi
[ "${1:-}" = "api" ] || exit 1
re='^repos/([^/]+/[^/]+)/contents/(.+)$'
[[ "${2:-}" =~ $re ]] || exit 1
p="$REMOTE_FIXTURE/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
if [ -d "$p" ]; then for f in "$p"/*; do [ -e "$f" ] && basename "$f"; done; exit 0; fi
[ -f "$p" ] || exit 1
cat "$p"
