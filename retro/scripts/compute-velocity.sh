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
#                       claim (the newest commit that added a non-empty
#                       claimed_by: for this task) to close (the OLDEST
#                       commit touching the task's current, exact
#                       dev/JOURNAL/ path — i.e. the git-mv-into-JOURNAL
#                       commit itself, not a synthetic time-of-day guess:
#                       an earlier "noon UTC on the close date" proxy was
#                       caught in PR review as systematically wrong — most
#                       tasks here claim and close same-day, and noon UTC
#                       sits earlier in the day than a same-day afternoon
#                       claim in US time zones, producing a negative span).
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

# Resolve a task's claim-start time from git HISTORY, not from the file's
# current claimed_by: value. _session/task_claim.sh's release path (_tc_release,
# called by /drive Phase 4 at close) explicitly CLEARS claimed_by to empty as
# part of closing — every dev/JOURNAL/*.md file's claimed_by is empty by
# construction, so reading it off the archived file and searching history for
# THAT (empty) value can never find anything (caught in PR review,
# T20260924-232855: the bug made hours_per_point permanently stuck at the
# bootstrap default — 0 of this repo's real completed tasks ever resolved).
#
# `git log --follow` is deliberately NOT used here: --follow's rename
# detection is content-similarity-based, and every task file shares nearly
# identical frontmatter boilerplate — on this repo's real history, --follow
# repeatedly latched onto an unrelated task's commits (confirmed: it produced
# claim timestamps dated AFTER the task's own close date for several real
# tasks, an impossible timeline, once the fix below replaced it). Query by
# the task ID instead — a glob pathspec matching any historical path
# containing the id (dev/TODO/<id>-*.md, dev/PARKING/<id>-*.md, and every
# dev/JOURNAL/<date>-<id>-*.md this task ever lived at) is exact, because the
# id is immutable and unique, with no content-similarity guessing involved.
#
# Walk that history and take the NEWEST commit that ADDED a non-empty
# "claimed_by: <value>" line — the last claim this task received before it
# closed. git log without --reverse is newest-first, so the FIRST matching
# added-line seen while scanning is that newest commit (awk sets `found`
# once and never overwrites it).
cv_resolve_claim_start() {
  local f="$1" id
  id="$(basename "$f" | grep -oE 'T[0-9]{8}-[0-9]{6}')"
  [ -n "$id" ] || return 0
  git -C "$cv_repo_root" log -p --format='===CMT===%aI' -- "*${id}*" 2>/dev/null | awk '
    /^===CMT===/ { cur=substr($0,10); next }
    /^\+claimed_by:[ \t]*[^ \t]/ { if (found == "") found = cur }
    END { if (found != "") print found }
  '
}

# The close timestamp: the OLDEST commit touching the task's exact current
# dev/JOURNAL/ path. That path never existed before the git-mv-into-JOURNAL
# commit, so this is exact (no rename-detection ambiguity) and reflects a
# real moment in time, unlike a synthetic time-of-day guess.
cv_resolve_close_time() {
  local f="$1"
  git -C "$cv_repo_root" log --format=%aI -- "$f" 2>/dev/null | tail -1
}

# Emit one TSV row per JOURNAL task file: close_iso, points, start_iso
# (start_iso empty if unresolvable). Piped into the python3 heredoc below
# for all the date-bucketing / median / JSON-writing math — this repo's
# established pattern for calendar arithmetic that must work on both GNU
# and BSD date (see _ipm/stamp-scheduled.sh), sidestepping bash's lack of a
# portable "Monday of this date" primitive entirely.
cv_rows="$(
  if [ -d "$cv_journal_dir" ] && git -C "$cv_repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    for f in "$cv_journal_dir"/*.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-T*) ;;
        *) continue ;;   # not a dated close entry (legacy/undated JOURNAL file)
      esac
      points="$(cv_fm_get "$f" estimation)"
      [[ "$points" =~ ^(1|2|3|5|8)$ ]] || continue   # unmigrated/unparseable — skip, don't crash
      close_iso="$(cv_resolve_close_time "$f")"
      [ -n "$close_iso" ] || close_iso="${base:0:10}T12:00:00+00:00"   # no git history (e.g. a test fixture never committed) — fall back to the filename date at noon UTC
      start_iso="$(cv_resolve_claim_start "$f")"
      printf '%s\t%s\t%s\n' "$close_iso" "$points" "$start_iso"
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
    close_iso, points_s = parts[0], parts[1]
    start_iso = parts[2] if len(parts) > 2 else ""
    try:
        # Bin by the close commit's own wall-clock date (the first 10 chars
        # of its ISO-8601 timestamp, i.e. the committer's local date) rather
        # than converting through UTC — this matches the convention the
        # dev/JOURNAL/ filename's own yyyy-mm-dd prefix already uses.
        close_date = datetime.date.fromisoformat(close_iso[:10])
        close_dt = datetime.datetime.fromisoformat(close_iso)
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
            actual_hours = (close_dt - start_dt).total_seconds() / 3600
            if actual_hours > 0:
                hours_per_point_samples.append(actual_hours / points)
                sample_size += 1
        except ValueError:
            pass

# The two numbers bootstrap independently (caught in PR review,
# T20260924-232855: an earlier version gated points_per_week on sample_size
# too, discarding real points_by_week data — and a sample_size==0 window,
# e.g. every closed task using the CCXP_PEER_MODE=0 claim bypass, is a real
# scenario, not just "freshly migrated"). A task contributes to
# points_per_week as soon as it has a parseable points value and closed in
# the window, with no dependency on a resolvable claim->close pair — only
# hours_per_point's sample (and the bootstrap flag, which tracks hours_per_
# point specifically, the only field /eta reads) needs one.
total_points = sum(points_by_week.values())
points_per_week_value = round(total_points / window_weeks, 2) if total_points > 0 else 10
hours_per_point_value = round(statistics.median(hours_per_point_samples), 2) if sample_size else 1

result = {
    "hours_per_point": hours_per_point_value,
    "points_per_week": points_per_week_value,
    "computed_at": today.isoformat(),
    "window_weeks": window_weeks,
    "sample_size": sample_size,
    "bootstrap": sample_size == 0,
}

with open(out_path, "w") as fh:
    json.dump(result, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"compute-velocity: wrote {out_path} "
      f"(hours_per_point={result['hours_per_point']}, "
      f"points_per_week={result['points_per_week']}, "
      f"sample_size={result['sample_size']}, bootstrap={result['bootstrap']})")
PY
