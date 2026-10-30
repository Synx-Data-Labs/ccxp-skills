#!/usr/bin/env bash
# midweek-add.sh --file IPM_FILE --task T<id> --est EST --why TEXT [options] —
# add one row to the `## Mid-week additions` table of an IPM file (/rca step 6,
# part 3). Only that table changes; the rest of the file is byte-identical.
# Nothing is pushed or posted. Re-running with a task already listed is a no-op.
#
#   --file F      the IPM file (from `_ipm/current.sh`)
#   --task ID     T<yyyymmdd>-<nnnnnn>
#   --est EST     the estimate cell (free text, no `|`)
#   --why TEXT    the "Why this iteration" cell (no `|`, one line)
#   --added DATE  YYYY-MM-DD (default: today, see _date/date.sh; TODAY pins it)
#   --url URL     render the Task cell as [ID](URL) (an http(s) URL)
#   --dry-run     print the row that would be added; write nothing
# The row number is the table's highest number + 1. A `| (none yet) |`
# placeholder row is replaced; otherwise the row goes after the last data row.
# Stdout on success: `ADDED #<n> <ID>` (or `DRY-RUN <row>`); `ALREADY <ID>` on exit 10.
# Exit: 0 added, 2 usage, 3 file missing/unwritable, 4 no Mid-week additions
#       table (heading, header or separator missing; nothing written),
#       10 the task is already in the table (nothing written).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "midweek-add.sh: $1" >&2; exit "${2:-2}"; }

file="" task="" est="" why="" added="" url="" dry=0 have_est=0 have_why=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file)  [ $# -ge 2 ] || die "--file needs a value"; file="$2"; shift 2 ;;
    --task)  [ $# -ge 2 ] || die "--task needs a value"; task="$2"; shift 2 ;;
    --est)   [ $# -ge 2 ] || die "--est needs a value"; est="$2"; have_est=1; shift 2 ;;
    --why)   [ $# -ge 2 ] || die "--why needs a value"; why="$2"; have_why=1; shift 2 ;;
    --added) [ $# -ge 2 ] || die "--added needs a value"; added="$2"; shift 2 ;;
    --url)   [ $# -ge 2 ] || die "--url needs a value"; url="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$file" ] || die "--file is required"
[[ "$task" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || die "--task must look like T20000101-000001, got '$task'"
[ "$have_est" = 1 ] && [ -n "${est// /}" ] || die "--est is required"
[ "$have_why" = 1 ] && [ -n "${why// /}" ] || die "--why is required"
for v in "$est" "$why"; do
  case "$v" in *'|'*|*$'\n'*|*$'\r'*) die "--est and --why must be one line without '|'" ;; esac
done
if [ -n "$url" ]; then
  [[ "$url" =~ ^https?://[^[:space:]\|\)]+$ ]] || die "--url must be an http(s) URL without spaces, '|' or ')'"
fi
if [ -z "$added" ]; then
  added="$(bash "$ROOT/_date/date.sh" today)" || exit 2
else
  if [[ ! "$added" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! bash "$ROOT/_date/date.sh" dow "$added" >/dev/null 2>&1; then
    die "--added must be a real YYYY-MM-DD date, got '$added'"
  fi
fi
[ -f "$file" ] && [ -r "$file" ] || die "not a readable file: $file" 3

cell="$task"
[ -z "$url" ] || cell="[$task]($url)"

tmp="$(mktemp "${TMPDIR:-/tmp}/midweek-add.XXXXXX")" || die "cannot create a temp file" 3
trap 'rm -f "$tmp"' EXIT

ROW_CELL="$cell" ROW_EST="$est" ROW_DATE="$added" ROW_WHY="$why" ROW_TASK="$task" \
awk '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function emit(   n) {
  n = maxn + 1
  printf "| %d | %s | %s | %s | %s |\n", n, ENVIRON["ROW_CELL"], ENVIRON["ROW_EST"], ENVIRON["ROW_DATE"], ENVIRON["ROW_WHY"]
  newn = n; emitted = 1
}
BEGIN { state = 0; maxn = 0; dup = 0; emitted = 0 }
state == 0 { print; if ($0 ~ /^##[ \t]+Mid-week additions/) state = 1; next }
state == 1 {                      # between the heading and the table header
  if ($0 ~ /^##[ \t]/) { bad = 1; exit }
  print
  if ($0 ~ /^\|/) { if ($0 ~ /^\|[ \t]*#[ \t]*\|/) state = 2; else { bad = 1; exit } }
  next
}
state == 2 { print; if ($0 ~ /^\|[ \t]*:?-+/) state = 3; else { bad = 1; exit }; next }
state == 3 {
  if ($0 ~ /^\|/) {
    split($0, c, "|"); first = trim(c[2])
    if (index($0, ENVIRON["ROW_TASK"]) > 0) dup = 1
    if (first ~ /^\(none yet\)/) { next }          # placeholder: replaced by the new row
    if (first ~ /^[0-9]+$/ && first + 0 > maxn) maxn = first + 0
    print; next
  }
  if (!emitted) emit()
  print; state = 4; next
}
{ print }
END {
  if (bad || state < 3) exit 4
  if (dup) exit 10
  if (!emitted) emit()
  print newn > "/dev/stderr"
}
' "$file" > "$tmp" 2> "$tmp.n"
rc=$?
newn="$(cat "$tmp.n" 2>/dev/null)"; rm -f "$tmp.n"
case "$rc" in
  0) ;;
  4) die "no well-formed '## Mid-week additions' table in $file; nothing written" 4 ;;
  10) echo "ALREADY $task"; echo "midweek-add.sh: $task is already in the table; nothing written" >&2; exit 10 ;;
  *) die "awk failed ($rc)" 3 ;;
esac
[[ "$newn" =~ ^[0-9]+$ ]] || die "internal error: no row number" 3

if [ "$dry" = 1 ]; then
  printf 'DRY-RUN | %s | %s | %s | %s | %s |\n' "$newn" "$cell" "$est" "$added" "$why"
  exit 0
fi
cat "$tmp" > "$file" || die "could not write $file" 3
echo "ADDED #$newn $task"
