#!/usr/bin/env bash
# Nightly green/red day counts for the ccxp-hud band (hud-data.sh sources this).
#
# hud-nightly-json  prints {"red":N,"green":M,"strip":"++-++-+"} or "null" (an older cache without "green" prints without it).
#
# Source: `gh run list` for the SynxDB nightly orchestrator workflow ("Nightly Orchestrator" in
# Synx-Data-Labs/synxdb-build-pipeline), scheduled runs only. Counted per UTC day over the last 30 days
# (today and the 29 days before it):
#   green day = at least one completed run, every one of them concluded success;
#   red day   = at least one run that day concluded failure or timed_out, even if a later run succeeded.
# Cancelled, skipped and still-running runs are ignored; a day with no counted run is neither.
# Output: `red` / `green` = red / green days in the last 30 days (today and the 29 before); `strip` = the last 7 days, oldest to
# newest, one character each: + green day, - red day, . no counted run. Nothing when no day in the 30 counts.
#
# Never blocks the caller: it prints the cached answer at once and, when the cache is older than
# HUD_NIGHTLY_TTL (default 1800 s), starts ONE detached refresh (10 s timeout, lock dir). gh missing,
# signed out, offline or no access keep the old answer / print "null"; gh's output is never passed on.
# gh JSON is untrusted: only two counts and an enumerated state survive the jq mapping.
#
# Overrides (also test hooks): HUD_NIGHTLY_REPO, HUD_NIGHTLY_WORKFLOW, HUD_NIGHTLY_TTL,
# HUD_NIGHTLY_OFF=1 (no lookup, "null"), HUD_NIGHTLY_SYNC=1 (refresh in the foreground),
# HUD_NIGHTLY_STATE_DIR (default ${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-nightly), HUD_NIGHTLY_NOW (fake epoch).

_HN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-ci.sh
. "$_HN_DIR/hud-ci.sh" # hci-run-timeout

HNI_REPO_DEFAULT="Synx-Data-Labs/synxdb-build-pipeline"
HNI_WORKFLOW_DEFAULT="Nightly Orchestrator"
HNI_TIMEOUT=10

hni-state-dir() { printf '%s' "${HUD_NIGHTLY_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/hud-nightly}"; }

# $1 now (epoch), stdin: JSON list of runs (gh run list --json status,conclusion,event,createdAt)
# -> {"red":N,"green":M,"strip":"++-++-+"}; nothing when no day of the 30 counts. Pure: no clock, no network.
sl-nightly-count() {
  jq -c --argjson now "$1" '
    ($now - 29 * 86400 | strftime("%Y-%m-%d")) as $from
    | [ .[]? | select(type == "object")
        | select(.status == "completed" and .event == "schedule" and (.conclusion | IN("success", "failure", "timed_out")))
        | ((.createdAt | tostring | fromdateiso8601?) // null) as $t
        | select($t != null and $t <= $now)
        | {t: $t, d: ($t | strftime("%Y-%m-%d")), red: (.conclusion != "success")}
        | select(.d >= $from) ] as $runs
    | ($runs | group_by(.d) | map({key: .[0].d, value: any(.[]; .red)}) | from_entries) as $days
    | if ($days | length) == 0 then empty else
        {red: ($days | map(select(.)) | length),
         green: ($days | map(select(. | not)) | length),
         strip: ([range(6; -1; -1) | ($now - . * 86400 | strftime("%Y-%m-%d")) as $d | if $days[$d] == null then "." elif $days[$d] then "-" else "+" end] | join(""))}
      end' 2>/dev/null
}

# $1 cache file
hni-refresh() {
  local file="$1" tmp now out=""
  now="${HUD_NIGHTLY_NOW:-$(date +%s)}"
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if hci-run-timeout "$HNI_TIMEOUT" gh run list --repo "${HUD_NIGHTLY_REPO:-$HNI_REPO_DEFAULT}" --workflow "${HUD_NIGHTLY_WORKFLOW:-$HNI_WORKFLOW_DEFAULT}" --event schedule --limit 100 --json status,conclusion,event,createdAt >"$tmp" 2>/dev/null; then
    out=$(sl-nightly-count "$now" <"$tmp") || out=""
    # An empty window (valid answer, nothing counted) is cached as such so the cell hides without re-asking.
    [ -n "$out" ] || { jq -e 'type == "array"' "$tmp" >/dev/null 2>&1 && out="{}"; } || out=""
  fi
  if [ -n "$out" ]; then
    jq -c --argjson now "$now" '. + {fetched: $now}' <<<"$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
  elif [ -r "$file" ]; then
    # Failed: keep the previous answer, only move the fetch time (so a failure is not retried every poll).
    { jq -c --argjson now "$now" '.fetched = $now' "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"; } \
      || { printf '{"fetched":%s}\n' "$now" >"$tmp" && mv -f "$tmp" "$file"; } # unreadable cache: start over, still not retried every poll
  else
    printf '{"fetched":%s}\n' "$now" >"$tmp" && mv -f "$tmp" "$file"
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

hud-nightly-json() {
  [ "${HUD_NIGHTLY_OFF:-}" != 1 ] || { printf 'null'; return 0; }
  local ttl="${HUD_NIGHTLY_TTL:-1800}" dir file now fetched=0 cached=""
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=1800
  dir=$(hni-state-dir)
  file="$dir/$(printf '%s|%s' "${HUD_NIGHTLY_REPO:-$HNI_REPO_DEFAULT}" "${HUD_NIGHTLY_WORKFLOW:-$HNI_WORKFLOW_DEFAULT}" | cksum | cut -d' ' -f1).json"
  now="${HUD_NIGHTLY_NOW:-$(date +%s)}"
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  fi
  if [ $((now - fetched)) -ge "$ttl" ] && command -v gh >/dev/null 2>&1 && mkdir -p "$dir" 2>/dev/null; then
    local lock="$file.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${HUD_NIGHTLY_SYNC:-}" = 1 ]; then
        hni-refresh "$file"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( hni-refresh "$file"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi
  local out=""
  [ -z "$cached" ] || out=$(jq -c 'select((.red | type) == "number" and (.strip | type) == "string" and (.strip | test("^[-+.]{7}$"))) | {red: (.red | floor)} + (if (.green | type) == "number" and .green >= 0 then {green: (.green | floor)} else {} end) + {strip}' <<<"$cached" 2>/dev/null | head -n1) || out=""
  printf '%s' "${out:-null}"
}
