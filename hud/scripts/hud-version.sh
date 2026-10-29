#!/usr/bin/env bash
# ccxp-skills version data for the ccxp-hud band (hud-data.sh sources this).
#
# hud-version-json <plugin_root> <enabled 1|0> [<repo_url>]
#   prints {"installed":"X.Y.Z","latest":"X.Y.Z"|null} or "null" (disabled, or no readable version).
#
# installed = the running plugin's own .claude-plugin/plugin.json (local read, no network).
# latest    = the highest plain `ccxp-skills--vX.Y.Z` tag of the public repo, from
#             `git ls-remote --tags` (needs no credentials and no gh). A prerelease tag is ignored.
# `latest` is only ever printed when it is STRICTLY newer than installed (numeric semver compare).
#
# Never blocks the caller: it answers from an on-disk cache and, when the cache is older than
# 6 h, starts ONE detached refresh (8 s timeout, lock dir, no credential prompt). Offline or
# git missing: the old answer is kept and the next try is ~15 min later. Remote output is
# untrusted: only strings that match the tag pattern survive.
#
# Test hooks: CCXP_HUD_VERSION_SYNC=1 refreshes in the foreground; HUD_VERSION_STATE_DIR
# relocates the cache (default ${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-version);
# HUD_VERSION_REMOTE overrides the remote (a local path works).

_HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-ci.sh
. "$_HV_DIR/hud-ci.sh"

HVR_TTL=21600
HVR_RETRY=900
HVR_TIMEOUT=8
HVR_REMOTE_DEFAULT="https://github.com/Synx-Data-Labs/ccxp-skills.git"
HVR_SEMVER_RE='^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-[0-9A-Za-z.-]{1,40})?$'

hvr-state-dir() { printf '%s' "${HUD_VERSION_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/hud-version}"; }

# $1 candidate -> 0 when it is a plain X.Y.Z (optionally -prerelease) version.
hvr-valid() { [[ "$1" =~ $HVR_SEMVER_RE ]]; }

# $1 A, $2 B -> exit 0 when A is strictly newer than B. Both must be valid, else 1.
# Numeric per component (10 > 9); a prerelease sorts below its release; two prereleases
# of the same core are never "newer" (not needed here).
hvr-semver-gt() {
  hvr-valid "$1" && hvr-valid "$2" || return 1
  local a b i
  [[ "$1" =~ $HVR_SEMVER_RE ]]; a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  [[ "$2" =~ $HVR_SEMVER_RE ]]; b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
  for i in 0 1 2; do
    if [ $((10#${a[i]})) -gt $((10#${b[i]})) ]; then return 0; fi
    if [ $((10#${a[i]})) -lt $((10#${b[i]})) ]; then return 1; fi
  done
  [ -z "${a[3]}" ] && [ -n "${b[3]}" ]
}

# $1 plugin root -> its version from .claude-plugin/plugin.json ("" when missing or invalid).
hvr-installed() {
  local v
  v=$(jq -r 'if (.version | type) == "string" then .version else "" end' "$1/.claude-plugin/plugin.json" 2>/dev/null | head -n1) || v=""
  hvr-valid "$v" && printf '%s' "$v"
  return 0
}

# stdin: `git ls-remote --tags` lines -> the highest plain release version ("" when none).
hvr-highest-tag() {
  local ref v best=""
  while read -r _ ref; do
    ref="${ref%^{\}}"
    v="${ref#refs/tags/ccxp-skills--v}"
    [ "$v" != "$ref" ] || continue
    [[ "$v" =~ ^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$ ]] || continue
    if [ -z "$best" ] || hvr-semver-gt "$v" "$best"; then best="$v"; fi
  done
  printf '%s' "$best"
}

# $1 cache file $2 remote
hvr-refresh() {
  local file="$1" remote="$2" tmp now latest="" prev=""
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if command -v git >/dev/null 2>&1 \
    && GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GIT_SSH_COMMAND='ssh -o BatchMode=yes' hci-run-timeout "$HVR_TIMEOUT" git ls-remote --tags "$remote" 'ccxp-skills--v*' >"$tmp" 2>/dev/null; then
    latest=$(hvr-highest-tag <"$tmp")
  fi
  prev=$(jq -r '.latest // ""' "$file" 2>/dev/null) || prev=""
  if [ -n "$latest" ]; then
    jq -n -c --arg l "$latest" --argjson f "$now" '{latest: $l, fetched: $f}' >"$tmp"
  else
    # Failed or no tag: keep the old answer and try again in ~15 min.
    jq -n -c --arg l "$prev" --argjson f "$((now - HVR_TTL + HVR_RETRY))" '{latest: $l, fetched: $f}' >"$tmp"
  fi
  mv -f "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null
  return 0
}

hud-version-json() {
  local root="$1" enabled="$2" remote="${3:-${HUD_VERSION_REMOTE:-$HVR_REMOTE_DEFAULT}}"
  [ "$enabled" = 1 ] || { printf 'null'; return 0; }
  local installed; installed=$(hvr-installed "$root")
  [ -n "$installed" ] || { printf 'null'; return 0; }

  local dir file now fetched=0 cached="" latest=""
  dir=$(hvr-state-dir)
  file="$dir/latest.json"
  now=$(date +%s)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
    [ "$fetched" -le "$now" ] || fetched=0 # a future timestamp (clock skew, hand edit) must not stop refreshes
  fi

  if [ $((now - fetched)) -ge "$HVR_TTL" ] && mkdir -p "$dir" 2>/dev/null; then
    local lock="$dir/latest.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${CCXP_HUD_VERSION_SYNC:-}" = 1 ]; then
        hvr-refresh "$file" "$remote"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( hvr-refresh "$file" "$remote"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi

  [ -z "$cached" ] || latest=$(jq -r '.latest // ""' <<<"$cached" 2>/dev/null | head -n1) || latest=""
  hvr-semver-gt "$latest" "$installed" || latest=""
  jq -n -c --arg i "$installed" --arg l "$latest" '{installed: $i, latest: (if $l == "" then null else $l end)}'
}
