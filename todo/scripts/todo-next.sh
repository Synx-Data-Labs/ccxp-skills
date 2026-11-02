#!/usr/bin/env bash
# Token-free port of todo/SKILL.md's `next` workflow (T20260914-359646).
#
# Walks dev/TODO/queue.md top to bottom, skips Done/legacy Revisit/Parked
# and (peer mode, default on) tasks claimed by another live session, and
# prints the first 3 survivors with their structural facts. Deliberately
# does NOT attempt "the next concrete action to move it forward" — that
# requires reading and interpreting free-form task-body prose, a judgment
# call this token-free script can't make.
#
#   todo-next.sh [--skip-needs-human] [--check]
#     --skip-needs-human  also skip gated tasks (a "needs a human" marker, or the
#                         legacy SUPERVISED/BLOCKED/needs manual/sign-off words, or
#                         a `Blocked by` status; see todo-gated in _lib.sh). Used by
#                         /drive's auto-pick; the default listing still shows them.
#     --check             print nothing; exit 0 when at least one task would be
#                         listed, 1 when none (T20261102-261809)
set -euo pipefail

TODO_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TODO_SCRIPTS_DIR/_lib.sh"

TODO_QUEUE_DIR="${TODO_QUEUE_DIR:-.}"
QUEUE_FILE="$TODO_QUEUE_DIR/dev/TODO/queue.md"

function todo-next-main() {
  local skip_gated=0 check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-needs-human) skip_gated=1 ;;
      --check) check=1 ;;
      *) printf 'usage: todo-next.sh [--skip-needs-human] [--check]\n' >&2; return 2 ;;
    esac
    shift
  done
  if [ ! -f "$QUEUE_FILE" ]; then
    [ "$check" = 1 ] && return 1
    printf 'No dev/TODO/queue.md found at %s\n' "$QUEUE_FILE"
    return 0
  fi

  local total=0 picked=0 total_entries=0
  local -a lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done < "$QUEUE_FILE"

  local line
  for line in "${lines[@]}"; do
    todo-parse-queue-line "$line" > /dev/null || continue
    total_entries=$((total_entries+1))
  done

  local parsed id relpath title task_file status claim
  for line in "${lines[@]}"; do
    parsed="$(todo-parse-queue-line "$line")" || continue
    total=$((total+1))
    id="$(cut -f1 <<<"$parsed")"
    relpath="$(cut -f2 <<<"$parsed")"
    title="$(cut -f3 <<<"$parsed")"
    task_file="$TODO_QUEUE_DIR/dev/TODO/$relpath"
    [ -f "$task_file" ] || continue

    status="$(todo-fm-get "$task_file" status)"
    case "$status" in
      Done*|Revisit*|Parked*) continue ;;
    esac
    if [ "$skip_gated" = 1 ] && todo-gated "$status"; then continue; fi

    claim="$(todo-claim-state "$id" "$TODO_LIB_REPO_ROOT")"
    case "$claim" in
      peer:*) continue ;;
    esac

    picked=$((picked+1))
    [ "$check" = 1 ] && return 0
    printf '#%d of %d: %s — %s\n' "$total" "$total_entries" "$id" "$title"
    printf '  Status: %s\n' "$status"

    local deadline scheduled blocks
    deadline="$(todo-fm-get "$task_file" deadline)"
    [ -n "$deadline" ] && printf '  Deadline: %s\n' "$deadline"
    scheduled="$(todo-fm-get "$task_file" scheduled)"
    [ -n "$scheduled" ] && printf '  Scheduled: %s\n' "$scheduled"

    case "$claim" in
      mine) printf '  Claim: claimed by this session\n' ;;
      reclaimable:*) printf '  Claim: reclaimable stale peer claim (%s)\n' "${claim#reclaimable:}" ;;
      unclaimed) : ;;
    esac

    blocks="$(todo-fm-get "$task_file" blocks)"
    [ -n "$blocks" ] && printf '  Unblocks: %s\n' "$blocks"

    # Step 5: a still-open blocker gets a plain callout, no interpretation.
    if [[ "$status" =~ ^Blocked\ by\ (T[0-9-]+) ]]; then
      local blocker_id="${BASH_REMATCH[1]}"
      if compgen -G "$TODO_QUEUE_DIR/dev/TODO/${blocker_id}-*.md" > /dev/null 2>&1; then
        printf '  Blocked by an open task (%s) — run /todo sweep, not interpreted further here\n' "$blocker_id"
      fi
    fi

    [ "$picked" -ge 3 ] && break
  done

  if [ "$picked" -eq 0 ]; then
    [ "$check" = 1 ] && return 1
    printf 'No actionable tasks in the queue (all skipped: Done/Revisit/Parked/peer-claimed).\n'
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  todo-next-main "$@"
fi
