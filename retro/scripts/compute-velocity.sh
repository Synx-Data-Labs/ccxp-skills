#!/usr/bin/env bash
# compute-velocity.sh [--repo-root DIR] [--today YYYY-MM-DD] [--window-weeks N]
#
# Compute rolling XP velocity from real dev/JOURNAL/ completion history and
# write it to dev/velocity.json (T20260924-232855). Run every /retro — see
# retro/SKILL.md's "Compute velocity" step.
#
# Over a trailing N-calendar-week window (Monday-Sunday, default N=4, purely
# calendar time — no dependency on scheduled:, IPM files, or whether /ccxp's
# IPM ritual ever runs):
#
#   points_per_week  — mean of (sum of points CLOSED) per calendar week,
#                       binned by each task's actual close date (the
#                       yyyy-mm-dd prefix on its dev/JOURNAL/ filename).
#   hours_per_point  — median(actual_hours / points) over the same window's
#                       completed tasks, where actual_hours is wall-clock
#                       claim (the commit that introduced the task's
#                       claimed_by: line, oldest match) to close (its
#                       JOURNAL filename date, at noon UTC — avoids a
#                       systematic bias toward either edge of the day).
#                       Median, not mean, to resist one outlier skewing the
#                       ratio (T20260924-232855 Appendix decision 1).
#
# Bootstrap case (zero tasks have a resolvable claim->close pair in the
# window — freshly migrated repo, or one that has never run /retro): write
# flat defaults instead of computing anything: hours_per_point: 1,
# points_per_week: 10 (5-day week * 2 points/day), bootstrap: true,
# sample_size: 0. A task contributes to points_per_week as soon as it has a
# parseable points value and closed in the window, even without a
# resolvable claim commit (points_per_week needs no start time) — only
# hours_per_point's sample (and sample_size) requires one.
#
# Date injection for tests: pass --today explicitly for determinism.
set -uo pipefail

USAGE="usage: compute-velocity.sh [--repo-root DIR] [--today YYYY-MM-DD] [--window-weeks N]"

cv_repo_root="."
cv_today="$(date -u +%F)"
cv_window_weeks="4"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)    [ $# -ge 2 ] || { echo "compute-velocity: --repo-root requires an argument" >&2; exit 2; }
                    cv_repo_root="$2"; shift 2 ;;
    --today)        [ $# -ge 2 ] || { echo "compute-velocity: --today requires an argument" >&2; exit 2; }
                    cv_today="$2"; shift 2 ;;
    --window-weeks) [ $# -ge 2 ] || { echo "compute-velocity: --window-weeks requires an argument" >&2; exit 2; }
                    cv_window_weeks="$2"; shift 2 ;;
    -h|--help)      echo "$USAGE"; exit 0 ;;
    *)              echo "compute-velocity: unknown argument '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done

cv_journal_dir="$cv_repo_root/dev/JOURNAL"
cv_fm_get() {
  # $1 file  $2 field -> echo the field's value (trimmed), or empty. First fence only.
  local file="$1" field="$2"
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm && $0 ~ "^"f":" {
      line=$0
      sub("^"f":[ \t]*", "", line)
      print line
      exit
    }
  ' "$file"
}

# Emit one TSV row per JOURNAL task file: close_date, points, start_iso
# (empty if unresolvable). Piped into the python3 heredoc below for all the
# date-bucketing / median / JSON-writing math — this repo's established
# pattern for calendar arithmetic that must work on both GNU and BSD date
# (see _ipm/stamp-scheduled.sh), sidestepping bash's lack of a portable
# "Monday of this date" primitive entirely.
cv_rows="$(
  if [ -d "$cv_journal_dir" ]; then
    for f in "$cv_journal_dir"/*.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-T*) ;;
        *) continue ;;   # not a dated close entry (legacy/undated JOURNAL file)
      esac
      close_date="${base:0:10}"
      points="$(cv_fm_get "$f" estimation)"
      [[ "$points" =~ ^(1|2|3|5|8)$ ]] || continue   # unmigrated/unparseable — skip, don't crash
      claimed_by="$(cv_fm_get "$f" claimed_by)"
      start_iso=""
      if [ -n "$claimed_by" ] && git -C "$cv_repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        start_iso="$(git -C "$cv_repo_root" log --follow -S"claimed_by: $claimed_by" \
          --format=%aI -- "$f" 2>/dev/null | tail -1)"
      fi
      printf '%s\t%s\t%s\n' "$close_date" "$points" "$start_iso"
    done
  fi
)"

cv_out="$cv_repo_root/dev/velocity.json"
mkdir -p "$(dirname "$cv_out")"

CV_TODAY="$cv_today" CV_WINDOW_WEEKS="$cv_window_weeks" CV_OUT="$cv_out" CV_ROWS="$cv_rows" \
  python3 - <<'PY'
import datetime
import json
import os
import statistics

today = datetime.date.fromisoformat(os.environ["CV_TODAY"])
window_weeks = int(os.environ["CV_WINDOW_WEEKS"])
out_path = os.environ["CV_OUT"]
rows = os.environ.get("CV_ROWS", "")

this_monday = today - datetime.timedelta(days=today.weekday())
window_start = this_monday - datetime.timedelta(weeks=window_weeks - 1)

points_by_week = {}
hours_per_point_samples = []
sample_size = 0

for line in rows.split("\n"):
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    close_date_s, points_s = parts[0], parts[1]
    start_iso = parts[2] if len(parts) > 2 else ""
    try:
        close_date = datetime.date.fromisoformat(close_date_s)
        points = int(points_s)
    except ValueError:
        continue
    if close_date < window_start or close_date > today:
        continue

    week_bin = close_date - datetime.timedelta(days=close_date.weekday())
    points_by_week[week_bin] = points_by_week.get(week_bin, 0) + points

    if start_iso:
        try:
            start_dt = datetime.datetime.fromisoformat(start_iso)
            # Close timestamp: noon UTC on the close date — avoids a
            # systematic bias toward either edge of the day when all we
            # have is a date, not a time (T20260924-232855 Appendix: wall
            # clock, simplest well-defined reading).
            close_dt = datetime.datetime(
                close_date.year, close_date.month, close_date.day, 12, 0, 0,
                tzinfo=datetime.timezone.utc)
            actual_hours = (close_dt - start_dt).total_seconds() / 3600
            if actual_hours > 0:
                hours_per_point_samples.append(actual_hours / points)
                sample_size += 1
        except ValueError:
            pass

if sample_size == 0:
    result = {
        "hours_per_point": 1,
        "points_per_week": 10,
        "computed_at": today.isoformat(),
        "window_weeks": window_weeks,
        "sample_size": 0,
        "bootstrap": True,
    }
else:
    total_points = sum(points_by_week.values())
    result = {
        "hours_per_point": round(statistics.median(hours_per_point_samples), 2),
        "points_per_week": round(total_points / window_weeks, 2),
        "computed_at": today.isoformat(),
        "window_weeks": window_weeks,
        "sample_size": sample_size,
        "bootstrap": False,
    }

with open(out_path, "w") as fh:
    json.dump(result, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"compute-velocity: wrote {out_path} "
      f"(hours_per_point={result['hours_per_point']}, "
      f"points_per_week={result['points_per_week']}, "
      f"sample_size={result['sample_size']}, bootstrap={result['bootstrap']})")
PY
