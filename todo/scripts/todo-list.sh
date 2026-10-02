#!/usr/bin/env bash
# Token-free port of todo/SKILL.md's `list` workflow (T20260914-359646).
#
# Renders the queue-order table, drift detection (untracked files, stale
# queue lines, stale Blocked-by references), status/claim counts, and the
# parking-lot count. Report-only — never mutates dev/TODO/ or queue.md.
set -euo pipefail

TODO_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TODO_SCRIPTS_DIR/_lib.sh"

TODO_QUEUE_DIR="${TODO_QUEUE_DIR:-.}"
QUEUE_FILE="$TODO_QUEUE_DIR/dev/TODO/queue.md"
TODO_DIR="$TODO_QUEUE_DIR/dev/TODO"
PARKING_DIR="$TODO_QUEUE_DIR/dev/PARKING"

function todo-list-main() {
  if [ ! -f "$QUEUE_FILE" ]; then
    printf 'No dev/TODO/queue.md found at %s\n' "$QUEUE_FILE"
    return 0
  fi

  printf '| # | ID | Title | Status | Est | Deadline | Scheduled | Claimed |\n'
  printf '|---|----|-------|--------|-----|----------|-----------|---------|\n'

  # Plain newline-delimited strings instead of `local -A` associative
  # arrays (bash 4+ only) — macOS's stock `/bin/bash` is 3.2, which has no
  # associative arrays at all (T20260925-407025). `queued_ids` is used purely
  # as a set (membership test); `all_statuses` collects one entry per task
  # and is reduced to per-status counts at the end via `sort | uniq -c`,
  # which is what an associative-array tally would have done anyway.
  local queued_ids=$'\n' all_statuses=""
  local total=0 claimed_mine=0 claimed_peers=0 committed=0
  local pos=0 line parsed id relpath title task_file status est deadline scheduled claim claimed_col
  local this_monday today
  this_monday="$(todo-current-monday)"
  today="${SESSION_TODAY:-$(date +%F)}"

  while IFS= read -r line; do
    parsed="$(todo-parse-queue-line "$line")" || continue
    pos=$((pos+1))
    id="$(cut -f1 <<<"$parsed")"
    relpath="$(cut -f2 <<<"$parsed")"
    title="$(cut -f3 <<<"$parsed")"
    queued_ids="${queued_ids}${id}"$'\n'
    task_file="$TODO_DIR/$relpath"

    if [ ! -f "$task_file" ]; then
      printf 'stale queue entry: %s (%s) — no matching dev/TODO/ file, run /todo sweep\n' "$id" "$relpath"
      continue
    fi

    total=$((total+1))
    status="$(todo-fm-get "$task_file" status)"
    all_statuses="${all_statuses}${status}"$'\n'
    est="$(todo-fm-get "$task_file" estimation)"
    deadline="$(todo-fm-get "$task_file" deadline)"
    scheduled="$(todo-fm-get "$task_file" scheduled)"
    claim="$(todo-claim-state "$id" "$TODO_LIB_REPO_ROOT")"

    claimed_col=""
    case "$claim" in
      mine) claimed_col="mine"; claimed_mine=$((claimed_mine+1)) ;;
      peer:*) claimed_col="${claim#peer:}"; claimed_peers=$((claimed_peers+1)) ;;
      reclaimable:*) claimed_col="${claim#reclaimable:}"; claimed_peers=$((claimed_peers+1)) ;;
    esac

    local deadline_col="$deadline" scheduled_col="$scheduled"
    if [ -n "$deadline" ] && [[ "$deadline" < "$today" ]]; then
      deadline_col="$deadline ⚠"
    fi
    if [ -n "$scheduled" ] && [[ "$scheduled" > "$this_monday" || "$scheduled" == "$this_monday" ]]; then
      committed=$((committed+1))
      scheduled_col="$scheduled ✓"
    fi

    printf '| %d | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$pos" "$id" "$title" "$status" "$est" "$deadline_col" "$scheduled_col" "$claimed_col"

    if [[ "$status" =~ ^Blocked\ by\ (T[0-9-]+) ]]; then
      local blocker_id="${BASH_REMATCH[1]}"
      if ! compgen -G "$TODO_DIR/${blocker_id}-*.md" > /dev/null 2>&1; then
        printf 'stale blocker: %s is Blocked by %s, which is no longer in dev/TODO/ — run /todo sweep\n' "$id" "$blocker_id"
      fi
    fi

    # SKILL.md step 4 also scans body "## Dependencies"-style sections for
    # stale T{id} references, not just the frontmatter status line — scoped
    # to just that section (not the whole file) to avoid flagging every
    # casual T-id mention (a `related:` field, prose referencing history).
    local dep_id
    while IFS= read -r dep_id; do
      [ -n "$dep_id" ] || continue
      if ! compgen -G "$TODO_DIR/${dep_id}-*.md" > /dev/null 2>&1; then
        printf 'stale dependency reference: %s references %s, which is no longer in dev/TODO/ — run /todo sweep\n' "$id" "$dep_id"
      fi
    done < <(awk '
      /^## Dependencies/ { insec=1; next }
      /^## / { insec=0 }
      insec { print }
    ' "$task_file" | grep -oE 'T[0-9]+-[0-9]+' | sort -u | grep -v "^${id}$" || true)
  done < "$QUEUE_FILE"

  local f base task_id untracked=0
  for f in "$TODO_DIR"/T*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    task_id="${base%%-*}"
    # ID is `T{digits}-{digits}` (two hyphen-delimited numeric groups).
    task_id="$(grep -oE '^T[0-9]+-[0-9]+' <<<"$base" || true)"
    [ -n "$task_id" ] || continue
    case "$queued_ids" in
      *$'\n'"$task_id"$'\n'*) : ;;
      *)
        untracked=$((untracked+1))
        printf 'untracked task not in queue.md: %s — run /todo sweep\n' "$base"
        ;;
    esac
  done

  printf 'total: %d\n' "$total"
  if [ -n "$all_statuses" ]; then
    printf '%s' "$all_statuses" | sort | uniq -c | while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace from `uniq -c`
      local count="${line%% *}" s="${line#* }"
      printf 'status %s: %d\n' "$s" "$count"
    done
  fi
  printf '%d committed to active iteration\n' "$committed"
  printf '%d claimed (%d mine, %d by peers)\n' $((claimed_mine+claimed_peers)) "$claimed_mine" "$claimed_peers"

  local parked=0
  if [ -d "$PARKING_DIR" ]; then
    parked="$(find "$PARKING_DIR" -maxdepth 1 -name 'T*.md' | wc -l | tr -d ' ')"
  fi
  printf 'Parking lot: %d parked\n' "$parked"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  todo-list-main "$@"
fi
