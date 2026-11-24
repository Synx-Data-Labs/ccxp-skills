#!/usr/bin/env bash
# Customer-issue statistics for the ccxp-hud band (hud-data.sh sources this). Opt-in: nothing runs unless the
# HUD config names an `issues` repo (`{"issues": {"repo": "<owner/name>", "ghConfigDir": "<dir>"}}`).
#
# hud-issues-json <owner/name> [gh-config-dir] prints
#   {"open":N,"undelivered":M,"hwm":{"d180":N,"d30":N,"d7":N}}   or "null" when unknown.
#   open        = open issues of the repo
#   undelivered = open issues WITHOUT the delivered status label (default `status:delivered`, taken from the
#                 customer-support skill's label_names.sh when present; override HUD_ISSUES_DELIVERED_LABEL)
#   hwm         = the largest `open` over the last 180 / 30 / 7 days, nested windows (sl-hwm-windows in
#                 hud-queue-hwm.sh, kept for this cell; the queue cell uses separate last month / last week / this
#                 week windows now). The value at the window start counts.
#
# Two series feed hwm, stored in the queue-hwm state dir under a key of "issues:<repo>":
#   1. history - rebuilt from every refresh: +1 at each issue's createdAt, -1 at its closedAt (one `gh issue list`
#                call, --state all, latest HUD_ISSUES_LIMIT = 3000 issues). A reopened issue (no closedAt) counts as open
#                since its creation; a repo with more issues than the limit understates the oldest history.
#   2. samples - the open count the HUD last saw, appended when it changes (sl-hwm-sample).
#
# Never blocks the caller: it answers from the on-disk cache and starts ONE detached refresh when the cache is older
# than HUD_ISSUES_TTL (default 900 s), 20 s timeout, lock dir. gh missing, signed out, offline or no access keep the
# old answer / print "null"; gh's output is never passed on and the repo is only read (`gh issue list`).
# gh JSON is untrusted: only counts survive the jq mapping.
#
# Overrides (also test hooks): HUD_ISSUES_TTL, HUD_ISSUES_SYNC=1 (refresh in the foreground), HUD_ISSUES_STATE_DIR
# (default <profile>/state/hud-issues), HUD_ISSUES_NOW (fake epoch; defaults to HUD_HWM_NOW, then the clock).

# Active profile dir (CCXP_PROFILE_DIR), see _session/profile-dir.sh.
# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
_HI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-queue-hwm.sh
. "$_HI_DIR/hud-queue-hwm.sh" # sl-hwm-key, sl-hwm-sample, sl-hwm-windows, sl-run-timeout (hud-lib.sh)
# shellcheck source=/dev/null
[ -r "$_HI_DIR/../../customer-support/scripts/label_names.sh" ] && . "$_HI_DIR/../../customer-support/scripts/label_names.sh"

HUD_ISSUES_TIMEOUT=20
HUD_ISSUES_LIMIT=3000

_hi-now() { printf '%s' "${HUD_ISSUES_NOW:-${HUD_HWM_NOW:-$(date +%s)}}"; }
_hi-dir() { printf '%s' "${HUD_ISSUES_STATE_DIR:-${CCXP_PROFILE_DIR:-}/state/hud-issues}"; }
_hi-label() { printf '%s' "${HUD_ISSUES_DELIVERED_LABEL:-${CS_L_DELIVERED:-status:delivered}}"; }
# $1 repo -> the hwm state key (distinct from any repo-root key)
_hi-key() { sl-hwm-key "issues:$1"; }

# $1 delivered label, stdin: `gh issue list --json state,createdAt,closedAt,labels` -> {"open":N,"undelivered":M}; nothing on bad input.
sl-issues-count() {
  jq -c --arg lbl "$1" '
    if type != "array" then empty else
      [ .[] | select(type == "object" and .state == "OPEN") ] as $o
      | {open: ($o | length),
         undelivered: ([ $o[] | select(([.labels[]? | .name?] | index($lbl)) == null) ] | length)}
    end' 2>/dev/null
}

# stdin: the same JSON -> "epoch<TAB>open count" lines (oldest first), one per create/close event. Pure.
sl-issues-series() {
  jq -r '
    if type != "array" then empty else
      [ .[] | select(type == "object")
        | ((.createdAt | tostring | fromdateiso8601?) // null) as $c
        | ((.closedAt // "" | tostring | fromdateiso8601?) // null) as $x
        | (if $c != null then {t: $c, d: 1} else empty end),
          (if $x != null and .state == "CLOSED" then {t: $x, d: -1} else empty end) ]
      | sort_by(.t)
      | reduce .[] as $e ({n: 0, out: []}; .n = ([.n + $e.d, 0] | max) | .out += ["\($e.t)\t\(.n)"])
      | .out[]
    end' 2>/dev/null
}

# $1 cache file $2 repo $3 gh config dir ("" = default) -> refresh cache and history; never fails.
hi-refresh() {
  local file="$1" repo="$2" ghdir="$3" tmp now out="" dir key
  now=$(_hi-now); dir=$(_hi-dir); key=$(_hi-key "$repo")
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if ( [ -z "$ghdir" ] || export GH_CONFIG_DIR="$ghdir"; export GH_PROMPT_DISABLED=1
       sl-run-timeout "$HUD_ISSUES_TIMEOUT" gh issue list --repo "$repo" --state all --limit "$HUD_ISSUES_LIMIT" --json state,createdAt,closedAt,labels ) >"$tmp" 2>/dev/null \
    && out=$(sl-issues-count "$(_hi-label)" <"$tmp") && [ -n "$out" ]; then
    local hist; hist="$(_hw-dir)/hist-$key"
    mkdir -p "$(_hw-dir)" 2>/dev/null || true
    sl-issues-series <"$tmp" >"$tmp.hist" 2>/dev/null && mv -f "$tmp.hist" "$hist" 2>/dev/null
    rm -f "$tmp.hist" 2>/dev/null
    jq -c --argjson now "$now" '. + {fetched: $now}' <<<"$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
  elif [ -r "$file" ]; then
    # Failed: keep the previous answer, only move the fetch time (so a failure is not retried every poll).
    { jq -c --argjson now "$now" '.fetched = $now' "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"; } \
      || { printf '{"fetched":%s}\n' "$now" >"$tmp" && mv -f "$tmp" "$file"; }
  else
    printf '{"fetched":%s}\n' "$now" >"$tmp" && mv -f "$tmp" "$file"
  fi
  rm -f "$tmp" "$tmp.hist" 2>/dev/null
  return 0
}

# $1 repo (owner/name) $2 gh config dir (optional)
hud-issues-json() {
  local repo="${1:-}" ghdir="${2:-}"
  [[ "$repo" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$ ]] || { printf 'null'; return 0; }
  [ "${ghdir#\~/}" = "$ghdir" ] || ghdir="$HOME/${ghdir#\~/}"
  if [ -n "$ghdir" ] && { [[ "$ghdir" != /* ]] || [[ "$ghdir" == *$'\n'* ]] || [ ! -d "$ghdir" ]; }; then ghdir=""; fi
  local ttl="${HUD_ISSUES_TTL:-900}" dir file now fetched=0 cached=""
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=900
  dir=$(_hi-dir); file="$dir/$(printf '%s' "$repo" | cksum | cut -d' ' -f1).json"; now=$(_hi-now)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  fi
  if [ $((now - fetched)) -ge "$ttl" ] && command -v gh >/dev/null 2>&1 && mkdir -p "$dir" 2>/dev/null; then
    local lock="$file.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${HUD_ISSUES_SYNC:-}" = 1 ]; then
        hi-refresh "$file" "$repo" "$ghdir"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( hi-refresh "$file" "$repo" "$ghdir"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi
  local counts="" open hwm
  [ -z "$cached" ] || counts=$(jq -c 'select((.open | type) == "number" and (.undelivered | type) == "number" and .open >= 0 and .undelivered >= 0 and .undelivered <= .open) | {open: (.open | floor), undelivered: (.undelivered | floor)}' <<<"$cached" 2>/dev/null | head -n1) || counts=""
  [ -n "$counts" ] || { printf 'null'; return 0; }
  open=$(jq -r '.open' <<<"$counts")
  sl-hwm-sample "issues:$repo" "$open"
  hwm=$(sl-hwm-windows "$(_hi-key "$repo")" "$open")
  if [ -n "$hwm" ]; then jq -c --argjson h "$hwm" '. + {hwm: $h}' <<<"$counts" 2>/dev/null || printf '%s' "$counts"; else printf '%s' "$counts"; fi
}
