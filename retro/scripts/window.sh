#!/usr/bin/env bash
# window.sh [WEEKS] [--repo-root DIR] — the review window for /retro, as
# KEY=value lines on stdout (nothing is written, nothing leaves the machine).
#
#   WEEKS         1..52, default 1 (the /retro argument; N weeks = N*7 days)
#   --repo-root   repo holding dev/JOURNAL (default: cwd)
#
# Output:
#   WEEKS=1
#   START=YYYY-MM-DD        END minus 7*WEEKS days
#   END=YYYY-MM-DD          today
#   SINCE_ISO=...Z          the instant 7*WEEKS days ago (UTC), for --created
#   THIS_MONDAY=YYYY-MM-DD  the Monday on or before today (the IPM file's date)
#   IPM_FILE=dev/JOURNAL/<THIS_MONDAY>-ipm-weekly.md, or empty when absent
#   PRIOR_RETRO=dev/JOURNAL/<date>-retro-*.md, the newest dated BEFORE END,
#                or empty when there is none (an already-written retro for
#                today is the one being re-run, not the prior one)
#
# Clock: TODAY=YYYY-MM-DD and NOW=YYYY-MM-DDTHH:MM:SSZ pin it (see
# _date/date.sh). Portable GNU/BSD: all calendar maths goes through date.sh.
# Exit: 0 ok, 2 usage / bad date, 3 repo root is not a directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATE() { bash "$ROOT/_date/date.sh" "$@"; }   # $ROOT may contain a space

weeks=1 repo="."
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) [ $# -ge 2 ] || { echo "window.sh: --repo-root needs a value" >&2; exit 2; }; repo="$2"; shift 2 ;;
    -*) echo "window.sh: unknown argument: $1" >&2; exit 2 ;;
    *)  weeks="$1"; shift ;;
  esac
done
[[ "$weeks" =~ ^[0-9]+$ ]] && [ "$weeks" -ge 1 ] && [ "$weeks" -le 52 ] \
  || { echo "window.sh: WEEKS must be an integer 1..52, got '$weeks'" >&2; exit 2; }
[ -d "$repo" ] || { echo "window.sh: not a directory: $repo" >&2; exit 3; }

end="$(DATE today)" || exit 2
start="$(DATE add "$end" "-$((weeks * 7))")" || exit 2
since="$(DATE ago "$((weeks * 7))")" || exit 2
monday="$(DATE monday "$end")" || exit 2

ipm=""
[ -f "$repo/dev/JOURNAL/$monday-ipm-weekly.md" ] && ipm="dev/JOURNAL/$monday-ipm-weekly.md"

prior="" f="" b=""
for f in "$repo"/dev/JOURNAL/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-retro-*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [[ "${b:0:10}" < "$end" ]] || continue
  # glob order is lexical, so the last qualifying name is the newest
  prior="dev/JOURNAL/$b"
done

printf 'WEEKS=%s\nSTART=%s\nEND=%s\nSINCE_ISO=%s\nTHIS_MONDAY=%s\nIPM_FILE=%s\nPRIOR_RETRO=%s\n' \
  "$weeks" "$start" "$end" "$since" "$monday" "$ipm" "$prior"
