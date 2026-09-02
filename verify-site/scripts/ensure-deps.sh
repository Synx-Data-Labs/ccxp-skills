#!/usr/bin/env bash
#
# ensure-deps.sh — install the skill's node deps into the skill dir.
#
# Idempotent: skips if node_modules/ is present. Uses NPM_REGISTRY env var if set
# (useful behind a firewall or in regions where registry.npmjs.org is slow).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "$HERE/node_modules/playwright" ] && [ -d "$HERE/node_modules/lighthouse" ]; then
  exit 0
fi

echo "Installing verify-site deps into $HERE (first-run, ~1–2 min)..."
REGISTRY_ARG=()
if [ -n "${NPM_REGISTRY:-}" ]; then
  REGISTRY_ARG=(--registry "$NPM_REGISTRY")
fi

(cd "$HERE" && npm install --no-audit --no-fund "${REGISTRY_ARG[@]}")

# Install Chromium for Playwright (~200MB; Playwright's installer handles idempotency)
(cd "$HERE" && node_modules/.bin/playwright install chromium)

echo "verify-site deps ready."
