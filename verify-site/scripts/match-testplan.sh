#!/usr/bin/env bash
#
# match-testplan.sh — heuristic matcher from check results back to test-plan items.
# Args: $1 PR body, $2 ndjson results, $3 output path for updated body
# Prints (stdout): count of ticked items
set -euo pipefail
BODY="$1"; RESULTS="$2"; OUT="$3"

fam_pass() {
  local fam="$1" total=0 failed=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    c=$(echo "$line" | jq -r '.check // empty')
    s=$(echo "$line" | jq -r '.status // empty')
    [ "$c" != "$fam" ] && continue
    total=$((total+1))
    [ "$s" = "fail" ] && failed=$((failed+1))
  done < "$RESULTS"
  if [ $total -eq 0 ]; then echo "none"; return; fi
  [ $failed -eq 0 ] && echo "pass" || echo "fail"
}

routes_status=$(fam_pass routes)
lh_status=$(fam_pass lighthouse)
a11y_status=$(fam_pass a11y)
resp_status=$(fam_pass responsive)
build_status="pass"  # we're here, so build succeeded

# Portable awk (BSD + gawk). No array capture.
awk -v routes="$routes_status" -v lh="$lh_status" -v a11y="$a11y_status" \
    -v resp="$resp_status" -v build="$build_status" '
BEGIN { IGNORECASE=1; ticked=0 }
{
  line=$0
  if (line ~ /^[[:space:]]*- \[ \]/) {
    lower=tolower(line)
    fam=""
    if (lower ~ /(npm run build|build green|compiles)/) fam="build"
    else if (lower ~ /(lighthouse|performance|\bperf\b|best practices|\bseo\b)/) fam="lighthouse"
    else if (lower ~ /(axe|accessibility|aria|focus ring|keyboard|skip link|\ba11y\b)/) fam="a11y"
    else if (lower ~ /(mobile|375|768|1280|responsive|stacks|horizontal overflow)/) fam="responsive"
    else if (lower ~ /(renders|loads|\broute\b|\b200\b|no 500)/) fam="routes"
    status=""
    if (fam == "build") status=build
    else if (fam == "routes") status=routes
    else if (fam == "lighthouse") status=lh
    else if (fam == "a11y") status=a11y
    else if (fam == "responsive") status=resp
    if (status == "pass") {
      sub(/\[ \]/, "[x]", line)
      ticked++
    }
  }
  print line
}
END { print ticked > "/tmp/verify-tick-count.txt" }
' "$BODY" > "$OUT"

cat /tmp/verify-tick-count.txt
