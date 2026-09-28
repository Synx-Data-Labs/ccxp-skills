#!/usr/bin/env bash
# _docs/doc-impact.sh — flag repo docs that may be stale given a code change.
#
# Usage:
#   bash _docs/doc-impact.sh [BASE_REF]   # default: origin/main
#
# Exit codes:
#   0 — nothing flagged (no changes, docs-only change, or no stale docs found)
#   1 — one or more candidate stale docs found
#   2 — usage error or not inside a git repo
#
# Sourceable: all logic lives inside doc_impact(); the dispatch at the bottom
# fires only when executed directly.
set -uo pipefail

doc_impact() {
  local base_ref="${1:-origin/main}"

  # ------------------------------------------------------------------
  # 1. Resolve repo root; cd there. Exit 2 if not a git repo.
  # ------------------------------------------------------------------
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'error: not inside a git repository\n' >&2
    return 2
  }
  cd "$repo_root"

  # ------------------------------------------------------------------
  # 2. Get changed files in the range.
  # ------------------------------------------------------------------
  local changed
  changed="$(git diff --name-only "${base_ref}...HEAD" 2>/dev/null)" || {
    printf 'error: git diff failed for range %s...HEAD\n' "$base_ref" >&2
    return 2
  }

  if [ -z "$changed" ]; then
    printf '✅ no changes in %s...HEAD\n' "$base_ref"
    return 0
  fi

  # ------------------------------------------------------------------
  # 3. Build tracked doc set via git ls-files.
  #    Patterns: README*, CLAUDE.md, dev/guidelines.md,
  #    dev/guidelines/*.md, */SKILL.md, SKILL.md, docs/**/*.md
  # ------------------------------------------------------------------
  local docs
  docs="$(git ls-files \
    'README*' \
    'CLAUDE.md' \
    'dev/guidelines.md' \
    'dev/guidelines/*.md' \
    '*/SKILL.md' \
    'SKILL.md' \
    'docs/*.md' \
    'docs/**/*.md' \
    2>/dev/null | sort -u)"

  # ------------------------------------------------------------------
  # 4. Partition changed into touched_docs and nondoc.
  # ------------------------------------------------------------------
  local touched_docs=""
  local nondoc=""
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s\n' "$docs" | grep -qxF "$f"; then
      touched_docs="${touched_docs}${f}"$'\n'
    else
      nondoc="${nondoc}${f}"$'\n'
    fi
  done <<< "$changed"

  if [ -z "$nondoc" ]; then
    printf '✅ docs-only change\n'
    return 0
  fi

  # ------------------------------------------------------------------
  # 5. Signal 1 — reference match.
  #    For each nondoc file, for each doc NOT in touched_docs, if the
  #    doc contains the file's basename, flag it.
  # ------------------------------------------------------------------
  # flagged: associative array doc -> reasons (newline-separated)
  declare -A flagged=()

  local nf basename doc
  while IFS= read -r nf; do
    [ -z "$nf" ] && continue
    basename="$(basename "$nf")"
    while IFS= read -r doc; do
      [ -z "$doc" ] && continue
      # Skip if this doc was already touched in the same change.
      if printf '%s\n' "$touched_docs" | grep -qxF "$doc"; then
        continue
      fi
      # Skip if file doesn't exist (could have been deleted).
      [ -f "$doc" ] || continue
      if grep -qF -- "$basename" "$doc"; then
        local reason="references changed file '${basename}'"
        if [ -n "${flagged[$doc]+set}" ]; then
          flagged[$doc]="${flagged[$doc]}"$'\n'"$reason"
        else
          flagged[$doc]="$reason"
        fi
      fi
    done <<< "$docs"
  done <<< "$nondoc"

  # ------------------------------------------------------------------
  # 6. Signal 2 — category heuristic (newly-ADDED files only).
  # ------------------------------------------------------------------
  local added
  added="$(git diff --name-only --diff-filter=A "${base_ref}...HEAD" 2>/dev/null)" || added=""

  local af af_base
  while IFS= read -r af; do
    [ -z "$af" ] && continue

    # a) New workflow file → flag every top-level README*
    if [[ "$af" =~ ^\.github/workflows/[^/]+\.(yml|yaml)$ ]]; then
      af_base="$(basename "$af")"
      while IFS= read -r doc; do
        [ -z "$doc" ] && continue
        [[ "$doc" =~ ^README ]] || continue
        printf '%s\n' "$touched_docs" | grep -qxF "$doc" && continue
        local reason="new workflow '${af_base}' — README may need an entry"
        if [ -n "${flagged[$doc]+set}" ]; then
          flagged[$doc]="${flagged[$doc]}"$'\n'"$reason"
        else
          flagged[$doc]="$reason"
        fi
      done <<< "$docs"
      continue
    fi

    # b) New action → flag top-level README*
    if [[ "$af" =~ ^actions/[^/]+/action\.(yml|yaml)$ ]]; then
      local action_name
      action_name="$(basename "$(dirname "$af")")"
      while IFS= read -r doc; do
        [ -z "$doc" ] && continue
        [[ "$doc" =~ ^README ]] || continue
        printf '%s\n' "$touched_docs" | grep -qxF "$doc" && continue
        local reason="new action '${action_name}'"
        if [ -n "${flagged[$doc]+set}" ]; then
          flagged[$doc]="${flagged[$doc]}"$'\n'"$reason"
        else
          flagged[$doc]="$reason"
        fi
      done <<< "$docs"
      continue
    fi

    # c) New helper script → flag owning SKILL.md
    if [[ "$af" =~ /scripts/[^/]+\.(sh|py)$ ]]; then
      local skill_doc="${af%%/scripts/*}/SKILL.md"
      if [ -f "$skill_doc" ] && printf '%s\n' "$docs" | grep -qxF "$skill_doc"; then
        printf '%s\n' "$touched_docs" | grep -qxF "$skill_doc" && continue
        af_base="$(basename "$af")"
        local reason="new helper '${af_base}'"
        if [ -n "${flagged[$skill_doc]+set}" ]; then
          flagged[$skill_doc]="${flagged[$skill_doc]}"$'\n'"$reason"
        else
          flagged[$skill_doc]="$reason"
        fi
      fi
      continue
    fi
  done <<< "$added"

  # ------------------------------------------------------------------
  # 7. Output.
  # ------------------------------------------------------------------
  if [ "${#flagged[@]}" -eq 0 ]; then
    printf '✅ no docs look stale for %s...HEAD\n' "$base_ref"
    return 0
  fi

  printf '⚠ docs may be stale (review/update in this change):\n'
  # Sort the flagged docs for stable output.
  local sorted_docs
  sorted_docs="$(printf '%s\n' "${!flagged[@]}" | sort)"
  while IFS= read -r doc; do
    [ -z "$doc" ] && continue
    # Collapse multiple reasons into a comma-separated list on one line.
    local reasons_inline
    reasons_inline="$(printf '%s\n' "${flagged[$doc]}" | sort -u | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
    printf ' • %s — %s\n' "$doc" "$reasons_inline"
  done <<< "$sorted_docs"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  doc_impact "$@"
fi
