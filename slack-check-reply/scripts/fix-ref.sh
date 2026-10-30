#!/usr/bin/env bash
# fix-ref.sh <key> <channel_id> <message_ts> — /slack-check-reply step 4: after
# the search fallback recovers a stale thread reference, write the corrected
# channel_id/message_ts back. Only those two fields change (type, summary,
# sent_at and resolved state are kept); the write is atomic and goes through
# _threads/threads.sh, the single owner of drive-threads.json.
#
# Exit: 0 updated | 2 usage | 3 key not in the state file | 4 malformed state file.
# Env: THREADS_FILE selects the state file (default .claude/state/drive-threads.json).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THREADS_SH="${THREADS_SH:-$HERE/../../_threads/threads.sh}"

[ "$#" -eq 3 ] || { echo "usage: fix-ref.sh <key> <channel_id> <message_ts>" >&2; exit 2; }
exec bash "$THREADS_SH" fix-ref "$1" --channel "$2" --ts "$3"
