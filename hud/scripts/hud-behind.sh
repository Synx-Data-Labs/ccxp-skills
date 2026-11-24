#!/usr/bin/env bash
# How far the session repo's current branch is from its remote, for the ccxp-hud repo cell (hud-data.sh sources this).
#
# hud-behind-json <repo_top>
#   prints {"behind":N,"ahead":M,"base":"upstream"|"origin"} on stdout, or nothing when there is nothing to show:
#   not a git repo, detached HEAD, no upstream and no origin default branch, or 0 behind and 0 ahead.
#
# base = "upstream": counted against the branch's own upstream (`@{u}`, its remote-tracking ref on disk).
#        "origin":   no upstream is set, so against origin/<default branch> (origin/HEAD, else origin/main, origin/master).
# The count reads refs already on disk: no network call per render.
#
# Keeping the ref fresh: at most once per HB_TTL (300 s) per repo, ONE detached
#   git fetch --quiet --no-tags --no-prune origin
# (15 s timeout, GIT_TERMINAL_PROMPT=0, lock dir so refreshes never overlap). It writes remote-tracking refs inside .git
# only (FETCH_HEAD is left alone too): never a pull, checkout, merge, rebase or stash. Only `origin` is fetched, so a branch
# whose upstream lives on another remote is counted from that remote's refs as they are on disk (refreshed by your own fetches). The attempt time is cached in <state>/<repo key>.json (like
# hud-version.sh); a failed fetch leaves the refs, and so the last answer, as they were and is retried after the TTL.
# No origin remote: no fetch.
#
# Test hooks: CCXP_HUD_BEHIND_SYNC=1 fetches in the foreground; HUD_BEHIND_STATE_DIR relocates the cache
# (default <profile>/state/hud-behind; with no profile dir and no override nothing is fetched or cached);
# HUD_BEHIND_TTL overrides the 300 s rate limit; HUD_BEHIND_FETCH=0 turns the background fetch off (the count then
# only moves when you fetch yourself).

# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
_HB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-ci.sh
. "$_HB_DIR/hud-ci.sh"

HB_TTL_DEFAULT=300
HB_TIMEOUT=15

hb-state-dir() {
  if [ -n "${HUD_BEHIND_STATE_DIR:-}" ]; then printf '%s' "$HUD_BEHIND_STATE_DIR"
  elif [ -n "${CCXP_PROFILE_DIR:-}" ]; then printf '%s/state/hud-behind' "$CCXP_PROFILE_DIR"
  fi
}

# $1 repo top -> "<ref>\t<base>" for the branch, nothing when HEAD is detached or no reference exists.
hb-ref() {
  local top="$1" ref="" sym=""
  git -C "$top" symbolic-ref -q HEAD >/dev/null 2>&1 || return 0
  ref=$(git -C "$top" rev-parse --symbolic-full-name '@{u}' 2>/dev/null) || ref=""
  if [ -n "$ref" ]; then printf '%s\tupstream' "$ref"; return 0; fi
  sym=$(git -C "$top" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || sym=""
  # A dangling origin/HEAD (its branch is gone) must not hide the fallbacks.
  if [ -z "$sym" ] || ! git -C "$top" rev-parse -q --verify "$sym" >/dev/null 2>&1; then
    local c
    sym=""
    for c in refs/remotes/origin/main refs/remotes/origin/master; do
      git -C "$top" rev-parse -q --verify "$c" >/dev/null 2>&1 && { sym="$c"; break; }
    done
  fi
  [ -z "$sym" ] || printf '%s\torigin' "$sym"
}

# $1 repo top -> a stable key for its cache file (the shared git dir, so linked worktrees share one fetch).
hb-key() {
  local d; d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || d="$1"
  printf '%s' "$d" | cksum | awk '{print $1}'
}

# $1 repo top $2 cache file
hb-fetch() {
  local top="$1" file="$2" tmp now ok=0 sshcmd="${GIT_SSH_COMMAND:-}"
  local -a extra=(--recurse-submodules=no)
  # Keep the user's own ssh command (env, else core.sshCommand) and only add BatchMode, so a custom key still works.
  [ -n "$sshcmd" ] || sshcmd=$(git -C "$top" config core.sshCommand 2>/dev/null) || sshcmd=""
  # A user's own GIT_SSH wrapper (no GIT_SSH_COMMAND, no core.sshCommand) is left alone: GIT_SSH_COMMAND would override it.
  [ -n "$sshcmd" ] || [ -n "${GIT_SSH:-}" ] || sshcmd=ssh
  # FETCH_HEAD belongs to the user's own `git pull`/`git fetch`: never overwrite it (git 2.29+; older git just skips the flag).
  if git fetch -h 2>&1 | grep -q 'write-fetch-head'; then extra+=(--no-write-fetch-head); fi
  now=$(date +%s)
  (
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true
    [ -z "$sshcmd" ] || export GIT_SSH_COMMAND="$sshcmd -o BatchMode=yes"
    hci-run-timeout "$HB_TIMEOUT" git -C "$top" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags --no-prune "${extra[@]}" origin
  ) >/dev/null 2>&1 && ok=1
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  jq -n -c --argjson t "$now" --argjson ok "$ok" '{tried: $t, ok: ($ok == 1)}' >"$tmp"
  mv -f "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# $1 repo top: starts at most one refresh per TTL, never waits for it (unless CCXP_HUD_BEHIND_SYNC=1).
hb-maybe-fetch() {
  local top="$1" dir file lock now tried=0 ttl="${HUD_BEHIND_TTL:-$HB_TTL_DEFAULT}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=$HB_TTL_DEFAULT
  [ "${HUD_BEHIND_FETCH:-1}" != 0 ] || return 0 # opt-out: count from the refs on disk only, never fetch
  dir=$(hb-state-dir); [ -n "$dir" ] || return 0
  git -C "$top" remote get-url origin >/dev/null 2>&1 || return 0
  file="$dir/$(hb-key "$top").json"; lock="$file.lock"; now=$(date +%s)
  if [ -r "$file" ]; then
    tried=$(jq -r '(.tried // 0) | floor' "$file" 2>/dev/null) || tried=0
    [[ "$tried" =~ ^[0-9]+$ ]] || tried=0
    [ "$tried" -le "$now" ] || tried=0
  fi
  [ $((now - tried)) -ge "$ttl" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
  mkdir "$lock" 2>/dev/null || return 0
  if [ "${CCXP_HUD_BEHIND_SYNC:-}" = 1 ]; then
    hb-fetch "$top" "$file"
    rmdir "$lock" 2>/dev/null || true
  else
    ( hb-fetch "$top" "$file"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  return 0
}

hud-behind-json() {
  local top="${1:-}" rb ref base counts ahead behind
  [ -n "$top" ] && git -C "$top" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$top" symbolic-ref -q HEAD >/dev/null 2>&1 || return 0 # detached: nothing is shown, so no fetch either
  hb-maybe-fetch "$top"
  rb=$(hb-ref "$top"); [ -n "$rb" ] || return 0
  ref="${rb%%$'\t'*}"; base="${rb##*$'\t'}"
  counts=$(git -C "$top" rev-list --left-right --count "HEAD...$ref" 2>/dev/null) || return 0
  read -r ahead behind <<<"$counts"
  [[ "$ahead" =~ ^[0-9]+$ && "$behind" =~ ^[0-9]+$ ]] || return 0
  [ $((ahead + behind)) -gt 0 ] || return 0
  jq -n -c --argjson b "$behind" --argjson a "$ahead" --arg base "$base" '{behind: $b, ahead: $a, base: $base}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  hud-behind-json "$@"
fi
