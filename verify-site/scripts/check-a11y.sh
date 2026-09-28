#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /tmp/verify-site.env

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mapfile -t ROUTES
if [ "${#ROUTES[@]}" -eq 0 ]; then
  echo '{"check":"a11y","status":"skip","detail":"no routes on stdin"}'
  exit 0
fi
ROUTES_JSON=$(printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -s .)

SCRIPT="/tmp/verify-a11y-$$.mjs"
cat > "$SCRIPT" <<NODE
import { chromium } from '$HERE/node_modules/playwright/index.mjs';
import AxeBuilder from '$HERE/node_modules/@axe-core/playwright/dist/index.js';

const URL = process.env.URL;
const routes = JSON.parse(process.env.ROUTES_JSON);
const browser = await chromium.launch();
const context = await browser.newContext();
const page = await context.newPage();
let fails = 0;
for (const r of routes) {
  const route = r.startsWith('/') ? r : '/' + r;
  try {
    await page.goto(URL + route, { waitUntil: 'networkidle', timeout: 20_000 });
  } catch (err) {
    console.log(JSON.stringify({ check: 'a11y', route, status: 'fail', detail: 'load: ' + err.message }));
    fails++;
    continue;
  }
  const results = await new AxeBuilder.default({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  const violations = results.violations.length;
  if (violations === 0) {
    console.log(JSON.stringify({ check: 'a11y', route, status: 'pass', detail: 'no violations' }));
  } else {
    const summary = results.violations.slice(0, 3).map(v => v.id + '(' + v.nodes.length + ')').join(',');
    console.log(JSON.stringify({ check: 'a11y', route, status: 'fail', detail: violations + ' violations: ' + summary }));
    fails++;
  }
}
await browser.close();
process.exit(fails > 0 ? 1 : 0);
NODE

URL="$URL" ROUTES_JSON="$ROUTES_JSON" node "$SCRIPT"
CODE=$?
rm -f "$SCRIPT"
exit $CODE
