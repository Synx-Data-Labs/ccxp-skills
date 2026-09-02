#!/usr/bin/env bash
#
# report.sh — render a human-readable summary of a verify-site run.
#
# Args: $1 ndjson results
#       $2 original PR body markdown
#       $3 updated PR body markdown (after match-testplan)
#       $4 ticked count
set -euo pipefail

RESULTS="$1"
ORIG="$2"
UPDATED="$3"
TICKED="$4"

per_family() {
  local fam="$1"
  local pass=0 fail=0 skip=0
  local fail_lines=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    c=$(echo "$line" | jq -r '.check // empty')
    s=$(echo "$line" | jq -r '.status // empty')
    [ "$c" != "$fam" ] && continue
    case "$s" in
      pass) pass=$((pass+1)) ;;
      fail) fail=$((fail+1)); fail_lines+=("$line") ;;
      skip) skip=$((skip+1)) ;;
    esac
  done < "$RESULTS"
  printf "### %s — %d pass, %d fail, %d skip\n\n" "$fam" "$pass" "$fail" "$skip"
  if [ "${#fail_lines[@]}" -gt 0 ]; then
    for l in "${fail_lines[@]}"; do
      r=$(echo "$l" | jq -r '.route // "-"')
      d=$(echo "$l" | jq -r '.detail // ""')
      printf "  - \`%s\`: %s\n" "$r" "$d"
    done
    printf "\n"
  fi
}

printf "# verify-site report\n\n"
printf "**Items auto-ticked**: %s\n\n" "$TICKED"
printf "## Checks\n\n"
per_family routes
per_family lighthouse
per_family responsive
per_family a11y

# Human-only items — those left unchecked in the updated body
printf "## Test-plan items still needing human review\n\n"
grep -E '^\s*- \[ \]' "$UPDATED" | sed 's/^/  /' || echo "  _(none)_"
printf "\n"
