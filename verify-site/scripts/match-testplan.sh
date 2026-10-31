#!/usr/bin/env bash
#
# match-testplan.sh — heuristic matcher from check results back to test-plan items.
# Args: $1 PR body, $2 ndjson results, $3 output path for updated body
# Prints (stdout): count of ticked items
set -euo pipefail
BODY="$1"; RESULTS="$2"; OUT="$3"
# Fail closed on unreadable inputs (a failed read inside fam_pass's command
# substitution would otherwise look like "no results" and still tick the build item).
[ -r "$BODY" ] && [ -r "$RESULTS" ] || { echo "match-testplan: cannot read body or results" >&2; exit 1; }

# fam_pass <family>: pass = at least one pass and nothing else but skips;
# any other status (fail, error, typo) fails closed; no record or only skips
# is "none", which never ticks.
fam_pass() {
  local fam="$1" passed=0 failed=0 line c s
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    # An unparseable record cannot be trusted either way: fail closed.
    c=$(echo "$line" | jq -r '.check // empty') || { echo "fail"; return; }
    s=$(echo "$line" | jq -r '.status // empty') || { echo "fail"; return; }
    [ "$c" != "$fam" ] && continue
    case "$s" in
      pass) passed=$((passed+1)) ;;
      skip) ;;
      *) failed=$((failed+1)) ;;
    esac
  done < "$RESULTS"
  if [ $failed -gt 0 ]; then echo "fail"; return; fi
  if [ $passed -eq 0 ]; then echo "none"; return; fi
  echo "pass"
}

routes_status=$(fam_pass routes)
lh_status=$(fam_pass lighthouse)
a11y_status=$(fam_pass a11y)
resp_status=$(fam_pass responsive)
build_status="pass"  # we're here, so build succeeded

# Portable awk (BSD + gawk). No array capture.
awk -v routes="$routes_status" -v lh="$lh_status" -v a11y="$a11y_status" \
    -v resp="$resp_status" -v build="$build_status" '
BEGIN { ticked=0 }
{
  line=$0
  if (line ~ /^[[:space:]]*- \[ \]/) {
    # Lowercase, non-alphanumerics -> spaces, padded: a keyword with spaces
    # around it is a whole-word match (BSD awk lacks a word-boundary escape).
    lower=" " tolower(line) " "
    gsub(/[^a-z0-9]+/, " ", lower)
    fam=""
    if (lower ~ /(npm run build| build green | compiles )/) fam="build"
    else if (lower ~ /(lighthouse|performance| perf |best practices| seo )/) fam="lighthouse"
    else if (lower ~ /(axe|accessibility|aria|focus ring|keyboard|skip link| a11y )/) fam="a11y"
    else if (lower ~ /(mobile|375|768|1280|responsive|stacks|horizontal overflow)/) fam="responsive"
    else if (lower ~ /(renders|loads| route | 200 |no 500)/) fam="routes"
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
' "$BODY" > "$OUT"

# Only [ ] -> [x] ever changes, so the tick count is the growth in [x] lines.
before=$(grep -cE '^[[:space:]]*- \[[xX]\]' "$BODY" || true)
after=$(grep -cE '^[[:space:]]*- \[[xX]\]' "$OUT" || true)
echo $((after - before))
