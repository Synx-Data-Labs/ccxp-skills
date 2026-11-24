#!/usr/bin/env bash
# Latest subscription rate-limit snapshot for the autopilot (T20261124-168446). Only the HUD mod sees the engine's
# rate limits (the status-line `rate_limits` object), so it writes them here after each refresh and any other script
# can read them back. Local file only, no network, no secrets: percentages, reset times and the write time.
#
#   hud-rate-cache.sh write            stdin: {"five_hour":{"used_percentage":N,"resets_at":E},"seven_day":{...}}
#   hud-rate-cache.sh read [--max-age SECONDS]
#   hud-rate-cache.sh path
#
# File: <cache dir>/rate-limits.json, the cache dir being $CCXP_HUD_CACHE_DIR or <profile>/state/hud-cache. Mode 600,
# replaced atomically (temp file, then rename), so a reader never sees half a file.
#   {"version":1,"written_at":<epoch s>,"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{...}}
# Field names and units follow the status-line docs: used_percentage 0-100, resets_at Unix epoch seconds. A window the
# engine did not report (API-key login, older version, one window missing) is simply absent, never null.
#
# write: nothing valid on stdin (no window with a numeric percentage) means no write and exit 0; an older file is kept
# and goes stale by its own written_at. read: exit 0 and the JSON on stdout, with windows whose resets_at has passed
# removed; 1 no usable file; 2 older than --max-age; 3 no live window left. HUD_RATE_NOW is the test clock.

_HRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -r "$_HRC_DIR/../../_session/profile-dir.sh" ] && . "$_HRC_DIR/../../_session/profile-dir.sh"

_hrc-now() { printf '%s' "${HUD_RATE_NOW:-$(date +%s)}"; }

_hrc-dir() {
  local d="${CCXP_HUD_CACHE_DIR:-}"
  [ -n "$d" ] || { [ -n "${CCXP_PROFILE_DIR:-}" ] && d="$CCXP_PROFILE_DIR/state/hud-cache"; }
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

hud-rate-cache-path() {
  local d
  d=$(_hrc-dir) || return 1
  printf '%s/rate-limits.json' "$d"
}

# stdin: the windows object -> the file. Untrusted input: only numbers survive.
hud-rate-cache-write() {
  local dir file now body tmp old
  dir=$(_hrc-dir) || return 0
  file="$dir/rate-limits.json"
  now=$(_hrc-now)
  [ -r "$file" ] && old=$(cat "$file" 2>/dev/null) || old='{}'
  body=$(jq -c --argjson now "$now" --argjson old "$(printf '%s' "$old" | jq -c 'if type == "object" then . else {} end' 2>/dev/null || echo '{}')" '
    def win($w): if ($w | type) == "object"
      then ($w | if (.used_percentage | type) == "number" and .used_percentage >= 0 and .used_percentage <= 100
        then {used_percentage: .used_percentage}
             + (if (.resets_at | type) == "number" and .resets_at > 0 then {resets_at: .resets_at} else {} end)
        else empty end)
      else empty end;
    # Several sessions share the file and an idle one may hold older numbers: within one window usage only grows and a
    # later reset time is a newer window, so keep whichever of old and new is the newer truth.
    def newer($o; $n):
      if ($o | type) != "object" or ($o.used_percentage | type) != "number" then $n
      elif ($o.resets_at // 0) > ($n.resets_at // 0) then $o
      elif ($o.resets_at // 0) == ($n.resets_at // 0) and $o.used_percentage > $n.used_percentage then $o
      else $n end;
    (first(win(.five_hour)) // null) as $f | (first(win(.seven_day)) // null) as $s
    | if ($f == null and $s == null) then empty
      else {version: 1, written_at: $now}
           + (if $f != null then {five_hour: newer($old.five_hour; $f)} else {} end)
           + (if $s != null then {seven_day: newer($old.seven_day; $s)} else {} end) end' 2>/dev/null) || return 0
  [ -n "$body" ] || return 0
  (
    umask 077
    mkdir -p "$dir" 2>/dev/null || exit 0
    tmp=$(mktemp "$dir/rate-limits.XXXXXX" 2>/dev/null) || exit 0
    if printf '%s\n' "$body" > "$tmp" && chmod 600 "$tmp"; then
      mv -f "$tmp" "$file" 2>/dev/null || command rm -f "$tmp" 2>/dev/null
    else
      command rm -f "$tmp" 2>/dev/null
    fi
  )
  return 0
}

hud-rate-cache-read() {
  local max="" file now out at
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-age)
        [ $# -ge 2 ] || { echo "hud-rate-cache read: --max-age needs whole seconds" >&2; return 64; }
        max="$2"; shift 2 ;;
      *) echo "hud-rate-cache read: unknown argument: $1" >&2; return 64 ;;
    esac
  done
  [ -z "$max" ] || [[ "$max" =~ ^[0-9]+$ ]] || { echo "hud-rate-cache read: --max-age needs whole seconds" >&2; return 64; }
  file=$(hud-rate-cache-path) || return 1
  [ -r "$file" ] || return 1
  now=$(_hrc-now)
  at=$(jq -r 'if (.version == 1 and (.written_at | type) == "number") then .written_at else empty end' "$file" 2>/dev/null) || return 1
  [ -n "$at" ] || return 1
  if [ -n "$max" ] && [ $(( now - ${at%.*} )) -gt "$max" ]; then return 2; fi
  out=$(jq -c --argjson now "$now" '
    def live: select((.resets_at // null) == null or .resets_at > $now);
    . as $r | {version, written_at}
    + (if ($r.five_hour | type) == "object" then (first($r.five_hour | live | {five_hour: .}) // {}) else {} end)
    + (if ($r.seven_day | type) == "object" then (first($r.seven_day | live | {seven_day: .}) // {}) else {} end)' "$file" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'has("five_hour") or has("seven_day")' >/dev/null 2>&1 || return 3
  printf '%s\n' "$out"
}

hud-rate-cache() {
  local cmd="${1:-}"
  [ $# -eq 0 ] || shift
  case "$cmd" in
    write) hud-rate-cache-write ;;
    read) hud-rate-cache-read "$@" ;;
    path) hud-rate-cache-path ;;
    *) echo "usage: hud-rate-cache.sh write | read [--max-age SECONDS] | path" >&2; return 64 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  hud-rate-cache "$@"
fi
