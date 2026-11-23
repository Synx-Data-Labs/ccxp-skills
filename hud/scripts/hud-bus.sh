#!/usr/bin/env bash
# Unread cross-account bus notes for the ccxp-hud band (hud-data.sh sources this). Local files only, no network, no lock.
#
# hud-bus-json <plugin_root> <enabled 1|0>
#   prints {"unread":<n>,"from":"<newest sender>"} or "null".
#
# Asks `_bus/bus.sh status --json` (read-only: it compares the inbox size with the saved cursor and never writes). "null"
# (no cell) when: disabled (`bus` out of the HUD fields), this plugin has no _bus/bus.sh, the profile has no bus config,
# nothing is unread, or anything fails. The answer is untrusted: only a whole count and a plain agent name survive.

hud-bus-json() {
  local root="$1" enabled="${2:-1}" out n from
  [ "$enabled" = 1 ] || { printf 'null'; return 0; }
  [ -r "$root/_bus/bus.sh" ] || { printf 'null'; return 0; }
  out=$(bash "$root/_bus/bus.sh" status --json 2>/dev/null </dev/null) || { printf 'null'; return 0; }
  n=$(printf '%s' "$out" | jq -r '.unread // empty | numbers | floor' 2>/dev/null) || n=""
  [[ "$n" =~ ^[0-9]{1,6}$ ]] && [ "$n" -ge 1 ] || { printf 'null'; return 0; }
  from=$(printf '%s' "$out" | jq -r '.from // "" | strings' 2>/dev/null) || from=""
  [[ "$from" =~ ^[a-z0-9-]{1,32}$ ]] || from=""
  jq -cn --argjson n "$((10#$n))" --arg f "$from" '{unread: $n, from: $f}'
}
