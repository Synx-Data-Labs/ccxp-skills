#!/usr/bin/env bash
# secrets-check.sh — pre-PR secret-handling check on a branch's diff.
#
# Usage: secrets-check.sh [base-ref]      (default origin/main)
#
# Runs the repo's scripts/lint-secret-handling.sh --diff <base> when present.
# Otherwise runs a rough built-in grep set on the ADDED lines of the merge-base
# diff, including staged, unstaged and untracked files
# and prints only `fallback: <rule>: diff line <n>` -- never the matched line or
# value, so nothing secret reaches a transcript. Reports only; never edits.
#
# Exit: 0 clean, 1 findings, 2 usage / not a git repo / base unresolved.
# Sourceable: defines functions only; runs only when executed directly.
set -euo pipefail

function secrets-check-fallback() {
  local base=${1:-origin/main} rule re n=0 hits
  local -a rules=(
    "token-literal|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|hooks\\.slack\\.com/services/"
    "cmdline-secret|--(token|password)[ =]+[^ -]|curl .*-u +[^ :]+:[^ ]+|docker login .*-p +[^ ]+"
    "token-literal|(TOKEN|SECRET|PASSWORD|API_?KEY)[A-Z_]*=[A-Za-z0-9+_-]{16,}"
  )
  local diff
  local mb f
  mb="$(git merge-base "$base" HEAD)"
  # committed + staged + unstaged tracked changes against the merge-base, plus untracked files
  diff="$(git diff "$mb" -U0 | grep -E '^\+[^+]|^\+$' || true)"
  while IFS= read -r f; do
    [[ -f "$f" ]] && diff+=$'\n'"$(sed 's/^/+/' "$f")"
  done < <(git ls-files -o --exclude-standard)
  local entry
  for entry in "${rules[@]}"; do
    rule=${entry%%|*}
    re=${entry#*|}
    hits="$(printf '%s\n' "$diff" | grep -nE -- "$re" | cut -d: -f1 || true)"
    for n in $hits; do
      echo "fallback: ${rule}: added-line index ${n}"
      found=1
    done
  done
}

function secrets-check() {
  local base=${1:-origin/main} root found=0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "secrets-check: not a git repo" >&2; return 2; }
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || { echo "secrets-check: base ref '${base}' does not resolve" >&2; return 2; }
  cd "$root"
  if [[ -f scripts/lint-secret-handling.sh ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "secrets-check: warning: uncommitted changes are not covered by the repo lint's --diff (it reads ${base}...HEAD); commit first" >&2
    fi
    bash scripts/lint-secret-handling.sh --diff "$base"
    return $?
  fi
  echo "secrets-check: no scripts/lint-secret-handling.sh here; using the rough built-in fallback" >&2
  secrets-check-fallback "$base"
  if (( found )); then
    echo "secrets-check: findings (values withheld); fix by moving the secret to stdin, --token-file or op run" >&2
    return 1
  fi
  echo "secrets-check: clean (fallback grep set)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  secrets-check "$@"
fi
