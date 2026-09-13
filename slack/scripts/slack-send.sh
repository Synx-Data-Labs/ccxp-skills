#!/usr/bin/env bash
# slack-send.sh - Send a Slack notification from the command line
#
# Usage:
#   ~/.claude/skills/slack/scripts/slack-send.sh "hello world"
#   ~/.claude/skills/slack/scripts/slack-send.sh --product NAME --version VER --status STATUS
#
# Environment / .env resolution (in order, first wins):
#   1. SLACK_WEBHOOK_URL already exported in the environment
#   2. ~/.claude/.env  (machine-global, recommended)
#   3. $(pwd)/.env     (consumer repo's env, for back-compat)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/slack-notify.sh"

# Load .env (skip in BATS to keep tests hermetic)
if [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
  for ENV_FILE in "${HOME}/.claude/.env" "$(pwd)/.env"; do
    if [[ -f "$ENV_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE"
      [[ -n "${SLACK_WEBHOOK_URL:-}" ]] && break
    fi
  done
fi

slack-send-usage() {
  cat <<EOF
Usage:
  $0 <message>                                     Send a plain text message
  $0 --product NAME --version VER --status STATUS  Send a build notification

Options:
  --product   Product name (e.g., "AcmeWidget4 Lightning")
  --version   Version string (e.g., "4.4.0")
  --status    Build status: success or failure
  --details   Optional details text
  --duration  Optional build duration

Examples:
  $0 "PR #4 is ready to merge"
  $0 --product "AcmeWidget4" --version "4.4.0" --status success --details "8 RPMs built"
EOF
}

if [[ $# -eq 0 ]]; then
  slack-send-usage
  exit 1
fi

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "Error: SLACK_WEBHOOK_URL is not set." >&2
  echo "Set it in ~/.claude/.env, the consumer repo's .env, or export it." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# Build notification mode: first arg starts with --
if [[ "$1" == --* ]]; then
  PRODUCT="" VERSION="" STATUS="" DETAILS="" DURATION=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --product)  PRODUCT="$2";  shift 2 ;;
      --version)  VERSION="$2";  shift 2 ;;
      --status)   STATUS="$2";   shift 2 ;;
      --details)  DETAILS="$2";  shift 2 ;;
      --duration) DURATION="$2"; shift 2 ;;
      --help|-h)  slack-send-usage; exit 0 ;;
      *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
  if [[ -z "$PRODUCT" || -z "$VERSION" || -z "$STATUS" ]]; then
    echo "Error: --product, --version, and --status are required" >&2
    slack-send-usage
    exit 1
  fi
  slack-notify-build "$PRODUCT" "$VERSION" "$STATUS" "$DETAILS" "$DURATION"
else
  # Plain text mode: join all args as the message
  MESSAGE="$*"
  # Build the JSON with jq so newlines, quotes, tabs and backslashes are
  # encoded correctly. Hand-rolled escaping left raw newlines in the payload,
  # which is invalid JSON and made Slack collapse multi-line messages.
  PAYLOAD=$(jq -n --arg text "$MESSAGE" '{text: $text}')
  slack-notify "$PAYLOAD"
fi
