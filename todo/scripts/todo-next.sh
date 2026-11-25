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
#   todo-next.sh [--skip-gated] [--check] [--exclude T<id>[,T<id>...]] [--nth N] [--here] [--when W]
#                [--tier N[,N...]] [--ids]
#     --skip-gated  also skip gated tasks (a
#                   `Blocked by` status only; see todo-gated in _lib.sh). Used by
#                   /drive's auto-pick; the default listing still shows them.
#     --check       print nothing; exit 0 when at least one task would be listed,
#                   1 when none
#     --exclude     skip these task ids (in flight in another autopilot slot) and every task whose
#                   status is `Blocked by` one of them
#     --nth N       list only the Nth survivor (1-based) instead of the first 3; with --check,
#                   exit 0 only when at least N survive
#     --tier        only tasks whose effective tier (todo-tier: frontmatter `tier:`, default 3) is listed
#     --ids         print only "<id><TAB><tier>" for every survivor, one per line, in queue order (no limit;
#                   one scan for the autopilot's tier cursor); wins over --nth and --check. Peer claims are
#                   NOT checked here (that is the slow part): the caller checks the few it takes
#     --here        only tasks with no `place:` or a place in the profile file's `here:` list
#     --when W      only tasks whose `when` matches W (today|tomorrow|week|overdue|<date>)
#                   Both are filters only (T20261114-380745): the pick is still the first
#                   match in queue order. Without them, tasks due today are listed first under
#                   a "Due today" line, informational; it never reorders the queue.
set -euo pipefail

TODO_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TODO_SCRIPTS_DIR/_lib.sh"

TODO_QUEUE_DIR="${TODO_QUEUE_DIR:-.}"
QUEUE_FILE="$TODO_QUEUE_DIR/dev/TODO/queue.md"

function todo-next-main() {
  local skip_gated=0 check=0 exclude="" nth=0 here=0 when="" tiers="" ids=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-gated) skip_gated=1 ;;
      --check) check=1 ;;
      --exclude) [ $# -ge 2 ] || { printf 'usage: --exclude needs a comma list of task ids\n' >&2; return 2; }; exclude=",$2,"; shift ;;
      --nth) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { printf 'usage: --nth needs a positive integer\n' >&2; return 2; }; nth="$2"; shift ;;
      --tier) [[ "${2:-}" =~ ^[1-4](,[1-4])*$ ]] || { printf 'usage: --tier needs tiers 1-4, comma separated\n' >&2; return 2; }; tiers="$2"; shift ;;
      --ids) ids=1 ;;
      --here) here=1 ;;
      --when) [ -n "${2:-}" ] || { printf 'usage: --when needs a value\n' >&2; return 2; }; when="$2"; shift ;;
      *) printf 'usage: todo-next.sh [--skip-gated] [--check] [--exclude T<id>,...] [--nth N] [--here] [--when W] [--tier N,...] [--ids]\n' >&2; return 2 ;;
    esac
    shift
  done
  if [ ! -f "$QUEUE_FILE" ]; then
    [ "$check" = 1 ] && return 1
    printf 'No dev/TODO/queue.md found at %s\n' "$QUEUE_FILE"
    return 0
  fi

  local total=0 picked=0 total_entries=0 dim_ids="" dim_filter=0 qargs=()
  local query="$TODO_SCRIPTS_DIR/task-query.sh"
  if [ "$here" = 1 ] || [ -n "$when" ]; then
    dim_filter=1
    [ "$here" = 1 ] && qargs+=(--here)
    [ -n "$when" ] && qargs+=(--when "$when")
    dim_ids="$(TODO_QUEUE_DIR="$TODO_QUEUE_DIR" bash "$query" "${qargs[@]}")" || return 2
    dim_ids="$(grep -oE '^T[0-9]+-[0-9]+' <<<"$dim_ids" || true)"
  elif [ "$check" = 0 ] && [ "$nth" -eq 0 ] && [ "$ids" = 0 ]; then
    local due
    due="$(TODO_QUEUE_DIR="$TODO_QUEUE_DIR" bash "$query" --when today 2>/dev/null | grep -E '^T[0-9]+-[0-9]+' || true)"
    if [ -n "$due" ]; then
      printf 'Due today (informational, does not reorder the queue):\n'
      printf '%s\n' "$due" | while IFS= read -r l; do printf '  %s\n' "$l"; done
    fi
  fi
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
    # `type: event` is a dated calendar entry, never implementation work
    # (T20261114-352324): never the pick, gated or not.
    [ "$(todo-task-type "$task_file")" = "event" ] && continue
    if [ "$dim_filter" = 1 ]; then
      case $'\n'"$dim_ids"$'\n' in *$'\n'"$id"$'\n'*) : ;; *) continue ;; esac
    fi
    if [ "$skip_gated" = 1 ] && todo-gated "$status"; then continue; fi
    if [ -n "$exclude" ]; then
      case "$exclude" in *",$id,"*) continue ;; esac
      if [[ "$status" =~ ^Blocked\ by\ (T[0-9-]+) ]]; then
        case "$exclude" in *",${BASH_REMATCH[1]},"*) continue ;; esac
      fi
    fi

    if [ -n "$tiers" ]; then
      case ",$tiers," in *",$(todo-tier "$task_file"),"*) : ;; *) continue ;; esac
    fi

    if [ "$ids" = 1 ]; then printf '%s\t%s\n' "$id" "$(todo-tier "$task_file")"; continue; fi

    claim="$(todo-claim-state "$id" "$TODO_LIB_REPO_ROOT")"
    case "$claim" in
      peer:*) continue ;;
    esac

    picked=$((picked+1))
    if [ "$nth" -gt 0 ]; then
      [ "$picked" -ge "$nth" ] || continue
      [ "$check" = 1 ] && return 0
    elif [ "$check" = 1 ]; then
      return 0
    fi
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

    blocks="$(todo-dependants "$id" "$TODO_QUEUE_DIR/dev/TODO" | paste -sd, - | sed 's/,/, /g')"
    [ -n "$blocks" ] && printf '  Unblocks: %s\n' "$blocks"

    # Step 5: a still-open blocker gets a plain callout, no interpretation.
    if [[ "$status" =~ ^Blocked\ by\ (T[0-9-]+) ]]; then
      local blocker_id="${BASH_REMATCH[1]}"
      if compgen -G "$TODO_QUEUE_DIR/dev/TODO/${blocker_id}-*.md" > /dev/null 2>&1; then
        printf '  Blocked by an open task (%s) — run /todo sweep, not interpreted further here\n' "$blocker_id"
      fi
    fi

    if [ "$nth" -gt 0 ]; then break; fi
    [ "$picked" -ge 3 ] && break
  done

  if [ "$ids" = 1 ]; then return 0; fi
  if [ "$picked" -eq 0 ] || { [ "$nth" -gt 0 ] && [ "$picked" -lt "$nth" ]; }; then
    [ "$check" = 1 ] && return 1
    printf 'No actionable tasks in the queue (all skipped: Done/Revisit/Parked/peer-claimed).\n'
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  todo-next-main "$@"
fi
