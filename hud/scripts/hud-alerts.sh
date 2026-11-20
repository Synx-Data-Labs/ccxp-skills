#!/usr/bin/env bash
# Slack-alerts-check staleness for the ccxp-hud band (hud-data.sh sources this). Local files only, no network.
#
# hud-alerts-json <plugin_root> <enabled 1|0>
#   prints {"checked_at":<epoch, 0 = never>,"held":true|false} or "null".
#
# The ccxp-agent persona's "Slack alerts check" records every check in ${CCXP_ALERTS_DIR:-<profile>/ccxp-alerts}/last-check
# (epoch seconds, written by agent-pairing/scripts/alerts-due.sh) and keeps alerts it held back under the cap in `hold`.
# The cell makes "we are not checking Slack" visible: it ages the last check, says "never checked" when there is none,
# and flags a non-empty `hold`.
#
# Degrades to "null" (no cell, nothing drawn) when: disabled (alerts: false in the HUD config), CCXP_ALERTS=0 (the
# persona's own off switch), or this plugin version has no agent-pairing/scripts/alerts-due.sh (it predates the alerts
# check, so there is nothing that could ever write the state). A missing state dir under a plugin that has the script
# is "never checked" (checked_at 0). The file content is untrusted: only a plain epoch survives.

# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"

hud-alerts-json() {
  local root="$1" enabled="${2:-1}" dir last=0 held=false
  [ "$enabled" = 1 ] || { printf 'null'; return 0; }
  [ "${CCXP_ALERTS:-1}" != 0 ] || { printf 'null'; return 0; }
  [ -r "$root/agent-pairing/scripts/alerts-due.sh" ] || { printf 'null'; return 0; }
  dir="${CCXP_ALERTS_DIR:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-alerts}}"
  [ -n "$dir" ] || { printf 'null'; return 0; }
  if [ -r "$dir/last-check" ]; then
    last=$(head -c 20 "$dir/last-check" 2>/dev/null | tr -d '[:space:]') || last=0
    [[ "$last" =~ ^[0-9]{1,12}$ ]] || last=0
    [ "$last" -le "$(date +%s)" ] || last=0 # a future stamp is not a check
  fi
  [ ! -s "$dir/hold" ] || held=true
  printf '{"checked_at":%s,"held":%s}' "$((10#$last))" "$held"
}
