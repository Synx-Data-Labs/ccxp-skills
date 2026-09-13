#!/usr/bin/env bash
#
# preview-up.sh — build the site, start a local preview server, wait until it responds.
#
# Writes /tmp/verify-site.env with PID, URL, and LOGFILE so downstream scripts and
# preview-down.sh can find the running server.
#
# Auto-detects Astro / Next / Vite projects, or reads .verify-site.json if present.
set -euo pipefail

ENV_FILE="/tmp/verify-site.env"
LOG_FILE="/tmp/verify-site-preview.log"

if [ -f "$ENV_FILE" ]; then
  # prior run didn't tear down; try to stop it
  source "$ENV_FILE" 2>/dev/null || true
  if [ -n "${PREVIEW_PID:-}" ] && kill -0 "$PREVIEW_PID" 2>/dev/null; then
    echo "Previous preview (pid $PREVIEW_PID) still running, stopping..."
    kill "$PREVIEW_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$ENV_FILE"
fi

BUILD=""
START=""
URL=""

if [ -f .verify-site.json ]; then
  BUILD=$(jq -r '.preview.build // empty' .verify-site.json)
  START=$(jq -r '.preview.start // empty' .verify-site.json)
  URL=$(jq -r '.preview.url // empty' .verify-site.json)
fi

if [ -z "$BUILD" ] || [ -z "$START" ] || [ -z "$URL" ]; then
  if ls astro.config.* >/dev/null 2>&1; then
    BUILD="${BUILD:-npm run build}"
    START="${START:-npm run preview -- --host 127.0.0.1 --port 4321}"
    URL="${URL:-http://127.0.0.1:4321}"
  elif ls next.config.* >/dev/null 2>&1; then
    BUILD="${BUILD:-npm run build}"
    START="${START:-npm run start -- -p 3000}"
    URL="${URL:-http://127.0.0.1:3000}"
  elif ls vite.config.* >/dev/null 2>&1; then
    BUILD="${BUILD:-npm run build}"
    START="${START:-npm run preview -- --host 127.0.0.1 --port 4173}"
    URL="${URL:-http://127.0.0.1:4173}"
  else
    echo "error: could not auto-detect framework. Create .verify-site.json with preview.build/start/url." >&2
    exit 2
  fi
fi

echo "Building..."
bash -c "$BUILD" 2>&1 | tail -5

echo "Starting preview server..."
: > "$LOG_FILE"
bash -c "$START" >>"$LOG_FILE" 2>&1 &
PREVIEW_PID=$!

cat > "$ENV_FILE" <<EOF
PREVIEW_PID=$PREVIEW_PID
URL=$URL
LOG_FILE=$LOG_FILE
EOF

# wait up to 60s for the server to answer
echo "Waiting for $URL ..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "$URL/"; then
    echo "Preview up (pid $PREVIEW_PID) at $URL"
    exit 0
  fi
  if ! kill -0 "$PREVIEW_PID" 2>/dev/null; then
    echo "error: preview process died. Last log lines:" >&2
    tail -20 "$LOG_FILE" >&2
    rm -f "$ENV_FILE"
    exit 3
  fi
  sleep 1
done

echo "error: preview did not answer within 60s. Last log lines:" >&2
tail -20 "$LOG_FILE" >&2
kill "$PREVIEW_PID" 2>/dev/null || true
rm -f "$ENV_FILE"
exit 4
