#!/usr/bin/env bash
# Generate a unique task ID in the canonical TYYYYMMDD-NNNNNN format.
#
# The format is defined in ~/.claude/skills/repo-conventions/templates/guidelines.md.
# Every skill that creates a task MUST call this script (or `task-id-new`
# after sourcing) instead of inlining its own generator — keeps the
# format in one place and lets us add collision avoidance, locking, etc.
# without touching every callsite.
#
# Usage:
#   bash ~/.claude/skills/_taskid/new.sh                 # one ID to stdout
#   bash ~/.claude/skills/_taskid/new.sh --check ./dev   # retry until unused under dev/{TODO,PARKING,JOURNAL}
#
# Sourceable form:
#   source ~/.claude/skills/_taskid/new.sh
#   id=$(task-id-new)
#   id=$(task-id-new --check ./dev)
#
# Minting an ID is NOT filing a task. Before referencing the ID anywhere
# else — code comments, test names, commit messages, other task files —
# create dev/TODO/<id>-<slug>.md first (see repo-conventions/templates/
# task.md). An ID with no task file is an orphaned reference: a future
# reader (including you, next session) has no way to look up what it's
# tracking or why. `_taskid/check-orphaned-refs.sh` catches exactly this in
# CI; don't rely on it to catch what you can just do in the right order.
set -euo pipefail

function task-id-new() {
  local check_dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) check_dir="${2:-./dev}"; shift 2 ;;
      -h|--help)
        sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *) echo "task-id-new: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  local date_part rand_part id
  date_part="$(date +%Y%m%d)"

  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    rand_part="$(od -An -tu4 -N4 /dev/urandom | tr -d ' ' | cut -c1-6)"
    # Pad to 6 digits in case the random read produced a short number.
    printf -v id "T%s-%06d" "$date_part" "$((10#$rand_part))"

    if [ -z "$check_dir" ]; then
      echo "$id"
      return 0
    fi

    # Collision check: any file under TODO/PARKING/JOURNAL whose name starts
    # with this id is a hit. Glob expansion needs nullglob to avoid literal
    # patterns when a folder is empty/missing.
    local taken=0 dir
    shopt -s nullglob
    for dir in "$check_dir/TODO" "$check_dir/PARKING" "$check_dir/JOURNAL"; do
      [ -d "$dir" ] || continue
      local matches=("$dir"/*"${id}"*)
      if [ "${#matches[@]}" -gt 0 ]; then
        taken=1
        break
      fi
    done
    shopt -u nullglob

    if [ "$taken" -eq 0 ]; then
      echo "$id"
      return 0
    fi
  done

  echo "task-id-new: failed to generate a non-colliding id after 10 attempts" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  task-id-new "$@"
fi
