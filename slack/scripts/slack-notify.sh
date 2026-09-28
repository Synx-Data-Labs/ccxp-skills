#!/usr/bin/env bash
# slack-notify.sh - Slack notification functions
#
# Usage:
#   source slack-notify.sh
#
# Environment:
#   SLACK_WEBHOOK_URL  - Slack Incoming Webhook URL (required)
#
# Functions:
#   slack-notify        - Send a raw JSON payload to Slack
#   slack-notify-build  - Send a build completion notification (product/version/status)

# slack-notify - Send a raw Slack message payload
#
# Args:
#   payload: JSON string for Slack webhook
#
# Returns: 0 on success, 1 on failure (non-fatal)
slack-notify() {
  local payload="$1"
  local webhook_url="${SLACK_WEBHOOK_URL:-}"

  if [[ -z "$webhook_url" ]]; then
    echo "Warning: SLACK_WEBHOOK_URL not set, skipping Slack notification" >&2
    return 0
  fi

  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    --max-time 10 \
    -d "$payload" \
    "$webhook_url")

  if [[ "$response" == "200" ]]; then
    echo "Slack notification sent successfully"
  else
    echo "Warning: Slack notification failed (HTTP $response)" >&2
  fi
}

# slack-notify-build - Send a build completion notification
#
# Args:
#   product:  Product name (e.g., "AcmeWidget4 Lightning", "AcmeDB Cloud")
#   version:  Version string (e.g., "4.4.0", "nightly")
#   status:   "success" or "failure"
#   details:  Optional details text (multiline OK — encoded via jq)
#   duration: Optional build duration string (e.g., "35m 12s")
#
# Example:
#   slack-notify-build "AcmeWidget4" "4.4.0" "success" "8 RPMs built" "42m 17s"
slack-notify-build() {
  local product="$1"
  local version="$2"
  local status="$3"
  local details="${4:-}"
  local duration="${5:-}"

  if [[ -z "$product" || -z "$version" || -z "$status" ]]; then
    echo "Usage: slack-notify-build <product> <version> <success|failure> [details] [duration]" >&2
    return 1
  fi

  local color icon
  case "$status" in
    success) color="#36a64f"; icon=":white_check_mark:" ;;
    failure) color="#cc0000"; icon=":x:" ;;
    *)       color="#cccccc"; icon=":information_source:" ;;
  esac

  # Build payload with jq so all fields (including details with newlines) are
  # correctly JSON-encoded. Hand-rolled escaping with sed misses raw newlines.
  local payload
  payload=$(jq -n \
    --arg color   "$color" \
    --arg icon    "$icon" \
    --arg product "$product" \
    --arg version "$version" \
    --arg status  "$status" \
    --arg details "$details" \
    --arg duration "$duration" \
    '{
      attachments: [{
        color:    $color,
        fallback: ($icon + " " + $product + " " + $version + " build " + $status),
        text:     ($icon + " *" + $product + " " + $version + "* build *" + $status + "*"),
        fields: (
          [{"title": "Product", "value": $product, "short": true},
           {"title": "Version", "value": $version, "short": true}]
          + (if $duration != "" then [{"title": "Duration", "value": $duration, "short": true}] else [] end)
          + (if $details  != "" then [{"title": "Details",  "value": $details,  "short": false}] else [] end)
        )
      }]
    }')

  slack-notify "$payload"
}

# Only run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  slack-notify "$@"
fi
