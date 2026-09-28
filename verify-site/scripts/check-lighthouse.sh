#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /tmp/verify-site.env

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LH="$HERE/node_modules/.bin/lighthouse"

THRESHOLD_PERF="${THRESHOLD_PERF:-80}"
THRESHOLD_A11Y="${THRESHOLD_A11Y:-90}"
THRESHOLD_BP="${THRESHOLD_BP:-90}"
THRESHOLD_SEO="${THRESHOLD_SEO:-90}"

if [ ! -x "$LH" ]; then
  echo '{"check":"lighthouse","status":"skip","detail":"lighthouse not installed"}'
  exit 0
fi

FAIL=0
while IFS= read -r route; do
  [ -z "$route" ] && continue
  [[ "$route" != /* ]] && route="/$route"

  out=$(mktemp /tmp/lh-XXXXXX.json)
  err=$(mktemp /tmp/lh-err-XXXXXX.log)
  if ! "$LH" "$URL$route" \
        --quiet --chrome-flags="--headless=new --no-sandbox" \
        --output=json --output-path="$out" \
        --only-categories=performance,accessibility,best-practices,seo \
        2>"$err"; then
    msg=$(tail -1 "$err" | tr -d '\n' | cut -c1-120)
    printf '{"check":"lighthouse","route":"%s","status":"fail","detail":"lighthouse failed: %s"}\n' "$route" "${msg:-unknown}"
    FAIL=$((FAIL+1))
    rm -f "$out" "$err"
    continue
  fi
  rm -f "$err"

  perf=$(jq -r '(.categories.performance.score // 0) * 100 | round' "$out")
  a11y=$(jq -r '(.categories.accessibility.score // 0) * 100 | round' "$out")
  bp=$(jq -r '(.["categories"]["best-practices"].score // 0) * 100 | round' "$out")
  seo=$(jq -r '(.categories.seo.score // 0) * 100 | round' "$out")
  rm -f "$out"

  status="pass"
  reasons=()
  (( perf < THRESHOLD_PERF )) && { status="fail"; reasons+=("perf $perf<$THRESHOLD_PERF"); }
  (( a11y < THRESHOLD_A11Y )) && { status="fail"; reasons+=("a11y $a11y<$THRESHOLD_A11Y"); }
  (( bp   < THRESHOLD_BP   )) && { status="fail"; reasons+=("bp $bp<$THRESHOLD_BP");     }
  (( seo  < THRESHOLD_SEO  )) && { status="fail"; reasons+=("seo $seo<$THRESHOLD_SEO");  }

  detail="perf=$perf a11y=$a11y bp=$bp seo=$seo"
  if [ "$status" = "fail" ]; then detail+=" (below threshold: ${reasons[*]})"; FAIL=$((FAIL+1)); fi

  printf '{"check":"lighthouse","route":"%s","status":"%s","detail":"%s","scores":{"performance":%d,"accessibility":%d,"best-practices":%d,"seo":%d}}\n' \
    "$route" "$status" "$detail" "$perf" "$a11y" "$bp" "$seo"
done

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
