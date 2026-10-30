#!/usr/bin/env bash
# metrics.sh --since ISO [--repo-root DIR] — the /retro Phase 1 + 3 numbers as
# ONE JSON object on stdout. Read-only: it only lists PRs and runs through gh;
# it never posts, pushes or edits anything. The grading and narrative stay with
# the caller.
#
#   --since ISO   window start, YYYY-MM-DDTHH:MM:SSZ (window.sh's SINCE_ISO)
#   --repo-root   repo to read (default: cwd); gh runs inside it
# Env: METRICS_GH   gh command (default `bash <skills-root>/_gh/gh.sh`)
#      METRICS_RUN_LIMIT  run fetch cap (default 1000, gh's API cap)
#      THREADS_FILE drive-threads.json (default .claude/state/... in the repo)
#      NOW pins the clock (stale-PR cutoff), see _date/date.sh
#
# Shape (all keys always present):
#   since, until(now), commits, tasks_completed (dev/JOURNAL task files dated in
#   the window), backlog{todo,parking},
#   prs{merged, open, stale_open (older than 3 days), avg_cycle_hours (null when
#       nothing merged), additions, deletions, truncated (a PR list hit its
#       500 cap: counts are a floor)},
#   ci{total (completed runs, incl. skipped/cancelled), green (conclusion
#      success), failed (failure, timed_out or startup_failure),
#      pass_rate_pct (null when total is 0), top_failing[{name,failures}] top 3,
#      oldest_created, run_limit, truncated},
#   escalations{sent (sent_at in the window), resolved (of those sent)}
# PRs are windowed by mergedAt >= since (to the second); commits likewise; JOURNAL
# entries and the merged search by whole calendar days from since's date.
# truncated=true means the run list hit the fetch cap, so older runs in the
# window were dropped: report the gap, never the rate as complete.
# Exit: 0 ok, 2 usage, 3 any gh/git/jq failure (nothing partial is printed),
#       4 malformed drive-threads file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
since="" repo="."
while [ $# -gt 0 ]; do
  case "$1" in
    --since)     [ $# -ge 2 ] || { echo "metrics.sh: --since needs a value" >&2; exit 2; }; since="$2"; shift 2 ;;
    --repo-root) [ $# -ge 2 ] || { echo "metrics.sh: --repo-root needs a value" >&2; exit 2; }; repo="$2"; shift 2 ;;
    *) echo "metrics.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "metrics.sh: --since must be YYYY-MM-DDTHH:MM:SSZ, got '$since'" >&2; exit 2; }
limit="${METRICS_RUN_LIMIT:-1000}"
[[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] || { echo "metrics.sh: bad METRICS_RUN_LIMIT" >&2; exit 2; }
[ -d "$repo" ] || { echo "metrics.sh: not a directory: $repo" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "metrics.sh: jq is required" >&2; exit 3; }
cd "$repo" || exit 3

gh_cmd="${METRICS_GH:-bash $ROOT/_gh/gh.sh}"
since_date="${since%%T*}"
fail() { echo "metrics.sh: $1 failed; no metrics printed" >&2; exit 3; }

now_iso="$(bash "$ROOT/_date/date.sh" ago 0)" || exit 3
stale_cut="$(bash "$ROOT/_date/date.sh" ago 3)" || exit 3
today="$(bash "$ROOT/_date/date.sh" today)" || exit 3   # same "today" as window.sh END

git rev-parse --git-dir >/dev/null 2>&1 || fail "git log (not a git repo)"
commits="$(git log --since="$since" --oneline | wc -l | tr -d ' ')"

# tasks completed: dev/JOURNAL/YYYY-MM-DD-T<id>-*.md dated within [since_date, today]
tasks=0
for f in dev/JOURNAL/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [[ "$b" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-T[0-9]{8}-[0-9]{6}- ]] || continue
  d="${BASH_REMATCH[1]}"
  { [[ "$d" > "$since_date" || "$d" == "$since_date" ]] && [[ ! "$d" > "$today" ]]; } && tasks=$((tasks + 1))
done
todo=0
for f in dev/TODO/*.md; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = queue.md ] && continue
  todo=$((todo + 1))
done
parking=0
for f in dev/PARKING/*.md; do [ -f "$f" ] && parking=$((parking + 1)); done

# shellcheck disable=SC2086
merged_raw="$($gh_cmd pr list --state merged --search "merged:>=$since_date" \
  --json number,title,mergedAt,createdAt,additions,deletions --limit 500)" || fail "gh pr list (merged)"
# shellcheck disable=SC2086
open_raw="$($gh_cmd pr list --state open --json number,title,createdAt --limit 500)" || fail "gh pr list (open)"
# shellcheck disable=SC2086
runs_raw="$($gh_cmd run list --created ">=$since" --limit "$limit" --json conclusion,name,createdAt)" || fail "gh run list"

esc="$(bash "$ROOT/_threads/threads.sh" list)"; rc=$?
[ "$rc" -eq 0 ] || { echo "metrics.sh: drive-threads file unreadable or malformed" >&2; exit 4; }

jq -n -c --arg since "$since" --arg until "$now_iso" --arg stale "$stale_cut" \
  --argjson commits "$commits" --argjson tasks "$tasks" --argjson todo "$todo" --argjson parking "$parking" \
  --argjson limit "$limit" --slurpfile merged <(printf '%s' "$merged_raw") \
  --slurpfile open <(printf '%s' "$open_raw") --slurpfile runs <(printf '%s' "$runs_raw") \
  --arg esc "$esc" '
  ($merged[0] | map(select(.mergedAt >= $since))) as $m
  | $open[0] as $o | $runs[0] as $r
  | ($r | map(select((.conclusion // "") != ""))) as $done
  | ($done | length) as $total
  | ($done | map(select(.conclusion == "success")) | length) as $green
  | ($done | map(select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure"))) as $fails
  | ($esc | split("\n") | map(select(length > 0) | split("\t")) | map(select(.[3] >= $since))) as $e
  | {since: $since, until: $until, commits: $commits, tasks_completed: $tasks,
     backlog: {todo: $todo, parking: $parking},
     prs: {merged: ($m | length), open: ($o | length),
           stale_open: ($o | map(select(.createdAt < $stale)) | length),
           avg_cycle_hours: (if ($m | length) == 0 then null
             else (($m | map((.mergedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) | add)
                   / ($m | length) / 3600 * 10 | round / 10) end),
           additions: ($m | map(.additions // 0) | add // 0),
           deletions: ($m | map(.deletions // 0) | add // 0),
           truncated: (($merged[0] | length) >= 500 or ($o | length) >= 500)},
     ci: {total: $total, green: $green, failed: ($fails | length),
          pass_rate_pct: (if $total == 0 then null else ($green * 1000 / $total | round / 10) end),
          top_failing: ($fails | group_by(.name) | map({name: .[0].name, failures: length})
                        | sort_by(-.failures, .name) | .[:3]),
          oldest_created: ($r | map(.createdAt) | min // null),
          run_limit: $limit, truncated: (($r | length) >= $limit)},
     escalations: {sent: ($e | length), resolved: ($e | map(select(.[1] == "true")) | length)}}
' || fail "assembling JSON"
