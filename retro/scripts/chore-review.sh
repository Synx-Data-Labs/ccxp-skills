#!/usr/bin/env bash
# chore-review.sh list-due    [--repo-root DIR] [--today YYYY-MM-DD]
# chore-review.sh scan-untracked --repo-root DIR --since YYYY-MM-DD
#
# Supports /retro's chore-index review step (build-pipeline-repo
# T20260608-246336): the weekly retro evaluates process-improvement chores
# tracked in a repo's dev/chore.md on evidence, not from memory.
#
# `dev/chore.md` is a thin index — one row per chore: Goal, a link to the
# chore's task file, Started date, and Outcome (blank until evaluated). This
# script is repo-agnostic: a repo with no dev/chore.md is a clean no-op for
# both subcommands (prints nothing, exits 0) so it doesn't break repos that
# haven't adopted the convention.
#
# list-due:
#   Parses dev/chore.md's table and prints one line per row that is DUE for
#   evaluation this retro: Outcome column is still blank/placeholder AND at
#   least one iteration (7 days) has passed since Started. Output format:
#     T<id>\t<goal>\t<started>
#   A row whose Outcome already carries a verdict (Kept/Revised/Extended) is
#   not due — already-evaluated chores don't get re-selected every week.
#
# scan-untracked:
#   Creation safety-net. Lists dev/*.md files (guideline/policy/skill-looking
#   paths — dev/guidelines.md, dev/branch-merge-policy.md, dev/*.md at the
#   dev/ root; excludes dev/TODO, dev/JOURNAL, dev/PARKING, dev/chore.md
#   itself) changed by a merge commit in the --since window, that dev/chore.md
#   does NOT link to (by task-id substring match against the diff's added
#   lines). A hit means "a process-looking change landed with no matching
#   chore.md row — add one or confirm it's not a chore."
#
# Used by /retro Phase 1d (chore index review).
set -euo pipefail

repo="."
today=""
since=""
cmd="${1:-}"
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) repo="${2:?--repo-root needs a dir}"; shift 2 ;;
    --today)     today="${2:?--today needs a date}"; shift 2 ;;
    --since)     since="${2:?--since needs a date}"; shift 2 ;;
    -h|--help)   sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'; exit 0 ;;
    -*)          echo "chore-review.sh: unknown option '$1'" >&2; exit 2 ;;
    *)           echo "chore-review.sh: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done

[ -z "$today" ] && today="$(date -u +%F)"

chore_md="$repo/dev/chore.md"

# Split a `|`-delimited table row into fields, trimming surrounding whitespace.
# Prints one field per line.
split_row() {
  awk -F'\\|' '{
    for (i = 2; i < NF; i++) {
      f = $i
      gsub(/^[ \t]+|[ \t]+$/, "", f)
      print f
    }
  }'
}

list_due() {
  [ -f "$chore_md" ] || return 0

  local today_epoch
  today_epoch="$(date -u -d "$today" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$today" +%s)"

  # Skip the header + separator rows (the first two `|`-leading lines), then
  # walk each data row. `|| true` on the grep guards against `set -o pipefail`
  # aborting the script when a table has zero data rows (grep exits 1).
  { grep -E '^\|' "$chore_md" || true; } | tail -n +3 | while IFS= read -r row; do
    local fields goal task_cell started outcome id started_epoch age_days
    fields="$(printf '%s\n' "$row" | split_row)"
    goal="$(sed -n '1p' <<<"$fields")"
    task_cell="$(sed -n '2p' <<<"$fields")"
    started="$(sed -n '3p' <<<"$fields")"
    outcome="$(sed -n '4p' <<<"$fields")"

    # already evaluated -> not due
    case "$outcome" in
      *Kept*|*Revised*|*Extended*) continue ;;
    esac

    id="$( { grep -oE 'T[0-9]{8}-[0-9]{6}' <<<"$task_cell" || true; } | head -1)"
    [ -n "$id" ] || continue

    started_epoch="$(date -u -d "$started" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$started" +%s)" || continue
    age_days=$(( (today_epoch - started_epoch) / 86400 ))
    [ "$age_days" -ge 7 ] || continue

    printf '%s\t%s\t%s\n' "$id" "$goal" "$started"
  done
}

scan_untracked() {
  [ -n "$since" ] || { echo "chore-review.sh scan-untracked: --since is required" >&2; exit 2; }
  [ -f "$chore_md" ] || return 0

  local linked_ids changed_files f id hit
  linked_ids="$(grep -oE 'T[0-9]{8}-[0-9]{6}' "$chore_md" | sort -u || true)"

  # dev/*.md at the dev/ root only (not TODO/JOURNAL/PARKING/chore.md itself) —
  # the process-looking-doc surface. Every stage is guarded with `|| true` so a
  # zero-match grep (a quiet window) doesn't trip `set -o pipefail` and abort.
  changed_files="$(
    git -C "$repo" log --since="$since" --name-only --pretty=format: -- 'dev/*.md' 2>/dev/null \
      | sort -u \
      | { grep -E '^dev/[^/]+\.md$' || true; } \
      | { grep -v -E '^dev/chore\.md$' || true; }
  )"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$repo/$f" ] || continue
    hit=0
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if grep -q "$id" "$repo/$f" 2>/dev/null; then
        hit=1
        break
      fi
    done <<<"$linked_ids"
    [ "$hit" -eq 1 ] || printf '%s\n' "$f"
  done <<<"$changed_files"
}

case "$cmd" in
  list-due)       list_due ;;
  scan-untracked) scan_untracked ;;
  ""|-h|--help)   sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'; exit 0 ;;
  *)              echo "chore-review.sh: unknown subcommand '$cmd' (expected list-due|scan-untracked)" >&2; exit 2 ;;
esac
