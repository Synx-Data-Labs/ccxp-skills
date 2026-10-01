#!/usr/bin/env bash
# migrate-estimation-to-points.sh [--repo-root DIR] [--dry-run]
#
# One-time, idempotent migration: rewrite every dev/TODO/*.md and
# dev/JOURNAL/*.md file's frontmatter `estimation:` value from the retired
# duration-bucket enum to the new Fibonacci-style points enum
# (T20260924-232855). Lossy by design (old durations were rough guesses
# anyway; /incept corrects real ones during normal grilling):
#
#   15m, 30m, 1h -> 1
#   2h, 4h       -> 2
#   1d           -> 3
#   2d           -> 5
#   1w, 2w       -> 8     (2w saturates at the same top bucket as 1w — the
#                          5-value Fibonacci scale has no slot above 8)
#
# Only the estimation: value is touched — any trailing prose on the same
# line (e.g. "2h (S)") is preserved after the mapped point. Idempotent: a
# file whose estimation: is already one of {1,2,3,5,8} is left untouched,
# so re-running after a partial migration (or across repos sharing this
# script) is always safe.
#
# Scope: only the frontmatter estimation: line (between the first pair of
# `---` fences) is ever touched — a body mention of "2h" in prose is never
# rewritten.
set -uo pipefail

USAGE="usage: migrate-estimation-to-points.sh [--repo-root DIR] [--dry-run]"

mep_repo_root="."
mep_dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) [ $# -ge 2 ] || { echo "migrate-estimation-to-points: --repo-root requires an argument" >&2; exit 2; }
                 mep_repo_root="$2"; shift 2 ;;
    --dry-run)   mep_dry_run=1; shift ;;
    -h|--help)   echo "$USAGE"; exit 0 ;;
    *)           echo "migrate-estimation-to-points: unknown argument '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done

mep_changed=0
mep_scanned=0

mep_migrate_file() {
  local f="$1"
  python3 - "$f" "$mep_dry_run" <<'PY'
import re
import sys

path, dry_run = sys.argv[1], sys.argv[2] == "1"

MAP = {
    "15m": "1", "30m": "1", "1h": "1",
    "2h": "2", "4h": "2",
    "1d": "3",
    "2d": "5",
    "1w": "8", "2w": "8",
}
BUCKET_RE = re.compile(r"^(15m|30m|1h|2h|4h|1d|2d|1w|2w)\b(.*)$")

with open(path, encoding="utf-8") as fh:
    text = fh.read()

if not text.startswith("---\n"):
    sys.exit(0)   # no frontmatter — not a task file, leave untouched
parts = text.split("---", 2)
if len(parts) < 3:
    sys.exit(0)
fm, body = parts[1], parts[2]

lines = fm.split("\n")
changed = False
for i, line in enumerate(lines):
    m = re.match(r"^estimation:[ \t]*(.*)$", line)
    if not m:
        continue
    value = m.group(1)
    bm = BUCKET_RE.match(value.strip())
    if not bm:
        break   # already migrated (or unrecognized) — leave as-is, idempotent
    mapped = MAP[bm.group(1)] + bm.group(2)
    lines[i] = f"estimation: {mapped}"
    changed = True
    break

if not changed:
    sys.exit(0)

new_fm = "\n".join(lines)
new_text = "---" + new_fm + "---" + body
if not dry_run:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new_text)
print(path)
PY
}

for mep_dir in "$mep_repo_root/dev/TODO" "$mep_repo_root/dev/JOURNAL"; do
  [ -d "$mep_dir" ] || continue
  for mep_f in "$mep_dir"/*.md; do
    [ -e "$mep_f" ] || continue
    mep_scanned=$((mep_scanned + 1))
    if mep_result="$(mep_migrate_file "$mep_f")" && [ -n "$mep_result" ]; then
      mep_changed=$((mep_changed + 1))
      echo "migrated: $mep_f"
    fi
  done
done

if [ "$mep_dry_run" -eq 1 ]; then
  echo "migrate-estimation-to-points: (dry-run) $mep_changed/$mep_scanned file(s) would change"
else
  echo "migrate-estimation-to-points: $mep_changed/$mep_scanned file(s) changed"
fi
