#!/usr/bin/env bash
# auto.sh on|off|status [--dry-run|-n] [--claude-dir DIR]
#
# Opt-in automatic updates for the ccxp-skills plugin (default OFF).
#   on     state file enabled=true, and the marketplace `autoUpdate` key = true in settings.json
#   off    state file enabled=false, and that key = false (only if it was true)
#   status read-only report
# State: <profile>/ccxp-skills-auto-update.json (mode 600). Settings edit is key-level (jq), with a
# timestamped backup, and only when the value would change. Idempotent. Sourceable: hooks/update-check.sh
# reuses the state helpers. A running session never hot-loads a new version by itself: the user types
# /reload-plugins (see hooks/update-check.sh).
set -euo pipefail

AUTO_MARKETPLACE="ccxp-skills"
AUTO_STATE_NAME="ccxp-skills-auto-update.json"

function auto_usage() { echo "usage: auto.sh on|off|status [--dry-run|-n] [--claude-dir DIR]" >&2; }

function auto_state_file() { printf '%s/%s' "$1" "$AUTO_STATE_NAME"; }

# auto_state_get DIR JQ_EXPR -> value ("" when missing/unreadable)
function auto_state_get() {
  local f; f="$(auto_state_file "$1")"
  [ -f "$f" ] || return 0
  jq -r "($2) | if . == null then empty else . end" "$f" 2>/dev/null || true
}

# auto_state_merge DIR JSON_OBJECT: merge keys into the state file (atomic, mode 600, other keys kept).
function auto_state_merge() {
  local dir="$1" patch="$2" f tmp cur='{}'
  f="$(auto_state_file "$dir")"
  [ -f "$f" ] && cur="$(jq -c . "$f" 2>/dev/null || echo '{}')"
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  if jq -n --argjson c "$cur" --argjson p "$patch" '{schema:1, holdMajor:true} + $c + $p' >"$tmp" 2>/dev/null; then
    chmod 600 "$tmp"; mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1   # tmp lives beside the state file in the profile dir
  fi
}

# settings_flag DIR -> true|false|absent|noentry|nofile|invalid
function auto_settings_flag() {
  local s="$1/${2:-settings.json}"
  [ -f "$s" ] || { echo nofile; return 0; }
  jq -r --arg m "$AUTO_MARKETPLACE" '
    if (.extraKnownMarketplaces | type) != "object" or (.extraKnownMarketplaces[$m] | type) != "object" then "noentry"
    elif (.extraKnownMarketplaces[$m] | has("autoUpdate")) then (.extraKnownMarketplaces[$m].autoUpdate | tostring)
    else "absent" end' "$s" 2>/dev/null || echo invalid
}

# auto_set_native DIR true|false DRY: key-level edit with backup; prints what it did.
function auto_set_native() {
  local dir="$1" want="$2" dry="$3" s cur tmp bak
  s="$dir/settings.json"
  # follow a symlinked settings.json so the edit lands in the real file, not a replacement for the link
  if [ -L "$s" ]; then s="$(readlink "$s")"; case "$s" in /*) ;; *) s="$dir/$s" ;; esac; fi
  cur="$(auto_settings_flag "$(dirname "$s")" "$(basename "$s")")"
  case "$cur" in
    nofile|noentry) echo "auto: native autoUpdate: no extraKnownMarketplaces.$AUTO_MARKETPLACE entry in $s, left alone (the SessionStart hook does the updating)"; return 0 ;;
    invalid) echo "auto: native autoUpdate: $s is not valid JSON, left alone" >&2; return 0 ;;
  esac
  if [ "$cur" = "$want" ] || { [ "$want" = false ] && [ "$cur" = absent ]; }; then
    echo "auto: native autoUpdate already $want in settings.json (no change)"; return 0
  fi
  if [ "$dry" = 1 ]; then echo "auto: --dry-run: would set extraKnownMarketplaces.$AUTO_MARKETPLACE.autoUpdate=$want in $s"; return 0; fi
  bak="$s.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$s" "$bak"
  tmp="$(mktemp "$s.XXXXXX")"
  if jq --arg m "$AUTO_MARKETPLACE" --argjson v "$want" '.extraKnownMarketplaces[$m].autoUpdate = $v' "$s" >"$tmp" 2>/dev/null; then
    chmod "$(stat -c %a "$s" 2>/dev/null || stat -f %Lp "$s")" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv "$tmp" "$s"
    echo "auto: set extraKnownMarketplaces.$AUTO_MARKETPLACE.autoUpdate=$want in $s (backup $bak)"
  else
    rm -f "$tmp"; echo "auto: settings edit failed; $s unchanged" >&2; return 1
  fi
}

function auto_set() {
  local dir="$1" want="$2" dry="$3" enabled
  enabled="$(auto_state_get "$dir" '.enabled')"
  if [ "$enabled" = "$want" ]; then
    echo "auto: already $( [ "$want" = true ] && echo on || echo off ) (state file unchanged)"
  elif [ "$dry" = 1 ]; then
    echo "auto: --dry-run: would set enabled=$want in $(auto_state_file "$dir")"
  else
    auto_state_merge "$dir" "{\"enabled\":$want}"
    echo "auto: $( [ "$want" = true ] && echo on || echo off ) (state file $(auto_state_file "$dir"))"
  fi
  auto_set_native "$dir" "$want" "$dry"
  if [ "$want" = true ]; then
    echo "auto: when a newer release is found at session start, it is downloaded and you get ONE message per version."
    echo "auto: a running session cannot hot-load it: you type /reload-plugins; restart once no jobs run (persona refresh); then /autopilot on."
    echo "auto: major version bumps are held (notice only). Turn off with: /update auto off"
  fi
}

function auto_status() {
  local dir="$1" en f
  f="$(auto_state_file "$dir")"; en="$(auto_state_get "$dir" '.enabled')"
  echo "auto: profile        $dir"
  echo "auto: auto-update    $( [ "$en" = true ] && echo ON || echo off )"
  echo "auto: native flag    $(auto_settings_flag "$dir") (extraKnownMarketplaces.$AUTO_MARKETPLACE.autoUpdate)"
  local v
  for v in DISABLE_AUTOUPDATER DISABLE_UPDATES CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC; do
    [ -z "${!v:-}" ] || echo "auto: env $v is set: Claude Code's own plugin auto-update is off unless FORCE_AUTOUPDATE_PLUGINS=1"
  done
  if [ -f "$f" ]; then
    echo "auto: last check     $(auto_state_get "$dir" '.lastCheckIso')"
    echo "auto: latest seen    $(auto_state_get "$dir" '.lastSeen')"
    echo "auto: notified for   $(auto_state_get "$dir" '.notifiedFor')"
    echo "auto: persona for    $(auto_state_get "$dir" '.personaFor')"
  fi
  local ap=dev/.autopilot-state.json
  if [ -f "$ap" ]; then
    echo "auto: autopilot      $(jq -r '(.status // "?") + (if .busy_since then " (busy)" else " (idle)" end)' "$ap" 2>/dev/null || echo '?') in $PWD"
  fi
}

function auto_main() {
  local verb="${1:-}" dry=0 dir
  [ $# -gt 0 ] && shift
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) dry=1; shift ;;
      --claude-dir) dir="${2:?--claude-dir requires a value}"; shift 2 ;;
      -h|--help) auto_usage; return 0 ;;
      *) auto_usage; return 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { echo "auto: ERROR: jq is required" >&2; return 1; }
  case "$verb" in
    on)  [ -d "$dir" ] || { echo "auto: ERROR: $dir is not a directory" >&2; return 1; }; auto_set "$dir" true "$dry" ;;
    off) [ -d "$dir" ] || { echo "auto: ERROR: $dir is not a directory" >&2; return 1; }; auto_set "$dir" false "$dry" ;;
    status) auto_status "$dir" ;;
    -h|--help) auto_usage ;;
    *) auto_usage; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  auto_main "$@"
fi
