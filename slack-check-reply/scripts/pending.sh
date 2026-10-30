#!/usr/bin/env bash
# pending.sh [<task-id> | all | standup] — /slack-check-reply step 1: which
# escalation threads from drive-threads.json to read. Read-only; the state file
# is owned by _threads/threads.sh (this script never touches it directly).
#
#   (none) | all   every UNRESOLVED entry
#   <task-id>      that one entry, resolved or not (key T<id> or T<id>-pr<N>)
#   standup        nothing: the standup thread is discovered live, never stored
#
# stdout: TSV, one row per thread: key, resolved, type, sent_at, summary,
# channel_id, message_ts. A missing or empty state file prints nothing (exit 0)
# for all/standup; for a <task-id> it is "not found".
# Exit: 0 | 2 usage | 3 <task-id> not in the state file | 4 malformed state file.
# Env: THREADS_FILE selects the state file (default .claude/state/drive-threads.json).
# Judgment stays with the caller: reading each thread and splitting replies.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THREADS_SH="${THREADS_SH:-$HERE/../../_threads/threads.sh}"

usage() { echo "usage: pending.sh [<task-id> | all | standup]" >&2; exit 2; }
[ "$#" -le 1 ] || usage
arg="${1:-all}"

case "$arg" in
  standup) exit 0 ;;
  all) bash "$THREADS_SH" list --unresolved --full; exit $? ;;
  T[0-9]*)
    [[ "$arg" =~ ^T[0-9]+(-[0-9]+)?(-pr[0-9]+)?$ ]] || { echo "pending.sh: not a task id: $arg" >&2; usage; }
    rows="$(bash "$THREADS_SH" list --full)" || exit $?
    row="$(printf '%s\n' "$rows" | awk -F'\t' -v k="$arg" '$1 == k { print; exit }')"
    [ -n "$row" ] || { echo "pending.sh: no escalation thread recorded for $arg" >&2; exit 3; }
    printf '%s\n' "$row" ;;
  *) usage ;;
esac
