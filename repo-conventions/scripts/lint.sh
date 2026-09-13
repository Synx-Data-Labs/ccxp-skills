#!/usr/bin/env bash
#
# lint.sh — Check current repo against ccxp-skills repo-conventions rules.
#
# Usage:
#   bash ~/.claude/skills/repo-conventions/scripts/lint.sh [path-to-repo]
#
# Exits non-zero if any rule is violated.

set -euo pipefail

REPO_DIR="${1:-$(pwd)}"
ERRORS=0

check() {
  local label="$1"
  local result="$2"
  local detail="${3:-}"
  if [[ "$result" == "ok" ]]; then
    echo "  ✅ ${label}"
  else
    echo "  ❌ ${label}${detail:+ — ${detail}}"
    ERRORS=$((ERRORS + 1))
  fi
}

cap-check() {
  # cap-check <file> <max_lines> <max_kb> <label>
  local file="$1" max_lines="$2" max_kb="$3" label="$4"
  if [[ ! -f "$file" ]]; then
    check "$label exists" "fail" "missing: $file"
    return
  fi
  local lines size_kb
  lines=$(wc -l < "$file" | tr -d ' ')
  size_kb=$(( ($(wc -c < "$file") + 1023) / 1024 ))
  if (( lines > max_lines )); then
    check "$label ≤ ${max_lines} lines" "fail" "${lines} lines"
  else
    check "$label ≤ ${max_lines} lines" "ok"
  fi
  if (( size_kb > max_kb )); then
    check "$label ≤ ${max_kb} KB" "fail" "${size_kb} KB"
  else
    check "$label ≤ ${max_kb} KB" "ok"
  fi
}

echo "=========================================="
echo "repo-conventions lint: ${REPO_DIR}"
echo "=========================================="
echo ""

# 1. CLAUDE.md
echo "CLAUDE.md..."
cap-check "${REPO_DIR}/CLAUDE.md" 50 3 "CLAUDE.md size"

if [[ -f "${REPO_DIR}/CLAUDE.md" ]]; then
  # Heuristic: a journal index is a month header (## YYYY or ## Month YYYY)
  # near a dev/JOURNAL/ link. Flag if both appear.
  if grep -qE '^## .*20[0-9]{2}' "${REPO_DIR}/CLAUDE.md" \
     && grep -q 'dev/JOURNAL/' "${REPO_DIR}/CLAUDE.md"; then
    check "no journal index in CLAUDE.md" "fail" "found month headers + dev/JOURNAL/ links"
  else
    check "no journal index in CLAUDE.md" "ok"
  fi
fi

# 2. dev/guidelines.md
echo ""
echo "dev/guidelines.md..."
cap-check "${REPO_DIR}/dev/guidelines.md" 200 8 "guidelines.md size"

if [[ -f "${REPO_DIR}/dev/guidelines.md" ]]; then
  if grep -qi 'TODO Lifecycle' "${REPO_DIR}/dev/guidelines.md"; then
    check "guidelines.md mentions TODO Lifecycle" "ok"
  else
    check "guidelines.md mentions TODO Lifecycle" "fail"
  fi
fi

# 3. dev/ folder layout
echo ""
echo "dev/ layout..."
for dir in TODO JOURNAL; do
  if [[ -d "${REPO_DIR}/dev/${dir}" ]]; then
    check "dev/${dir}/ exists" "ok"
  else
    check "dev/${dir}/ exists" "fail"
  fi
done

# 4. task-file frontmatter (delegated to lint_tasks.py)
echo ""
echo "dev/ task frontmatter..."
if command -v python3 >/dev/null 2>&1; then
  if ! python3 "$(dirname "${BASH_SOURCE[0]}")/lint_tasks.py" --all "${REPO_DIR}"; then
    ERRORS=$((ERRORS + 1))
  fi
else
  check "python3 available for task lint" "fail" "python3 not found"
fi

# 5. task/issue/PR references clickable (delegated to lint_refs.py, read-only)
echo ""
echo "dev/ task references..."
if command -v python3 >/dev/null 2>&1; then
  if ! python3 "$(dirname "${BASH_SOURCE[0]}")/lint_refs.py" --all "${REPO_DIR}"; then
    ERRORS=$((ERRORS + 1))
  fi
else
  check "python3 available for ref lint" "fail" "python3 not found"
fi

# Summary
echo ""
echo "=========================================="
if (( ERRORS > 0 )); then
  echo "❌ ${ERRORS} violation(s)"
  echo "=========================================="
  exit 1
else
  echo "✅ all checks passed"
  echo "=========================================="
  exit 0
fi
