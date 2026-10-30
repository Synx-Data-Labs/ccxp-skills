#!/usr/bin/env bash
# todo-sweep.sh — the mechanical half of `/todo sweep`, as a read-only PLAN
# and a writing APPLY. Judgment stays with the caller: the Park
# recommendation is never scripted, and SUPERSEDE_CANDIDATE lines are only
# explicit "superseded/absorbed by T<id>" cross-references, never closed
# unless the caller confirms each one.
#
#   todo-sweep.sh plan  [--root DIR]
#   todo-sweep.sh apply --phase 1|2|3a [--root DIR] [--dry-run] [--supersede ID:COVERING]...
#   todo-sweep.sh park  [--root DIR] [--dry-run] ID:REASON...
#
# --root DIR (default $TODO_QUEUE_DIR or .) holds dev/TODO/, dev/JOURNAL/ and
# dev/TODO/queue.md. plan prints TSV, one finding per line, in queue order:
#   ADD                 <id> <file> <title>        task file not in queue.md
#   REMOVE              <id> <file>                queue.md line with no task file
#   UNBLOCK             <id> <new-status> <ids>    every `Blocked by` blocker left dev/TODO/
#   ORDER_VIOLATION     <blocker> <blocked>        blocker queued behind the task it blocks
#   CLOSE_DONE          <id> <file>                status Done still in dev/TODO/
#   SUPERSEDE_CANDIDATE <id> <covering> <evidence> explicit "superseded/absorbed by T<id>" line
# apply re-plans from the current state (never trusts an old plan):
#   phase 1   ADD + REMOVE (queue membership sync; never reorders)
#   phase 2   UNBLOCK (status + struck dependency lines) + ORDER_VIOLATION
#             (`insert-before`, blockers sharing a target keep their order)
#   phase 3a  CLOSE_DONE and each --supersede ID:COVERING that plan listed as a
#             candidate: `## Closed (date)`, move to dev/JOURNAL/<date>-<file>
#             (git mv when tracked), drop the queue line
# park applies an owner-APPROVED list and never decides what to park: per ID:REASON
# set `status: Parked`, add `## Parked (date)` + the reason, move the file to
# dev/PARKING/ (git mv when tracked) and drop its queue line. An ID already in
# dev/PARKING/ is skipped (a stale queue line is dropped); a repeated ID keeps its first reason; epic-links sync and the commit stay with the caller.
# --dry-run prints `DRY-RUN <action>` lines and changes nothing. apply never
# commits. Exit: 0 ok, 2 usage, 3 nothing to do, 4 unexpected input (missing
# queue, malformed queue entry, duplicate id, journal target exists, a
# --supersede that is not a candidate, an ordering that does not converge, a
# park ID with no file in dev/TODO/ or whose dev/PARKING/ target exists);
# on 4 the queue and journal are left as they were.
set -euo pipefail

SW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SW_DIR/_lib.sh"
# shellcheck source=../../_queue/queue.sh
source "$TODO_LIB_REPO_ROOT/_queue/queue.sh"

SW_ID_RE='T[0-9]+-[0-9]+'
SW_TAB=$'\t'

function sw_die() { local code="$1"; shift; printf 'todo-sweep.sh: %s\n' "$*" >&2; exit "$code"; }
function sw_usage() {
  printf 'usage: todo-sweep.sh plan [--root DIR]\n       todo-sweep.sh apply --phase 1|2|3a [--root DIR] [--dry-run] [--supersede ID:COVERING]...\n       todo-sweep.sh park [--root DIR] [--dry-run] ID:REASON...\n' >&2
  exit 2
}

# ---- state -----------------------------------------------------------------
# FILES  "id<TAB>path" per dev/TODO/T*.md      QENT  "id<TAB>file<TAB>title" per queue line
# EFF    ids in effective order: queued tasks that have a file, then the ids ADD would append.
FILES="" QENT="" EFF=""

function sw_load() {
  TODO_DIR="$ROOT/dev/TODO"; QUEUE="${SW_QUEUE_OVERRIDE:-$TODO_DIR/queue.md}"
  JOURNAL_DIR="$ROOT/dev/JOURNAL"
  [ -f "$TODO_DIR/queue.md" ] || sw_die 4 "no dev/TODO/queue.md under $ROOT"
  FILES="" QENT="" EFF=""
  local f base id line parsed qid
  for f in "$TODO_DIR"/T*.md; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    id="$(grep -oE "^$SW_ID_RE" <<<"$base" || true)"
    [ -n "$id" ] || continue
    if grep -q "^${id}${SW_TAB}" <<<"$FILES"; then sw_die 4 "two task files carry id $id"; fi
    FILES="${FILES}${id}${SW_TAB}${f}"$'\n'
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- [T"*) ;; *) continue ;; esac
    parsed="$(todo-parse-queue-line "$line")" || sw_die 4 "malformed queue entry: $line"
    qid="${parsed%%"$SW_TAB"*}"
    if grep -q "^${qid}${SW_TAB}" <<<"$QENT"; then sw_die 4 "queue lists $qid twice"; fi
    QENT="${QENT}${parsed}"$'\n'
  done < "$QUEUE"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    qid="${line%%"$SW_TAB"*}"
    if sw_has_file "$qid"; then EFF="${EFF}${qid}"$'\n'; fi
  done <<<"$QENT"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    qid="${line%%"$SW_TAB"*}"
    if ! sw_queued "$qid"; then EFF="${EFF}${qid}"$'\n'; fi
  done <<<"$FILES"
}

function sw_has_file() { grep -q "^${1}${SW_TAB}" <<<"$FILES"; }
function sw_queued() { grep -q "^${1}${SW_TAB}" <<<"$QENT"; }
function sw_path() { awk -F'\t' -v id="$1" '$1==id { print $2; exit }' <<<"$FILES"; }
function sw_pos() { awk -v id="$1" '$0==id { print NR; exit }' <<<"$EFF"; }
function sw_qfield() { awk -F'\t' -v id="$1" -v n="$2" '$1==id { print $n; exit }' <<<"$QENT"; }

# Title for a queue line: the H1 minus a leading "T<id>:" (falls back to the slug).
function sw_title() {
  local path="$1" id="$2" t
  t="$(awk '/^# / { sub(/^# /, ""); print; exit }' "$path")"
  t="$(sed -E "s/^${id}:? *//" <<<"$t")"
  if [ -z "$t" ]; then t="${path##*/}"; t="${t#"$id"-}"; t="${t%.md}"; fi
  printf '%s' "$t" | tr '\t' ' '
}

# Blockers named by a `Blocked by T<id>[, T<id>...]` status; empty if not blocked.
function sw_blockers() {
  local status="$1"
  [[ "$status" =~ ^Blocked\ by\ T[0-9]+-[0-9]+ ]] || return 0
  sed -E "s/^Blocked by ($SW_ID_RE(,? +(and +)?$SW_ID_RE)*).*/\\1/" <<<"$status" | grep -oE "$SW_ID_RE"
}

function sw_next_status() { if grep -q '^## Design' "$1"; then echo Design; else echo Open; fi; }

# Task body without frontmatter and fenced code.
function sw_body() {
  awk '
    NR==1 && $0=="---" { fm=1; next }
    fm && $0=="---" { fm=0; next }
    fm { next }
    /^```/ { fence=!fence; next }
    !fence { print }' "$1"
}

# ---- plan ------------------------------------------------------------------
function sw_unblocked_ids() { # ids whose Blocked-by blockers have ALL left dev/TODO/
  local line id path status b all
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%%"$SW_TAB"*}"; path="${line#*"$SW_TAB"}"
    status="$(todo-fm-get "$path" status)"
    all="$(sw_blockers "$status")"; [ -n "$all" ] || continue
    local stale=1
    for b in $all; do sw_has_file "$b" && stale=0; done
    [ "$stale" = 1 ] && printf '%s\n' "$id"
  done <<<"$FILES"
  return 0
}

function sw_violations() { # "blocker<TAB>blocked" in queue order of the blocked task
  local id path status b pb pk
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    path="$(sw_path "$id")"; status="$(todo-fm-get "$path" status)"
    pk="$(sw_pos "$id")"
    for b in $(sw_blockers "$status"); do
      sw_has_file "$b" || continue
      pb="$(sw_pos "$b")"
      if [ -n "$pb" ] && [ -n "$pk" ] && [ "$pb" -gt "$pk" ]; then printf '%s\t%s\n' "$b" "$id"; fi
    done
  done <<<"$EFF"
  return 0
}

function sw_plan() {
  local line id path status title blk
  # 1. membership
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%%"$SW_TAB"*}"; path="${line#*"$SW_TAB"}"
    sw_queued "$id" || printf 'ADD\t%s\t%s\t%s\n' "$id" "${path##*/}" "$(sw_title "$path" "$id")"
  done <<<"$FILES"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%%"$SW_TAB"*}"
    sw_has_file "$id" || printf 'REMOVE\t%s\t%s\n' "$id" "$(sw_qfield "$id" 2)"
  done <<<"$QENT"
  # 2. stale blockers, then ordering
  for id in $(sw_unblocked_ids); do
    path="$(sw_path "$id")"; status="$(todo-fm-get "$path" status)"
    blk="$(sw_blockers "$status" | paste -sd, -)"
    printf 'UNBLOCK\t%s\t%s\t%s\n' "$id" "$(sw_next_status "$path")" "$blk"
  done
  sw_violations | while IFS= read -r line; do printf 'ORDER_VIOLATION\t%s\n' "$line"; done
  # 3a. closable
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    path="$(sw_path "$id")"; status="$(todo-fm-get "$path" status)"
    if [[ "$status" =~ ^Done($|[^A-Za-z]) ]]; then
      printf 'CLOSE_DONE\t%s\t%s\n' "$id" "${path##*/}"
    else
      sw_supersede_candidate "$id" "$path"
    fi
  done <<<"$EFF"
}

function sw_supersede_candidate() {
  local id="$1" path="$2" hit cover
  hit="$(sw_body "$path" | grep -iE "(supersed|absorb|subsum)[a-z]* +(in|into|by) +\\**$SW_ID_RE" | grep -v '^[[:space:]]*[-*]*[[:space:]]*~~' | head -n1 || true)"
  [ -n "$hit" ] || return 0
  cover="$(grep -oE "$SW_ID_RE" <<<"$hit" | grep -v "^${id}\$" | head -n1 || true)"
  [ -n "$cover" ] || return 0
  printf 'SUPERSEDE_CANDIDATE\t%s\t%s\t%s\n' "$id" "$cover" "$(printf '%s' "$hit" | tr '\t' ' ' | cut -c1-200)"
}

# ---- apply -----------------------------------------------------------------
DRY=0
function sw_do() { # <message>; true when the caller should really write
  if [ "$DRY" = 1 ]; then printf 'DRY-RUN %s\n' "$1"; return 1; fi
  printf '%s\n' "$1"; return 0
}

# Rewrite one file through a temp file (keeps the inode and mode).
function sw_rewrite() { local f="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"; }

function sw_set_status() {
  local path="$1" new="$2"
  SW_NEW="$new" awk '
    NR==1 && $0=="---" { fm=1; print; next }
    fm && $0=="---" { fm=0 }
    fm && !done && /^status:/ { print "status: " ENVIRON["SW_NEW"]; done=1; next }
    { print }' "$path" | sw_rewrite "$path"
}

function sw_strike() { # <path> <blocker> <suffix>: strike `## Dependencies` lines naming the blocker
  SW_ID="$2" SW_SUF="$3" awk '
    /^## / { dep = ($0 ~ /^## Dependencies/) }
    dep && index($0, ENVIRON["SW_ID"]) && $0 !~ /~~/ {
      pre=""; rest=$0
      if (match(rest, /^[ \t]*[-*] +/)) { pre=substr(rest, 1, RLENGTH); rest=substr(rest, RLENGTH+1) }
      sub(/[ \t]+$/, "", rest)
      print pre "~~" rest "~~ " ENVIRON["SW_SUF"]; next }
    { print }' "$1" | sw_rewrite "$1"
}

function sw_journal_of() { # journal file name for a task id, or ''
  local f
  for f in "$JOURNAL_DIR"/*"$1"-*.md; do [ -e "$f" ] && { printf '%s' "${f##*/}"; return 0; }; done
  return 0
}

function sw_apply_phase1() {
  local line id file title n=0
  while IFS=$'\t' read -r kind id file title; do
    case "$kind" in
      ADD) n=$((n+1)); if sw_do "ADDED $id"; then q_append "$QUEUE" "$id" "$file" "$title"; fi ;;
      REMOVE) n=$((n+1)); if sw_do "REMOVED $id"; then q_remove "$QUEUE" "$id"; fi ;;
    esac
  done < <(sw_plan)
  return $((n == 0 ? 3 : 0))
}

function sw_apply_phase2() {
  local n=0 id path status next j suf b pass blocked
  for id in $(sw_unblocked_ids); do
    n=$((n+1))
    path="$(sw_path "$id")"; status="$(todo-fm-get "$path" status)"
    next="$(sw_next_status "$path")"
    local rest; rest="$(sed -E "s/^Blocked by $SW_ID_RE(,? +(and +)?$SW_ID_RE)*//" <<<"$status")"
    if sw_do "UNBLOCKED $id -> ${next}${rest}"; then
      for b in $(sw_blockers "$status"); do
        j="$(sw_journal_of "$b")"
        if [ -n "$j" ]; then suf="✅ Done (see dev/JOURNAL/$j)"; else suf="✅ Resolved (no longer in dev/TODO)"; fi
        sw_strike "$path" "$b" "$suf"
      done
      sw_set_status "$path" "${next}${rest}"
    fi
  done
  # Ordering works on a scratch copy of the queue (later passes see earlier
  # moves); it replaces the real queue only once the order has converged.
  SW_QUEUE_OVERRIDE="$(mktemp)"; cp "$TODO_DIR/queue.md" "$SW_QUEUE_OVERRIDE"; QUEUE="$SW_QUEUE_OVERRIDE"
  for pass in $(seq 1 25); do
    sw_load
    local viol; viol="$(sw_violations)"
    [ -n "$viol" ] || break
    if [ "$pass" = 25 ]; then rm -f "$QUEUE"; sw_die 4 "blocker ordering does not converge (cycle?): $(tr '\t\n' '> ' <<<"$viol")"; fi
    for blocked in $(printf '%s\n' "$viol" | cut -f2 | awk '!s[$0]++'); do
      local group; group="$(printf '%s\n' "$viol" | awk -F'\t' -v t="$blocked" '$2==t { print $1 }' | while IFS= read -r b; do printf '%s %s\n' "$(sw_pos "$b")" "$b"; done | sort -n | cut -d' ' -f2)"
      for b in $group; do
        n=$((n+1)); sw_do "MOVED $b before $blocked" || true
        q_insert_before "$QUEUE" "$b" "$(sw_qfield "$b" 2)" "$(sw_qfield "$b" 3)" "$blocked"
      done
    done
  done
  if [ "$DRY" = 0 ] && [ "$n" -gt 0 ]; then cat "$QUEUE" > "$TODO_DIR/queue.md"; fi
  rm -f "$QUEUE"; unset SW_QUEUE_OVERRIDE
  return $((n == 0 ? 3 : 0))
}

function sw_apply_phase3a() {
  local n=0 kind id file cover why cands date line c ok
  date="$(bash "$TODO_LIB_REPO_ROOT/_date/date.sh" today)"
  cands="$(sw_plan | awk -F'\t' '$1=="SUPERSEDE_CANDIDATE"')"
  for c in ${SUPERSEDE[@]+"${SUPERSEDE[@]}"}; do
    printf '%s\n' "$cands" | awk -F'\t' -v i="${c%%:*}" -v v="${c#*:}" '$2==i && $3==v { f=1 } END { exit !f }' \
      || sw_die 4 "--supersede $c is not a SUPERSEDE_CANDIDATE in the plan"
  done
  local work=""
  while IFS=$'\t' read -r kind id file cover; do
    case "$kind" in
      CLOSE_DONE) work="${work}${id}${SW_TAB}${file}${SW_TAB}marked Done"$'\n' ;;
      SUPERSEDE_CANDIDATE)
        ok=0; for c in ${SUPERSEDE[@]+"${SUPERSEDE[@]}"}; do [ "$c" = "$id:$file" ] && ok=1; done
        [ "$ok" = 1 ] && work="${work}${id}${SW_TAB}$(sw_path "$id" | sed 's|.*/||')${SW_TAB}superseded by ${file}"$'\n' ;;
    esac
  done < <(sw_plan)
  # Fail closed before writing anything.
  while IFS=$'\t' read -r id file why; do
    [ -n "$id" ] || continue
    [ ! -e "$JOURNAL_DIR/$date-$file" ] || sw_die 4 "dev/JOURNAL/$date-$file already exists"
  done <<<"$work"
  while IFS=$'\t' read -r id file why; do
    [ -n "$id" ] || continue
    n=$((n+1))
    if sw_do "CLOSED $id ($why) -> dev/JOURNAL/$date-$file"; then
      local src="$TODO_DIR/$file"
      grep -q '^## Closed (' "$src" || printf '\n## Closed (%s)\n\n%s\n' "$date" "$why" >> "$src"
      mkdir -p "$JOURNAL_DIR"
      if git -C "$ROOT" ls-files --error-unmatch "dev/TODO/$file" >/dev/null 2>&1; then
        git -C "$ROOT" mv "dev/TODO/$file" "dev/JOURNAL/$date-$file"
      else
        mv "$src" "$JOURNAL_DIR/$date-$file"
      fi
      q_remove "$QUEUE" "$id"
    fi
  done <<<"$work"
  return $((n == 0 ? 3 : 0))
}

function sw_park() {
  local date item id reason src file n=0 todo_ids=""
  date="$(bash "$TODO_LIB_REPO_ROOT/_date/date.sh" today)"
  # Validate everything first (fail closed before writing anything).
  for item in "${PARK[@]}"; do
    id="${item%%:*}"
    if sw_has_file "$id"; then
      file="$(sw_path "$id")"; file="${file##*/}"
      [ ! -e "$ROOT/dev/PARKING/$file" ] || sw_die 4 "dev/PARKING/$file already exists"
      [ -n "$(todo-fm-get "$(sw_path "$id")" status)" ] || sw_die 4 "$id has no status: line to set"
      todo_ids="$todo_ids $id"
    elif [ -n "$(compgen -G "$ROOT/dev/PARKING/$id-*.md" || true)" ]; then
      :
    else
      sw_die 4 "$id has no file in dev/TODO/ or dev/PARKING/"
    fi
  done
  for item in "${PARK[@]}"; do
    id="${item%%:*}"; reason="${item#*:}"
    case " $todo_ids " in *" $id "*) ;; *) printf 'SKIPPED %s (already in dev/PARKING)\n' "$id"; [ "$DRY" = 1 ] || q_remove "$QUEUE" "$id"; continue ;; esac
    src="$(sw_path "$id")"; file="${src##*/}"
    n=$((n+1))
    if sw_do "PARKED $id -> dev/PARKING/$file"; then
      sw_set_status "$src" Parked
      printf '\n## Parked (%s)\n\n%s\n' "$date" "$reason" >> "$src"
      mkdir -p "$ROOT/dev/PARKING"
      if git -C "$ROOT" ls-files --error-unmatch "dev/TODO/$file" >/dev/null 2>&1; then
        git -C "$ROOT" mv "dev/TODO/$file" "dev/PARKING/$file"
      else
        mv "$src" "$ROOT/dev/PARKING/$file"
      fi
      q_remove "$QUEUE" "$id"
    fi
  done
  return $((n == 0 ? 3 : 0))
}

# ---- main ------------------------------------------------------------------
function todo-sweep-main() {
  local cmd="${1:-}" phase=""
  [ $# -gt 0 ] || sw_usage
  shift
  ROOT="${TODO_QUEUE_DIR:-.}"; SUPERSEDE=(); PARK=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || sw_usage; ROOT="$2"; shift 2 ;;
      --phase) [ $# -ge 2 ] || sw_usage; phase="$2"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      --supersede) [ $# -ge 2 ] || sw_usage; [[ "$2" =~ ^$SW_ID_RE:$SW_ID_RE$ ]] || sw_usage; SUPERSEDE+=("$2"); shift 2 ;;
      *) [ "$cmd" = park ] && [[ "$1" =~ ^$SW_ID_RE:.+ ]] || sw_usage; case " ${PARK[*]:-} " in *" ${1%%:*}:"*) ;; *) PARK+=("$1") ;; esac; shift ;;
    esac
  done
  [ -d "$ROOT" ] || sw_die 2 "no such directory: $ROOT"
  ROOT="$(cd "$ROOT" && pwd)"
  case "$cmd" in
    plan)
      [ -z "$phase" ] && [ "$DRY" = 0 ] && [ ${#SUPERSEDE[@]} -eq 0 ] || sw_usage
      sw_load
      local out; out="$(sw_plan)"
      [ -n "$out" ] || return 3
      printf '%s\n' "$out" ;;
    apply)
      [ -z "${SUPERSEDE[0]:-}" ] || [ "$phase" = 3a ] || sw_usage
      case "$phase" in 1|2|3a) ;; *) sw_usage ;; esac
      sw_load
      "sw_apply_phase${phase}" ;;
    park)
      [ -z "$phase" ] && [ ${#SUPERSEDE[@]} -eq 0 ] && [ ${#PARK[@]} -gt 0 ] || sw_usage
      sw_load
      sw_park ;;
    *) sw_usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  todo-sweep-main "$@"
fi
