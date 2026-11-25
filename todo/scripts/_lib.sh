#!/usr/bin/env bash
# Shared parsing helpers for todo-list.sh / todo-next.sh (T20260914-359646).
# Sourceable only — no CLI dispatch of its own.
set -euo pipefail

# Parse one `- [T{id}](path): title` dev/TODO/queue.md line.
# Prints: id<TAB>relpath<TAB>title ; exits 1 (no output) if the line doesn't match.
function todo-parse-queue-line() {
  local line="$1"
  # A pattern variable, not an inline `=~` literal: bash's own parser (not
  # the regex engine) mis-tokenizes unquoted parens inside an inline `[[
  # =~ ]]` pattern containing a `[^]...]` bracket expression — confirmed by
  # a real failure while writing this function's own test (T20260914-359646).
  local pat='^- \[([^]]+)\]\(([^)]+)\): (.*)$'
  if [[ "$line" =~ $pat ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# Read one YAML frontmatter field from a task file. Prints '' (exit 0) if
# the field is absent or the file has no frontmatter block.
function todo-fm-get() {
  local file="$1" field="$2"
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ "^"f":" { sub("^"f":[ ]?", ""); print; exit }
  ' "$file"
}

# --- gated statuses (not auto-pickable) ---------------------------------------
# One shared definition, used by todo-next.sh (--skip-gated) and autopilot-state.sh
# (eligible). Exit 0 when a status value is not auto-pickable: only a `Blocked by ...`
# dependency status (case-insensitive). The words BLOCKED, SUPERVISED, "needs manual" and
# "sign-off" are plain prose now, never a gate (d174, T20261124-381200).
function todo-gated() {
  printf '%s' "${1:-}" | grep -qiE '(^|[^[:alpha:]])blocked by([^[:alpha:]]|$)'
}

# --- dependencies (compat reader, epic E3, T20261124-320024) -------------------
# Prints the task ids a task depends on, one per line, de-duplicated: the ids in
# its `depends_on:` (flow `[T1, T2]` or block list form) followed by the ids in a
# legacy `status: Blocked by T..` (so old and new files read the same while
# several repos run different plugin versions). Prints nothing when it has none.
# A task with only `depends_on:` keeps its real status, so todo-gated never
# skips it; only the legacy status word does. Read-only.
function todo-deps() {
  local file="$1"
  {
    tr -d '\r' < "$file" | awk '
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---" { exit }
      infm && /^depends_on:/ { indep=1; sub(/#.*$/, ""); print; next }
      infm && indep && /^[[:space:]]*-/ { sub(/#.*$/, ""); print; next }
      infm && indep && /^[[:space:]]*(#.*)?$/ { next }
      infm && indep { indep=0 }
    '
    local status
    status="$(todo-fm-get "$file" status)"
    case "$status" in
      [Bb]locked\ by*) printf '%s\n' "$status" ;;
    esac
  } | grep -oE 'T[0-9]{8}-[0-9]{6}' | awk '!seen[$0]++' || true
}

# --- legacy `blocks:` and derived dependants (T20261125-264487) ---------------
# `depends_on:` is the only authored relation. Dependants (what a task holds up)
# are derived from its inverse over the board. An old `blocks: [X]` line on task A
# still reads as "X depends on A" during the migration window (compat reader):
# it warns on stderr, never fails. `todo-deps.sh migrate` rewrites those lines.

# Ids named by a task's legacy `blocks:` line (flow or block list), one per line,
# de-duplicated. Silent; use todo-dependants for the warned, board-aware view.
function todo-legacy-blocks() {
  local file="$1"
  tr -d '\r' < "$file" | awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^blocks:/ { inb=1; sub(/#.*$/, ""); print; next }
    infm && inb && /^[[:space:]]*-/ { sub(/#.*$/, ""); print; next }
    infm && inb && /^[[:space:]]*(#.*)?$/ { next }
    infm && inb { inb=0 }
  ' | grep -oE 'T[0-9]{8}-[0-9]{6}' | awk '!seen[$0]++' || true
}

# Task ids that depend on <id>, one per line, de-duplicated, in board order:
# every task in <todo-dir> whose todo-deps names <id>, then the open ids in <id>'s
# own legacy `blocks:` line (one stderr warning per file carrying it). Read-only.
function todo-dependants() {
  local id="$1" dir="$2"
  _todo-dependants-raw "$id" "$dir" | awk '!seen[$0]++'
}
function _todo-dependants-raw() {
  local id="$1" dir="$2" own legacy x
  # One awk pass over the board (no per-file forks): every task whose depends_on
  # or legacy `Blocked by` status names <id>.
  local files=("$dir"/T*.md)
  if [ -f "${files[0]}" ]; then
    awk -v id="$id" '
      function flush() { if (hit && substr(base, 1, 16) != id) print substr(base, 1, 16); hit=0 }
      FNR==1 { flush(); infm=0; indep=0; closed=0; base=FILENAME; sub(/^.*\//, "", base) }
      { sub(/\r$/, "") }
      FNR==1 && $0=="---" { infm=1; next }
      infm && $0=="---" { infm=0; closed=1; next }
      !infm { next }
      /^depends_on:/ { indep=1; line=$0; sub(/#.*$/, "", line); if (index(line, id)) hit=1; next }
      indep && /^[[:space:]]*-/ { line=$0; sub(/#.*$/, "", line); if (index(line, id)) hit=1; next }
      indep && /^[[:space:]]*(#.*)?$/ { next }
      { indep=0 }
      /^status:[ \t]*[Bb]locked by/ { if (index($0, id)) hit=1 }
      END { flush() }
    ' "${files[@]}"
  fi
  own="$(compgen -G "$dir/${id}-*.md" | head -1 || true)"
  if [ -n "$own" ]; then
    legacy="$(todo-legacy-blocks "$own")"
    if [ -n "$legacy" ]; then
      printf 'warning: %s carries a legacy blocks: line; depends_on is the only authored field (migration: todo-deps.sh migrate, T20261125-366351)\n' "${own##*/}" >&2
      for x in $legacy; do
        if compgen -G "$dir/${x}-*.md" > /dev/null 2>&1; then printf '%s\n' "$x"; fi
      done
    fi
  fi
  return 0
}

# Claim-state verdict for one task id: mine|peer:<claimant>|reclaimable:<claimant>|unclaimed
# $2 (optional) overrides the repo root task_claim.sh is invoked from — tests
# pass a throwaway task file's directory; real callers omit it (defaults to
# this script's own repo root).
function todo-claim-state() {
  local id="$1" repo_root="${2:-$TODO_LIB_REPO_ROOT}"
  if [ "${CCXP_PEER_MODE:-1}" = "0" ]; then
    printf 'unclaimed\n'
    return 0
  fi
  local line status claimed_by
  line="$(bash "$repo_root/_session/task_claim.sh" read "$id" 2>/dev/null || true)"
  status="${line%%$'\t'*}"
  if [ "$line" = "$status" ]; then
    claimed_by=""
  else
    claimed_by="${line#*$'\t'}"
  fi
  if [ -z "$claimed_by" ]; then
    printf 'unclaimed\n'
    return 0
  fi
  local mine
  mine="$(bash "$repo_root/_session/task_claim.sh" claimant-id 2>/dev/null || true)"
  if [ "$claimed_by" = "$mine" ]; then
    printf 'mine\n'
    return 0
  fi
  local verdict
  verdict="$(bash "$repo_root/_session/task_claim.sh" reclaimable "$id" 2>/dev/null || true)"
  if [ "$verdict" = "reclaimable" ]; then
    printf 'reclaimable:%s\n' "$claimed_by"
  else
    printf 'peer:%s\n' "$claimed_by"
  fi
}

# Print the ISO date (YYYY-MM-DD) of the Monday that starts the current
# week. Same logic as _session/task_claim.sh's private _tc_current_monday
# (weekday-offset subtraction, not `date -d 'monday'`, which resolves to
# the NEXT Monday on any day that isn't itself Monday — a real bug caught
# by an independent PR #73 review, 2026-09-22). Respects SESSION_TODAY for
# testability, same hook as _tc_current_monday/iteration.sh.
function todo-current-monday() {
  local today="${SESSION_TODAY:-$(date +%F)}"
  python3 -c "
import datetime
d = datetime.date.fromisoformat('${today}')
print((d - datetime.timedelta(days=d.weekday())).isoformat())
"
}

# Repo root this lib was sourced from — callers rely on this for locating
# _session/task_claim.sh, dev/TODO/, etc. relative to the *sourcing* script,
# not the caller's own cwd.
TODO_LIB_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Normalised frontmatter `type:` (lowercase; quotes, trailing comment and CR
# stripped), matching what lint_tasks.py accepts.
function todo-task-type() {
  todo-fm-get "$1" type | tr -d '\r"'"'" | sed -E 's/^[[:space:]]+//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'
}

# Effective autopilot tier of a task file: the frontmatter `tier:` (1..4), or 3
# when absent or invalid (lint_tasks.py rejects an invalid value; reading stays
# lenient so one bad file never stops selection).
function todo-tier() {
  local v
  v="$(todo-fm-get "$1" tier | tr -d '\r"'"'" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in 1|2|3|4) printf '%s\n' "$v" ;; *) printf '3\n' ;; esac
}
