#!/usr/bin/env bash
#
# verify.sh — orchestrator for the verify-site skill.
#
# Usage: verify.sh <pr-number>
#
# Discovers routes, runs the check scripts, matches results to the PR's test
# plan, writes an updated PR body, and prints a summary.
#
# Writes:
#   /tmp/verify-site-routes.txt    — discovered routes, one per line
#   /tmp/verify-site-results.ndjson — merged check results
#   /tmp/verify-site-report.md      — human-readable summary
set -euo pipefail

PR="${1:?Usage: $0 <pr-number>}"
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "Error: PR number must be numeric, got: $PR" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="$(bash "$HERE/../../_gh/gh.sh" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  echo "Error: could not determine repo from cwd." >&2
  exit 2
fi
echo "Repo: $REPO"
echo "PR:   #$PR"

BODY_FILE=$(mktemp /tmp/verify-body.XXXXXX)
bash "$HERE/../../_gh/gh.sh" pr view "$PR" --repo "$REPO" --json body --jq '.body' > "$BODY_FILE"

cleanup() {
  bash "$HERE/preview-down.sh" || true
}
trap cleanup EXIT

# 0. Ensure skill-local deps (playwright, lighthouse, axe) are installed once
bash "$HERE/ensure-deps.sh"

# 1. Build + start preview (does build step internally)
bash "$HERE/preview-up.sh"
# shellcheck disable=SC1091
source /tmp/verify-site.env

# 2. Discover routes
# Sitemap loc URLs use the production origin (site: config in the framework),
# not our preview origin. Rewrite every loc → path, then de-dup.
ROUTES_FILE=/tmp/verify-site-routes.txt
: > "$ROUTES_FILE"

extract_locs() {
  # $1 = local file; strip whitespace between tags, emit each <loc>..</loc> on its own line
  tr -d '\n' < "$1" | sed 's#<loc>#\n<loc>#g' | grep -oE '<loc>[^<]+' | sed 's#<loc>##'
}

if curl -sf "$URL/sitemap-index.xml" -o /tmp/verify-sitemap-index.xml 2>/dev/null; then
  extract_locs /tmp/verify-sitemap-index.xml | while IFS= read -r sm; do
    # sm is like https://www.example-website.com/sitemap-0.xml — replace the origin with preview URL
    sm_path=$(echo "$sm" | sed -E 's#^https?://[^/]+##')
    curl -sf "$URL$sm_path" -o /tmp/verify-sitemap-inner.xml 2>/dev/null || continue
    extract_locs /tmp/verify-sitemap-inner.xml >> "$ROUTES_FILE"
  done
elif curl -sf "$URL/sitemap.xml" -o /tmp/verify-sitemap-inner.xml 2>/dev/null; then
  extract_locs /tmp/verify-sitemap-inner.xml >> "$ROUTES_FILE"
fi

# Strip origins → paths
if [ -s "$ROUTES_FILE" ]; then
  sed -E -e 's#^https?://[^/]+##' "$ROUTES_FILE" | sort -u > "$ROUTES_FILE.tmp"
  mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"
fi
grep -qE '^/$' "$ROUTES_FILE" || echo "/" >> "$ROUTES_FILE"
sort -u "$ROUTES_FILE" -o "$ROUTES_FILE"

ROUTE_COUNT=$(wc -l < "$ROUTES_FILE" | tr -d ' ')
echo "Discovered $ROUTE_COUNT routes from sitemap."

RESULTS=/tmp/verify-site-results.ndjson
: > "$RESULTS"

# 3. Routes check (all)
echo ""
echo "== routes =="
cat "$ROUTES_FILE" | bash "$HERE/check-routes.sh" | tee -a "$RESULTS" || true

# 4. Lighthouse (sample: up to 3 routes: /, and the two most distinct sections)
echo ""
echo "== lighthouse (sample) =="
SAMPLE=$(mktemp)
{
  grep -E '^/$' "$ROUTES_FILE" || true
  grep -E '^/blog/$|^/blog$' "$ROUTES_FILE" | head -1 || true
  grep -E '^/product/[^/]+/$|^/product/[^/]+$' "$ROUTES_FILE" | head -1 || true
} | sort -u > "$SAMPLE"
if [ -s "$SAMPLE" ]; then
  cat "$SAMPLE" | bash "$HERE/check-lighthouse.sh" | tee -a "$RESULTS" || true
else
  echo '{"check":"lighthouse","status":"skip","detail":"no sample routes"}' | tee -a "$RESULTS"
fi
rm -f "$SAMPLE"

# 5. Responsive (all routes)
echo ""
echo "== responsive =="
cat "$ROUTES_FILE" | bash "$HERE/check-responsive.sh" | tee -a "$RESULTS" || true

# 6. A11y (all routes)
echo ""
echo "== a11y =="
cat "$ROUTES_FILE" | bash "$HERE/check-a11y.sh" | tee -a "$RESULTS" || true

# 7. Match + auto-tick
echo ""
echo "== matching test plan =="
UPDATED_BODY=$(mktemp /tmp/verify-body-updated.XXXXXX)
TICKED=$(bash "$HERE/match-testplan.sh" "$BODY_FILE" "$RESULTS" "$UPDATED_BODY")
echo "Ticked $TICKED item(s)."

if [ "$TICKED" -gt 0 ]; then
  bash "$HERE/../../_gh/gh.sh" pr edit "$PR" --repo "$REPO" --body-file "$UPDATED_BODY" >/dev/null
  echo "PR body updated."
fi

# 8. Summary report
bash "$HERE/report.sh" "$RESULTS" "$BODY_FILE" "$UPDATED_BODY" "$TICKED" > /tmp/verify-site-report.md
cat /tmp/verify-site-report.md
