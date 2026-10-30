#!/usr/bin/env bash
# _queue/queue-op.sh — the mechanical half of /stage, /top and /bottom:
# resolve task ids to dev/TODO files, expand blocker chains, edit queue.md
# through queue.sh (never by hand) and print the confirmation block. Landing
# the change (branch, PR, merge) stays with the skill (_gh/land.sh, /address-pr).
#
#   queue-op.sh stage   [--repo DIR] [--dry-run] T<id>...
#   queue-op.sh top     [--repo DIR] [--dry-run] [--before T<id>] T<id>...
#   queue-op.sh bottom  [--repo DIR] [--dry-run] T<id>...
#
# --repo DIR (default .) holds dev/TODO/. Every id must resolve to exactly one
# dev/TODO/T<id>-*.md BEFORE queue.md is touched; any failure leaves it as it was.
#   stage   adds missing ids: appended, or immediately before the frontmost queued
#           task it blocks (its own `blocks:`, or that task's `status: Blocked by`).
#           Never moves a queued id.
#   top     expands each id into its `status: Blocked by T<id>` chain (blocker first,
#           10 hops max, cycle = exit 4), then moves the list to the front (first
#           listed wins slot 1) or, with --before, immediately above T<id>
#           (which must already be queued), keeping list order.
#   bottom  moves the ids to the back (first listed wins the very last slot).
# A repeated id keeps its first occurrence. --dry-run computes and prints but
# does not write queue.md.
# stdout: the confirmation block, then `CHANGED=0|1` and `UNTRACKED=<paths>`
# (task files not yet tracked by git, repo-relative, space separated: pass them
# to land.sh). Prose diagnostics go to stderr.
# Exit: 0 ok, 1 unresolvable id / --before target not queued, 2 usage,
# 3 stage had nothing to add, 4 blocker cycle, chain over 10 hops, or the
# --before target inside the expanded list.
set -euo pipefail

QO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
source "$QO_DIR/queue.sh"

QO_ID_RE='T[0-9]+-[0-9]+'
QO_TAB=$'\t'

function qo_die() { local code="$1"; shift; printf 'queue-op.sh: %s\n' "$*" >&2; exit "$code"; }
function qo_usage() {
  printf 'usage: queue-op.sh stage|bottom [--repo DIR] [--dry-run] T<id>...\n       queue-op.sh top [--repo DIR] [--dry-run] [--before T<id>] T<id>...\n' >&2
  exit 2
}

# ---- task files -------------------------------------------------------------
# qo_file <id>: the single dev/TODO/<id>-*.md path, or '' when none/ambiguous.
function qo_file() {
  local f found="" n=0
  for f in "$REPO/dev/TODO/$1"-*.md; do
    [ -e "$f" ] || continue
    found="$f"; n=$((n+1))
  done
  [ "$n" -eq 1 ] && printf '%s' "$found"
  return 0
}

# qo_resolve <id>: file path on stdout; exit 1 (after a diagnosis) if unresolvable.
function qo_resolve() {
  local id="$1" f
  f="$(qo_file "$id")"
  if [ -z "$f" ]; then
    if [ -n "$(compgen -G "$REPO/dev/TODO/$id-*.md" || true)" ]; then
      qo_die 1 "$id matches several files in dev/TODO/"
    fi
    (cd "$REPO" && bash "$QO_DIR/../_taskid/in-this-repo.sh" "$id") >&2 || true
    qo_die 1 "$id does not resolve to a file in dev/TODO/ of $REPO"
  fi
  printf '%s' "$f"
}

function qo_fm() { # <file> <field>: one frontmatter value ('' if absent)
  awk -v f="$2" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && index($0, f ":") == 1 { sub("^" f ":[ ]*", ""); print; exit }' "$1"
}

# Title: the H1 minus a leading "T<id>:" (falls back to the slug).
function qo_title() {
  local file="$1" id="$2" t
  t="$(awk '/^# / { sub(/^# /, ""); print; exit }' "$file")"
  t="$(sed -E "s/^${id}:? *//" <<<"$t")"
  if [ -z "$t" ]; then t="${file##*/}"; t="${t#"$id"-}"; t="${t%.md}"; fi
  printf '%s' "$t" | tr '\t' ' '
}

# Blocker ids named by a `Blocked by T<id>[, T<id>...]` status (case-insensitive
# prefix, trailing notes ignored); nothing if the status is not a block.
function qo_blockers() {
  local s="$1"
  s="$(sed -E 's/^[Bb][Ll][Oo][Cc][Kk][Ee][Dd] +[Bb][Yy] +/Blocked by /' <<<"$s")"
  [[ "$s" =~ ^Blocked\ by\ T[0-9]+-[0-9]+ ]] || return 0
  sed -E "s/^Blocked by ($QO_ID_RE(,? +(and +)?$QO_ID_RE)*).*/\\1/" <<<"$s" | grep -oE "$QO_ID_RE"
}

# ---- queue views ------------------------------------------------------------
# qo_entries: "<n><TAB><id><TAB><title>" per queue line of $QT, in order.
function qo_entries() {
  local pat='^- \[([^]]+)\]\(([^)]+)\): (.*)$' line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- ["*) ;; *) continue ;; esac
    [[ "$line" =~ $pat ]] || continue
    n=$((n+1))
    printf '%s\t%s\t%s\n' "$n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  done < "$QT"
}
function qo_total() { grep -c '^- \[' "$QT" || true; }

# ---- blocker chain (top) ----------------------------------------------------
# qo_chain <id>: ids in dependency order, deepest blocker first, <id> last.
function qo_chain() {
  local id="$1" cur="$1" hops=0 seen=" $1 " b chain=() out="" x
  while :; do
    b="$(qo_blockers "$(qo_fm "$(qo_file "$cur")" status)" | head -n1)"
    [ -n "$b" ] || break
    [ -n "$(qo_file "$b")" ] || break  # closed or in another repo: nothing open to reorder
    hops=$((hops+1))
    [ "$hops" -le 10 ] || qo_die 4 "blocker chain of $id is longer than 10 hops (cycle or data error)"
    case "$seen" in *" $b "*) qo_die 4 "blocker cycle through $b starting at $id" ;; esac
    seen="$seen$b "
    chain=("$b" ${chain[@]+"${chain[@]}"})
    cur="$b"
  done
  for x in ${chain[@]+"${chain[@]}"}; do out="${out}${x}"$'\n'; done
  printf '%s%s\n' "$out" "$id"
}

# ---- state ------------------------------------------------------------------
IDS=() EXP=() NOTE=()   # given ids; expanded ids (top); "<id><TAB>blocker of <x>" notes

function qo_in() { local x="$1"; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

function qo_note() { local l; for l in ${NOTE[@]+"${NOTE[@]}"}; do [ "${l%%"$QO_TAB"*}" = "$1" ] && printf ' %s' "[${l#*"$QO_TAB"}]"; done; return 0; }

function qo_line() { printf '%s. %s: %s%s\n' "$1" "$2" "$3" "$(qo_note "$2")"; }

function qo_show_range() { # <from> <to>
  local n id title
  while IFS=$'\t' read -r n id title; do
    [ "$n" -ge "$1" ] && [ "$n" -le "$2" ] && qo_line "$n" "$id" "$title"
  done < <(qo_entries)
  return 0
}

# ---- verbs ------------------------------------------------------------------
function qo_stage() {
  local id file title target
  for id in "${IDS[@]}"; do
    file="$(qo_file "$id")"; title="$(qo_title "$file" "$id")"
    if q_has "$QT" "$id"; then
      printf '%s: already at position %s of %s — no change\n' "$id" "$(q_pos "$QT" "$id")" "$(qo_total)"
      continue
    fi
    target="$(qo_frontmost_blocked "$id" "$file")"
    if [ -n "$target" ]; then
      q_insert_before "$QT" "$id" "${file##*/}" "$title" "$target"
      printf '%s: inserted at position %s of %s, immediately before %s (it blocks %s)\n' "$id" "$(q_pos "$QT" "$id")" "$(qo_total)" "$target" "$target"
    else
      q_append "$QT" "$id" "${file##*/}" "$title"
      printf '%s: appended at position %s of %s\n' "$id" "$(q_pos "$QT" "$id")" "$(qo_total)"
    fi
  done
}

# Frontmost queued task that <id> blocks (its `blocks:` field, or the queued
# task's own `Blocked by` status); '' if none.
function qo_frontmost_blocked() {
  local id="$1" file="$2" n tid title tf declared
  declared="$(qo_fm "$file" blocks | grep -oE "$QO_ID_RE" || true)"
  while IFS=$'\t' read -r n tid title; do
    [ "$tid" != "$id" ] || continue
    if grep -qx "$tid" <<<"$declared"; then printf '%s' "$tid"; return 0; fi
    tf="$(qo_file "$tid")"; [ -n "$tf" ] || continue
    if qo_blockers "$(qo_fm "$tf" status)" | grep -qx "$id"; then printf '%s' "$tid"; return 0; fi
  done < <(qo_entries)
  return 0
}

function qo_top() {
  local i id file first tpos
  if [ -n "$BEFORE" ]; then
    for id in "${EXP[@]}"; do               # forward: each insert lands below the earlier ones
      file="$(qo_file "$id")"
      q_insert_before "$QT" "$id" "${file##*/}" "$(qo_title "$file" "$id")" "$BEFORE"
    done
    first="$(q_pos "$QT" "${EXP[0]}")"; tpos="$(q_pos "$QT" "$BEFORE")"
    printf 'New order around %s:\n' "$BEFORE"
    qo_show_range "$((first > 1 ? first - 1 : 1))" "$tpos"
  else
    for ((i=${#EXP[@]}-1; i>=0; i--)); do   # reverse so the first listed ends up first
      id="${EXP[$i]}"; file="$(qo_file "$id")"
      q_top "$QT" "$id" "${file##*/}" "$(qo_title "$file" "$id")"
    done
    printf 'New queue order:\n'
    qo_show_range 1 "$(( ${#EXP[@]} + 2 ))"
  fi
}

function qo_bottom() {
  local i id file total
  for ((i=${#IDS[@]}-1; i>=0; i--)); do
    id="${IDS[$i]}"; file="$(qo_file "$id")"
    q_bottom "$QT" "$id" "${file##*/}" "$(qo_title "$file" "$id")"
  done
  total="$(qo_total)"
  printf 'New queue order (tail):\n'
  qo_show_range "$(( total - ${#IDS[@]} > 1 ? total - ${#IDS[@]} : 1 ))" "$total"
}

# ---- main -------------------------------------------------------------------
function queue_op_main() {
  local verb="${1:-}" arg id DRY=0
  [ $# -gt 0 ] || qo_usage
  shift
  case "$verb" in stage|top|bottom) ;; *) qo_usage ;; esac
  REPO="." BEFORE=""
  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --repo) [ $# -ge 2 ] || qo_usage; REPO="$2"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      --before)
        [ "$verb" = top ] && [ $# -ge 2 ] && [ -z "$BEFORE" ] || qo_usage
        [[ "$2" =~ ^$QO_ID_RE$ ]] || qo_usage
        BEFORE="$2"; shift 2 ;;
      -*) qo_usage ;;
      *)
        [[ "$arg" =~ ^$QO_ID_RE$ ]] || qo_usage
        qo_in "$arg" ${IDS[@]+"${IDS[@]}"} || IDS+=("$arg")
        shift ;;
    esac
  done
  [ ${#IDS[@]} -gt 0 ] || qo_usage
  [ -d "$REPO" ] || qo_die 2 "no such directory: $REPO"
  REPO="$(cd "$REPO" && pwd)"

  # Resolve everything before touching queue.md (all-or-nothing).
  local real="$REPO/dev/TODO/queue.md"
  for id in "${IDS[@]}"; do qo_resolve "$id" >/dev/null; done
  if [ -n "$BEFORE" ]; then
    qo_resolve "$BEFORE" >/dev/null
    { [ -f "$real" ] && q_has "$real" "$BEFORE"; } || qo_die 1 "$BEFORE is not in queue.md; /stage it first or drop --before"
  fi
  if [ "$verb" = top ]; then
    local chain rev l k x
    for id in "${IDS[@]}"; do
      rev=(); chain="$(qo_chain "$id")"
      while IFS= read -r l; do [ -n "$l" ] && rev+=("$l"); done <<<"$chain"
      for ((k=0; k<${#rev[@]}; k++)); do
        x="${rev[$k]}"
        if [ "$k" -lt $((${#rev[@]} - 1)) ]; then NOTE+=("${x}${QO_TAB}blocker of ${rev[$((k+1))]}, pulled up"); fi
        qo_in "$x" ${EXP[@]+"${EXP[@]}"} || EXP+=("$x")
      done
    done
    if [ -n "$BEFORE" ] && qo_in "$BEFORE" "${EXP[@]}"; then
      qo_die 4 "$BEFORE is in the expanded list (it blocks a given task); --before it makes no sense"
    fi
    for id in "${EXP[@]}"; do qo_resolve "$id" >/dev/null; done
  fi

  # Work on a scratch copy; write back only on success.
  QT="$(mktemp)"
  trap 'rm -f "$QT"' EXIT
  if [ -f "$real" ]; then cat "$real" > "$QT"; else printf '%s\n' "$Q_HEADER" > "$QT"; fi
  local before_sum; before_sum="$(cksum < "$QT")"
  [ "$DRY" = 1 ] && printf 'DRY-RUN queue.md will not be written\n'
  case "$verb" in
    stage) qo_stage ;;
    top) qo_top ;;
    bottom) qo_bottom ;;
  esac
  local changed=0
  [ "$(cksum < "$QT")" = "$before_sum" ] || changed=1
  # A missing queue.md counts as changed once it is created.
  [ -f "$real" ] || changed=1
  if [ "$changed" = 1 ] && [ "$DRY" = 0 ]; then
    mkdir -p "$(dirname "$real")"; cat "$QT" > "$real"
  fi

  local untracked="" rel all=("${IDS[@]}")
  [ "$verb" = top ] && all=("${EXP[@]}")
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for id in "${all[@]}"; do
      rel="dev/TODO/$(qo_file "$id" | sed 's|.*/||')"
      git -C "$REPO" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || untracked="${untracked:+$untracked }$rel"
    done
  fi
  printf 'CHANGED=%s\nUNTRACKED=%s\n' "$changed" "$untracked"
  if [ "$verb" = stage ] && [ "$changed" = 0 ]; then return 3; fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  queue_op_main "$@"
fi
