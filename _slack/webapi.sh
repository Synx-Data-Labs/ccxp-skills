#!/usr/bin/env bash
# _slack/webapi.sh — Slack Web API calls via curl + a bot token. No MCP.
#
# Replaces the mcp__claude_ai_Slack__* OAuth-connector tools
# (slack_search_public_and_private, slack_read_thread, slack_send_message)
# for ccxp automation (T20261001-319589): that connector requires an
# interactively-granted OAuth session and is unavailable in headless/cron
# (`CCXP_CRON_MODE=1`, `-p` mode) sessions — confirmed recurring, not a
# one-off (see the task file for the evidence trail). A bot token works
# identically in cron and interactive sessions because it's a plain
# Authorization header, not a per-session grant.
#
# Scope: read + reply only (dedup-check a thread, find a message by text in
# a time window, post a message or a threaded reply). Simple one-way
# notifications (standup post, hold-tick note) still use the existing
# incoming webhooks via slack/scripts/slack-send.sh — no bot token needed
# for those, and webhooks remain simpler for that case.
#
# Requires Bot Token Scopes: chat:write, channels:history, channels:read
# (add groups:history/groups:read too for any private target channel). The
# bot must be invited to (or self-join via channels:join) every channel it
# posts to or reads.
#
# Environment / .env resolution (in order, first wins) — same convention as
# slack/scripts/slack-send.sh:
#   1. SLACK_BOT_TOKEN already exported in the environment
#   2. ~/.claude/.env  (machine-global, recommended)
#   3. $(pwd)/.env     (consumer repo's env, for back-compat)

# -e deliberately omitted — sourceable (same reasoning as _gh/gh.sh): a
# caller that sources this file to use one function directly must not have
# its own shell's error-exit behavior silently changed.
set -uo pipefail

_slack_api_base="https://slack.com/api"

# Resolves SLACK_BOT_TOKEN into the caller's environment if not already set.
# No-ops (returns 1, prints nothing) if it can't be found anywhere — callers
# check the exit status so a missing token is a clean "feature unavailable",
# not a crash.
_slack_api_load_token() {
  if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
    return 0
  fi
  local env_file
  for env_file in "${HOME}/.claude/.env" "$(pwd)/.env"; do
    if [[ -f "$env_file" ]]; then
      # shellcheck disable=SC1090
      source "$env_file"
      [[ -n "${SLACK_BOT_TOKEN:-}" ]] && return 0
    fi
  done
  return 1
}

_slack_api_die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }

_slack_api_require_token() {
  _slack_api_load_token || _slack_api_die \
    "SLACK_BOT_TOKEN is not set (checked env, ~/.claude/.env, \$(pwd)/.env) — see _slack/README.md"
}

_slack_api_require_jq() {
  command -v jq >/dev/null 2>&1 || _slack_api_die "jq is required but not installed"
}

# $1 method (e.g. chat.postMessage), remaining args: curl -d/-F style
# key=value form fields. Prints the raw JSON response. Non-2xx HTTP or
# Slack's own {"ok": false, ...} are NOT treated as script failure here —
# callers inspect the JSON (`.ok`, `.error`) themselves, since a "channel
# not found" or "not in channel" error is routine, actionable data, not an
# exceptional condition worth a bash exit code.
_slack_api_call() {
  local method="$1"; shift
  local -a form_args=()
  local kv
  for kv in "$@"; do
    form_args+=(--data-urlencode "$kv")
  done
  curl -sS --max-time 15 \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    "${form_args[@]}" \
    "${_slack_api_base}/${method}"
}

# slack-api-post <channel_id> <text> [thread_ts]
# Posts a message (optionally as a thread reply). Prints the raw
# chat.postMessage JSON response — callers that need the new message's own
# ts for a *later* step in the same process read `.ts` from it; a
# different, later process (e.g. a future ccxp tick) cannot rely on that
# ts being handed to it and should rediscover the message via
# slack-api-find-by-text instead.
slack-api-post() {
  local channel_id="$1" text="$2" thread_ts="${3:-}"
  _slack_api_require_token
  if [[ -n "$thread_ts" ]]; then
    _slack_api_call chat.postMessage "channel=${channel_id}" "text=${text}" "thread_ts=${thread_ts}"
  else
    _slack_api_call chat.postMessage "channel=${channel_id}" "text=${text}"
  fi
}

# slack-api-history <channel_id> [oldest_ts] [latest_ts] [limit]
# Prints the raw conversations.history JSON response. oldest/latest are
# Slack ts strings ("1234567890.123456"); omit either to leave that bound
# open. limit defaults to 100 (Slack's own default).
slack-api-history() {
  local channel_id="$1" oldest="${2:-}" latest="${3:-}" limit="${4:-100}"
  _slack_api_require_token
  local -a args=("channel=${channel_id}" "limit=${limit}")
  [[ -n "$oldest" ]] && args+=("oldest=${oldest}")
  [[ -n "$latest" ]] && args+=("latest=${latest}")
  _slack_api_call conversations.history "${args[@]}"
}

# slack-api-thread-replies <channel_id> <message_ts>
# Prints the raw conversations.replies JSON response (parent message +
# every reply, in `.messages[]`) — the slack_read_thread replacement, used
# for labrun-rca's dedup check ("does this thread already have a `*RCA —`
# reply?") before posting a new one.
slack-api-thread-replies() {
  local channel_id="$1" message_ts="$2"
  _slack_api_require_token
  _slack_api_call conversations.replies "channel=${channel_id}" "ts=${message_ts}"
}

# slack-api-find-by-text <channel_id> <search_text> [oldest_ts] [latest_ts]
# The slack_search_public_and_private replacement, scoped to one channel in
# a time window (conversations.history has no cross-channel full-text
# search — a bot token can't call search.messages, that's user-token-only
# — so this is a history fetch + jq substring filter instead). Prints the
# matching messages as a JSON array (newest first, matching Slack's own
# history order), or `[]` if none match or the channel/token isn't
# readable. Requires jq.
slack-api-find-by-text() {
  local channel_id="$1" search_text="$2" oldest="${3:-}" latest="${4:-}"
  _slack_api_require_jq
  local response
  response="$(slack-api-history "$channel_id" "$oldest" "$latest" 200)" || true
  jq --arg needle "$search_text" \
    'if .ok then [.messages[] | select((.text // "" | contains($needle)) or (.attachments // [] | tostring | contains($needle)))] else [] end' \
    <<<"$response"
}

_slack_api_usage() {
  cat <<'EOF'
Usage:
  webapi.sh post <channel_id> <text> [thread_ts]
  webapi.sh history <channel_id> [oldest_ts] [latest_ts] [limit]
  webapi.sh thread-replies <channel_id> <message_ts>
  webapi.sh find-by-text <channel_id> <search_text> [oldest_ts] [latest_ts]

Requires SLACK_BOT_TOKEN (env, ~/.claude/.env, or $(pwd)/.env). See
_slack/README.md for the Bot Token Scopes needed and how to obtain one.
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    _slack_api_usage
    exit 1
  fi
  local cmd="$1"; shift
  case "$cmd" in
    post)            slack-api-post "$@" ;;
    history)          slack-api-history "$@" ;;
    thread-replies)   slack-api-thread-replies "$@" ;;
    find-by-text)     slack-api-find-by-text "$@" ;;
    --help|-h)        _slack_api_usage ;;
    *)                echo "Unknown command: $cmd" >&2; _slack_api_usage; exit 1 ;;
  esac
}

# Run only if executed directly (not sourced) — lets tests/scripts source
# this file and call individual functions without invoking main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
