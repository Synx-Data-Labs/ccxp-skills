#!/usr/bin/env bash
# is-support-task.sh — is this task a `support` task? (T20261012-109735)
#
# Usage: is-support-task.sh <task-file | T<id>>   (id resolved under dev/TODO,
#        dev/PARKING, dev/JOURNAL of the cwd repo)
# Exit: 0 support, 1 not support / not found. A task is `support` iff its body
# has `- **Type**: support` or its frontmatter has a `support-issue:` key.

set -euo pipefail

function support-is-support-task() {
  local arg="${1:-}" file="" d
  [[ -n "$arg" ]] || return 1
  if [[ -f "$arg" ]]; then
    file="$arg"
  else
    for d in dev/TODO dev/PARKING dev/JOURNAL; do
      file="$(compgen -G "$d/*${arg}-*.md" | head -1 || true)"
      [[ -n "$file" ]] && break
    done
  fi
  [[ -n "$file" && -f "$file" ]] || return 1
  grep -qE '^- \*\*Type\*\*:[[:space:]]*support([[:space:]]|$)|^support-issue:[[:space:]]*\S' "$file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  support-is-support-task "$@"
fi
