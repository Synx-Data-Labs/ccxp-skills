#!/usr/bin/env bash
# Stop the preview server started by preview-up.sh
set -euo pipefail

ENV_FILE="/tmp/verify-site.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "No preview env file at $ENV_FILE; nothing to stop."
  exit 0
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -n "${PREVIEW_PID:-}" ] && kill -0 "$PREVIEW_PID" 2>/dev/null; then
  kill "$PREVIEW_PID" 2>/dev/null || true
  for i in $(seq 1 10); do
    if ! kill -0 "$PREVIEW_PID" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if kill -0 "$PREVIEW_PID" 2>/dev/null; then
    kill -9 "$PREVIEW_PID" 2>/dev/null || true
  fi
  echo "Preview (pid $PREVIEW_PID) stopped."
fi

rm -f "$ENV_FILE"
