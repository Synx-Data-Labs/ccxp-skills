#!/usr/bin/env bash
#
# check-routes.sh — HTTP 200 check on every discovered route.
#
# Stdin:  one route path per line (e.g. "/", "/blog/")
# Env:    URL (base URL, from /tmp/verify-site.env)
# Stdout: one JSON object per route, one per line (ndjson):
#   {"check":"routes","route":"/","status":"pass","detail":"200"}
set -euo pipefail

# shellcheck disable=SC1091
source /tmp/verify-site.env

FAIL=0
while IFS= read -r route; do
  [ -z "$route" ] && continue
  # Normalize: ensure leading slash, strip trailing except root
  [[ "$route" != /* ]] && route="/$route"

  code=$(curl -s -o /dev/null -w '%{http_code}' "$URL$route" || echo "000")
  if [ "$code" = "200" ]; then
    printf '{"check":"routes","route":"%s","status":"pass","detail":"200"}\n' "$route"
  else
    printf '{"check":"routes","route":"%s","status":"fail","detail":"HTTP %s"}\n' "$route" "$code"
    FAIL=$((FAIL+1))
  fi
done

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
