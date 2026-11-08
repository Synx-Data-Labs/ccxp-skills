#!/usr/bin/env bash
# lint_profile_dir.sh — fail on a bare ~/.claude profile literal in code
# (T20261108-315759). Scans *.sh and *.py (outside tests/), non-comment lines.
#
# Flagged: $HOME/.claude, ${HOME}/.claude, ~/.claude, Path.home() / ".claude",
# and a quoted ".claude" path component, when followed by a non-word,
# non-hyphen character or end of line (so .claude-work, .claude-plugin and
# repo-relative .claude/state are fine only when not preceded by a home form).
# Exempt: _session/profile-dir.sh (the one definition), this file, and any line
# carrying the marker `profile-dir-ok`.
#
# Usage: lint_profile_dir.sh [ROOT]   (default: the repo root above this file)
# Exit: 0 clean, 1 findings (printed as file:line: text), 2 usage.
#
# Sourceable: functions only; the CLI runs under the direct-execution guard.

lint-profile-dir-scan() {
  local root="${1:-}" f rc=0 hits
  [ -d "$root" ] || { echo "lint_profile_dir: not a directory: $root" >&2; return 2; }
  # Home-relative forms followed by `/.claude` then (non-word, non-hyphen | EOL),
  # and python's quoted component.
  # shellcheck disable=SC2016 # the regex is literal, never expanded
  local re='(\$HOME"?|\$\{HOME(:-[^}]*)?\}"?|~|expanduser\("~"\))/\.claude([^A-Za-z0-9_-]|$)|Path\.home\(\) */ *"\.claude"|"\.claude",|, *"\.claude"\)'
  while IFS= read -r f; do
    case "$f" in
      */_session/profile-dir.sh|*/_session/lint_profile_dir.sh) continue ;;
    esac
    hits="$(grep -nE -- "$re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'profile-dir-ok')" || true
    if [ -n "$hits" ]; then
      printf '%s\n' "$hits" | sed "s|^|${f#"$root"/}:|"
      rc=1
    fi
  done < <(cd "$root" && find . -type f \( -name '*.sh' -o -name '*.py' \) \
             -not -path '*/tests/*' -not -path '*/.git/*' -not -path '*/node_modules/*' | sort | sed "s|^\.|$root|")
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  [ "$#" -le 1 ] || { echo "usage: lint_profile_dir.sh [ROOT]" >&2; exit 2; }
  lint-profile-dir-scan "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  exit $?
fi
