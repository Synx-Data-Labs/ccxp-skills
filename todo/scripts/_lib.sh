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

# Repo root this lib was sourced from — callers rely on this for locating
# _session/task_claim.sh, dev/TODO/, etc. relative to the *sourcing* script,
# not the caller's own cwd.
TODO_LIB_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
