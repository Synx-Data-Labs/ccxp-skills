#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /tmp/verify-site.env

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIDTHS="${WIDTHS:-375,768,1280}"

mapfile -t ROUTES
if [ "${#ROUTES[@]}" -eq 0 ]; then
  echo '{"check":"responsive","status":"skip","detail":"no routes on stdin"}'
  exit 0
fi
ROUTES_JSON=$(printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -s .)

SCRIPT="/tmp/verify-responsive-$$.mjs"
cat > "$SCRIPT" <<NODE
import { chromium } from '$HERE/node_modules/playwright/index.mjs';
const URL = process.env.URL;
const routes = JSON.parse(process.env.ROUTES_JSON);
const widths = process.env.WIDTHS.split(',').map(Number);

const browser = await chromium.launch();
const context = await browser.newContext();
const page = await context.newPage();
let fails = 0;
for (const r of routes) {
  const route = r.startsWith('/') ? r : '/' + r;
  for (const w of widths) {
    await page.setViewportSize({ width: w, height: 800 });
    try {
      await page.goto(URL + route, { waitUntil: 'networkidle', timeout: 20_000 });
    } catch (err) {
      console.log(JSON.stringify({ check: 'responsive', route, status: 'fail', detail: 'load@' + w + ': ' + err.message }));
      fails++;
      continue;
    }
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    if (overflow > 1) {
      console.log(JSON.stringify({ check: 'responsive', route, status: 'fail', detail: 'horizontal overflow ' + overflow + 'px @ ' + w + 'w' }));
      fails++;
    } else {
      console.log(JSON.stringify({ check: 'responsive', route, status: 'pass', detail: 'no overflow @ ' + w + 'w' }));
    }
  }
}
await browser.close();
process.exit(fails > 0 ? 1 : 0);
NODE

URL="$URL" ROUTES_JSON="$ROUTES_JSON" WIDTHS="$WIDTHS" node "$SCRIPT"
CODE=$?
rm -f "$SCRIPT"
exit $CODE
