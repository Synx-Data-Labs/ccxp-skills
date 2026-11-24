#!/usr/bin/env bash
# ccxp-skills version data for the ccxp-hud band (hud-data.sh sources this).
#
# hud-version-json <plugin_root> <enabled 1|0> [<repo_url>]
#   prints {"installed":"X.Y.Z","latest":"X.Y.Z"|null[,"url":"https://github.com/<owner>/<repo>"]} or "null"
#   (disabled, or no readable version). `url` is the plugin's GitHub location from its own plugin.json
#   (`repository`, else `homepage`, a `.git` suffix or `#fragment` dropped); absent when neither is a plain
#   github.com repo URL (the mod then falls back to the public ccxp-skills URL).
#
# installed = the running plugin's own .claude-plugin/plugin.json (local read, no network).
# latest    = the highest plain `ccxp-skills--vX.Y.Z` tag of the public repo, from
#             `git ls-remote --tags` (needs no credentials and no gh). A prerelease tag is ignored.
# `latest` is the highest known release whatever its relation to installed (the HUD decides between
#             "(latest)", "(X available)" and plain); null while unknown (no lookup yet, offline, no tag).
#
# unreleased = the commits on the default branch (main) after the installed version's release tag
#             `ccxp-skills--v<installed>`: {"count":N,"subjects":[newest first, at most 3, one line each]}; the key is
#             absent when there are none, the tag is unknown, or the lookup never succeeded (offline). Source: the
#             public GitHub compare API via `curl` (no credentials, no gh, no git checkout, so it works from the
#             installed plugin cache), cached in <state>/unreleased.json for 1 h (HVU_TTL), one detached refresh at a
#             time (8 s timeout, lock dir); a change of installed version or repo drops the old answer. Subjects are
#             untrusted: control characters stripped, 72 chars at most. Override the request URL with HUD_UNRELEASED_URL (tests).
#
# Never blocks the caller: it answers from an on-disk cache and, when the cache is older than
# 6 h OR the running plugin.json changed since the cache was written (its mtime is stored in the
# cache as "pm"; an update or reinstall of the plugin re-checks once, not after the TTL), starts ONE detached refresh (8 s timeout, lock dir, no credential prompt). Offline or
# git missing: the old answer is kept and the next try is ~15 min later. Remote output is
# untrusted: only strings that match the tag pattern survive.
#
# Test hooks: CCXP_HUD_VERSION_SYNC=1 refreshes in the foreground; HUD_VERSION_STATE_DIR
# relocates the cache (default <profile>/state/hud-version);
# HUD_VERSION_REMOTE overrides the remote (a local path works); with it set, the unreleased lookup runs only when
# HUD_UNRELEASED_URL is set too.


# Active profile dir (CCXP_PROFILE_DIR), see _session/profile-dir.sh.
# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
_HV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-ci.sh
. "$_HV_DIR/hud-ci.sh"

HVR_TTL=21600
HVR_RETRY=900
HVR_MIN_RECHECK=60 # a plugin.json change re-checks at most once a minute (two live plugin roots must not ping-pong the shared cache)
HVR_TIMEOUT=8
HVR_REMOTE_DEFAULT="https://github.com/Synx-Data-Labs/ccxp-skills.git"
HVU_TTL=3600
HVU_API_DEFAULT="https://api.github.com"
HVR_SEMVER_RE='^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-[0-9A-Za-z.-]{1,40})?$'

hvr-state-dir() { printf '%s' "${HUD_VERSION_STATE_DIR:-${CCXP_PROFILE_DIR:-}/state/hud-version}"; }

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

# Keep the URL pattern in sync with PLUGIN_URL_RE in hud/model.ts.
# $1 plugin root -> the plugin's GitHub repo URL from plugin.json ("" when missing or not a plain github.com/<owner>/<repo>).
hvr-url() {
  local u f
  for f in repository homepage; do
    u=$(jq -r --arg f "$f" '(.[$f] | if type == "object" then .url else . end) | if type == "string" then . else "" end' "$1/.claude-plugin/plugin.json" 2>/dev/null | head -n1) || u=""
    u="${u%%#*}"; u="${u%/}"; u="${u%.git}"; u="${u%/}"
    if [[ "$u" =~ ^https://github\.com/[A-Za-z0-9_][A-Za-z0-9_.-]{0,59}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$ ]]; then printf '%s' "$u"; return 0; fi
  done
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

# $1 plugin root -> mtime (epoch) of its plugin.json, "0" when unreadable. BSD stat first, then GNU.
hvr-plugin-mtime() {
  local f="$1/.claude-plugin/plugin.json" m
  m=$(stat -f %m "$f" 2>/dev/null) || m=""
  [[ "$m" =~ ^[0-9]+$ ]] || m=$(stat -c %Y "$f" 2>/dev/null) || m=""
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s' "$m"
}

# $1 cache file $2 remote $3 plugin.json mtime recorded as "pm" (default 0)
hvr-refresh() {
  local file="$1" remote="$2" pm="${3:-0}" tmp now latest="" prev=""
  [[ "$pm" =~ ^[0-9]+$ ]] || pm=0
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if command -v git >/dev/null 2>&1 \
    && GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GIT_SSH_COMMAND='ssh -o BatchMode=yes' hci-run-timeout "$HVR_TIMEOUT" git ls-remote --tags "$remote" 'ccxp-skills--v*' >"$tmp" 2>/dev/null; then
    latest=$(hvr-highest-tag <"$tmp")
  fi
  prev=$(jq -r '.latest // ""' "$file" 2>/dev/null) || prev=""
  if [ -n "$latest" ]; then
    jq -n -c --arg l "$latest" --argjson f "$now" --argjson pm "$pm" '{latest: $l, fetched: $f, pm: $pm}' >"$tmp"
  else
    # Failed or no tag: keep the old answer and try again in ~15 min.
    jq -n -c --arg l "$prev" --argjson f "$((now - HVR_TTL + HVR_RETRY))" --argjson pm "$pm" '{latest: $l, fetched: $f, pm: $pm}' >"$tmp"
  fi
  mv -f "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# $1 repo URL (https://github.com/<owner>/<repo>) $2 installed version -> the compare API URL for tag...main.
hvu-api-url() {
  local slug="${1#https://github.com/}"
  printf '%s/repos/%s/compare/ccxp-skills--v%s...main' "${HVU_API:-$HVU_API_DEFAULT}" "$slug" "$2"
}

# stdin: compare API JSON -> {"count":N,"subjects":[...]} (newest first, 3 at most), exit 1 when it is not a compare answer.
hvu-parse() {
  jq -c -e 'if (.ahead_by | type) == "number" then {count: (.ahead_by | floor), subjects: ([.commits[]? | .commit.message | tostring | split("\n")[0] | explode | map(select(. >= 32 and . != 127 and (. < 128 or . > 159))) | implode | .[0:72]] | reverse | .[0:3])} else empty end' 2>/dev/null
}

# $1 cache file $2 key ("<installed> <repo>") $3 api url
hvu-refresh() {
  local file="$1" key="$2" api="$3" tmp now body="" prev="" empty='{"count":0,"subjects":[]}'
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if command -v curl >/dev/null 2>&1; then
    body=$(curl -fsS --max-time "$HVR_TIMEOUT" -H 'Accept: application/vnd.github+json' "$api" 2>/dev/null | hvu-parse) || body=""
  fi
  if [ -n "$body" ]; then
    jq -n -c --arg k "$key" --argjson f "$now" --argjson d "$body" '{key: $k, fetched: $f} + $d' >"$tmp"
  else
    # Failed: keep the old answer for the same key and retry in ~15 min.
    prev=$(jq -c --arg k "$key" 'select(.key == $k) | {count, subjects}' "$file" 2>/dev/null) || prev=""
    jq -n -c --arg k "$key" --argjson f "$((now - HVU_TTL + HVR_RETRY))" --argjson d "${prev:-$empty}" '{key: $k, fetched: $f} + $d' >"$tmp"
  fi
  mv -f "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# $1 installed $2 repo url ("" = the public default) -> {"count":N,"subjects":[...]} on stdout, nothing when unknown or zero.
# Answers from the cache; starts ONE detached refresh when it is older than HVU_TTL or was written for another version/repo.
hvu-json() {
  # A relocated tag remote (HUD_VERSION_REMOTE, a test hook) without its own HUD_UNRELEASED_URL: no lookup, never a stray request.
  [ -z "${HUD_VERSION_REMOTE:-}" ] || [ -n "${HUD_UNRELEASED_URL:-}" ] || return 0
  local installed="$1" url="${2:-${HVR_REMOTE_DEFAULT%.git}}" dir file key now fetched=0 cached="" ckey=""
  dir=$(hvr-state-dir); file="$dir/unreleased.json"; key="$installed $url"; now=$(date +%s)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    ckey=$(jq -r '.key // ""' <<<"${cached:-null}" 2>/dev/null) || ckey=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
    [ "$fetched" -le "$now" ] || fetched=0
  fi
  local age=$((now - fetched))
  if { [ "$age" -ge "$HVU_TTL" ] || { [ "$ckey" != "$key" ] && [ "$age" -ge "$HVR_MIN_RECHECK" ]; }; } && mkdir -p "$dir" 2>/dev/null; then
    local lock="$dir/unreleased.lock" api="${HUD_UNRELEASED_URL:-$(hvu-api-url "$url" "$installed")}"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${CCXP_HUD_VERSION_SYNC:-}" = 1 ]; then
        hvu-refresh "$file" "$key" "$api"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""; ckey="$key"
      else
        ( hvu-refresh "$file" "$key" "$api"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi
  [ "$ckey" = "$key" ] || return 0
  jq -c 'select((.count | type) == "number" and .count > 0) | {count: (.count | floor), subjects: ((.subjects // []) | map(select(type == "string")) | .[0:3])}' <<<"${cached:-null}" 2>/dev/null || true
}

hud-version-json() {
  local root="$1" enabled="$2" remote="${3:-${HUD_VERSION_REMOTE:-$HVR_REMOTE_DEFAULT}}"
  [ "$enabled" = 1 ] || { printf 'null'; return 0; }
  local installed; installed=$(hvr-installed "$root")
  [ -n "$installed" ] || { printf 'null'; return 0; }

  local dir file now fetched=0 cached="" latest="" pm=0 cached_pm=-1
  pm=$(hvr-plugin-mtime "$root")
  dir=$(hvr-state-dir)
  file="$dir/latest.json"
  now=$(date +%s)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
    [ "$fetched" -le "$now" ] || fetched=0 # a future timestamp (clock skew, hand edit) must not stop refreshes
    cached_pm=$(jq -r '(.pm // -1) | floor' <<<"${cached:-null}" 2>/dev/null) || cached_pm=-1
    [[ "$cached_pm" =~ ^-?[0-9]+$ ]] || cached_pm=-1
  fi

  # Due: the TTL ran out, or the plugin.json differs from the one the cache was written for (an old cache without "pm" counts as changed once),
  # but a change re-checks no more often than every HVR_MIN_RECHECK seconds.
  if { [ $((now - fetched)) -ge "$HVR_TTL" ] || { [ "$cached_pm" != "$pm" ] && [ $((now - fetched)) -ge "$HVR_MIN_RECHECK" ]; }; } && mkdir -p "$dir" 2>/dev/null; then
    local lock="$dir/latest.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${CCXP_HUD_VERSION_SYNC:-}" = 1 ]; then
        hvr-refresh "$file" "$remote" "$pm"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( hvr-refresh "$file" "$remote" "$pm"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi

  [ -z "$cached" ] || latest=$(jq -r '.latest // ""' <<<"$cached" 2>/dev/null | head -n1) || latest=""
  hvr-valid "$latest" || latest=""
  local url unrel; url=$(hvr-url "$root")
  unrel=$(hvu-json "$installed" "$url") || unrel=""
  jq -n -c --arg i "$installed" --arg l "$latest" --arg u "$url" --argjson n "${unrel:-null}" '{installed: $i, latest: (if $l == "" then null else $l end)} + (if $u == "" then {} else {url: $u} end) + (if $n == null then {} else {unreleased: $n} end)'
}
