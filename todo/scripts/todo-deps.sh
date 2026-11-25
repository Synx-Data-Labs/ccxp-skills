#!/usr/bin/env bash
# todo-deps.sh — dependency helpers over dev/TODO (epic E3, T20261125-264487).
#
#   todo-deps.sh dependants T<id> [--dir DIR]     tasks that depend on T<id>
#                                                 (derived from depends_on; a legacy
#                                                 blocks: line is read with a warning)
#   todo-deps.sh migrate [--dry-run] [--dir DIR]...
#                                                 rewrite each `blocks: [X]` on task A
#                                                 into A's id in X's depends_on, then
#                                                 remove the blocks: key. --dry-run
#                                                 reports and writes nothing.
#
# --dir (repeatable; default ${TODO_QUEUE_DIR:-.}/dev/TODO, plus dev/PARKING for
# migrate when it exists). Never run migrate on a repo's real task files except
# through that repo's own migration task.
set -euo pipefail

TODO_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$TODO_DEPS_DIR/_lib.sh"

function todo-deps-main() {
  local cmd="${1:-}"; shift || true
  local root="${TODO_QUEUE_DIR:-.}" dirs=() dry=() id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dirs+=("$2"); shift 2 ;;
      --dry-run) dry=(--dry-run); shift ;;
      -*) echo "todo-deps.sh: unknown flag $1" >&2; return 2 ;;
      *) id="$1"; shift ;;
    esac
  done
  case "$cmd" in
    dependants)
      [ -n "$id" ] || { echo "usage: todo-deps.sh dependants T<id> [--dir DIR]" >&2; return 2; }
      [ "${#dirs[@]}" -gt 0 ] || dirs=("$root/dev/TODO")
      todo-dependants "$id" "${dirs[0]}"
      ;;
    migrate)
      if [ "${#dirs[@]}" -eq 0 ]; then
        dirs=("$root/dev/TODO")
        [ -d "$root/dev/PARKING" ] && dirs+=("$root/dev/PARKING")
      fi
      python3 -I "$TODO_DEPS_DIR/todo_deps_migrate.py" "${dry[@]+"${dry[@]}"}" "${dirs[@]}"
      ;;
    *) echo "usage: todo-deps.sh {dependants|migrate} ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  todo-deps-main "$@"
fi
