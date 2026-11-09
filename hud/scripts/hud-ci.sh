#!/usr/bin/env bash
# CI status data for the ccxp-hud band (hud-data.sh sources this).
#
# hud-ci-json <repo_root> <ci_config_json> <poll_seconds>
#   prints {"state":"passing|failing|running|unknown","at":<epoch>[,"eta":{...}]} or "null".
#
# The CI source is CONFIGURATION, never code: <ci_config_json> is the mod's `ci`
# block ({"workflow","branch"?,"repo"?}); null or invalid prints "null" and runs
# nothing. The last runs of that workflow come from ONE `gh run list ... --limit 20` call:
# the newest decides the state, the rest feed the ETA.
#
# ETA (on unless the ci block has "eta": false): only while the newest run is in_progress. History = the
# older runs that completed with success and have a positive startedAt..updatedAt span, newest first,
# capped at 7. Those with the same event (schedule vs workflow_dispatch ...) as the running run are
# used when there are >= 3 of them, else any event. Fewer than 3 usable runs: no "eta" key at all.
# Otherwise "eta": {"start": epoch the run started, "typ": median seconds, "min", "max", "n"}.
# Showing it (ETA HH:MM, ~ range, over usual) is the mod's job (hud/model.ts ciEta).
#
# Never blocks the caller: it prints the cached answer at once and, when the
# cache is older than the TTL (>= 120 s, and never more often than the poll), starts
# ONE detached refresh (5 s timeout, lock dir). gh missing, signed out, offline or the
# workflow absent keep the old answer / print "null"; nothing from gh's stdout or
# stderr is ever passed on. gh JSON is untrusted: only an enumerated state and an
# epoch number survive the jq mapping below. Arguments are passed to gh as an
# argv array, never through a shell string.
#
# Test hooks: CCXP_HUD_CI_SYNC=1 refreshes in the foreground; HUD_CI_STATE_DIR
# relocates the cache (default <profile>/state/hud-ci).


# Active profile dir (CCXP_PROFILE_DIR), see _session/profile-dir.sh.
# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
HCI_MIN_TTL=120
HCI_TIMEOUT=5

# $1 repo root -> the repo's name from origin's URL ("" when no origin). Local only.
sl-origin-name() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  printf '%s' "$url" | sed -E 's|/+$||; s|\.git$||; s|^.*[/:]||'
}

hci-state-dir() { printf '%s' "${HUD_CI_STATE_DIR:-${CCXP_PROFILE_DIR:-}/state/hud-ci}"; }

# Same shapes the mod's config.ts accepts; the helper re-validates (defence in depth).
hci-valid() { # $1 kind (workflow|branch|repo) $2 value
  case "$1" in
    workflow) [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$ ]] ;;
    branch) [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ ]] ;;
    repo) [[ "$2" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$ ]] ;;
    *) return 1 ;;
  esac
}

# $1 seconds, rest = command: runs it, kills it after $1 seconds; its exit code.
hci-run-timeout() {
  local secs="$1" pid watcher rc; shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}

# $1 cache file $2 workflow $3 branch ("" = default) $4 repo ("" = current)
hci-refresh() {
  local file="$1" wf="$2" branch="$3" repo="$4" tmp now state=""
  local -a repo_args=()
  [ -z "$repo" ] || repo_args=(--repo "$repo")
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if [ -z "$branch" ]; then
    hci-run-timeout "$HCI_TIMEOUT" gh repo view ${repo:+"$repo"} --json defaultBranchRef --jq .defaultBranchRef.name >"$tmp" 2>/dev/null || true
    branch=$(head -n1 "$tmp" 2>/dev/null | head -c 200)
    hci-valid branch "$branch" || branch=""
  fi
  if [ -n "$branch" ] && hci-run-timeout "$HCI_TIMEOUT" gh run list --workflow "$wf" --branch "$branch" "${repo_args[@]}" --limit 20 --json status,conclusion,createdAt,startedAt,updatedAt,event >"$tmp" 2>/dev/null; then
    state=$(jq -c --argjson now "$now" '
      def ts: (. // "") | tostring | fromdateiso8601? // 0;
      def median: sort | length as $n | if $n % 2 == 1 then .[($n - 1) / 2] else ((.[$n / 2 - 1] + .[$n / 2]) / 2 | floor) end;
      (.[0] // null) as $r
      | if ($r | type) != "object" then empty else
          ([.[1:][] | select(type == "object" and .status == "completed" and .conclusion == "success")
            | {event: (.event | tostring), d: ((.updatedAt | ts) - (.startedAt | ts))} | select(.d > 0)]) as $hist
          | ($hist | map(select(.event == ($r.event | tostring)))) as $same
          | (if ($same | length) >= 3 then $same else $hist end | .[:7] | map(.d)) as $ds
          | ($r.startedAt | ts) as $start
          | {state: (if $r.status != "completed" then "running"
                     elif $r.conclusion == "success" then "passing"
                     elif ($r.conclusion | IN("failure", "timed_out", "startup_failure")) then "failing"
                     else "unknown" end),
             at: (($r.createdAt | ts)), fetched: $now}
            + (if $r.status == "in_progress" and $start > 0 and ($ds | length) >= 3
               then {eta: {start: $start, typ: ($ds | median), min: ($ds | min), max: ($ds | max), n: ($ds | length)}} else {} end)
        end' "$tmp" 2>/dev/null) || state=""
  fi
  if [ -z "$state" ]; then
    # Failed or no run: keep the previous state, only move the fetch time. The ETA is not kept: it goes stale fast.
    state=$(jq -c --argjson now "$now" '.fetched = $now | del(.eta)' "$file" 2>/dev/null) || state=""
    [ -n "$state" ] || state="{\"state\":\"\",\"at\":0,\"fetched\":$now}"
  fi
  printf '%s\n' "$state" >"$tmp" && mv -f "$tmp" "$file"
  rm -f "$tmp" 2>/dev/null
  return 0
}

hud-ci-json() {
  local root="$1" cfg="$2" poll="${3:-0}" wf branch repo eta_on
  { [ -n "$cfg" ] && [ "$cfg" != "null" ]; } || { printf 'null'; return 0; }
  wf=$(jq -r 'if type == "object" and (.workflow | type) == "string" then .workflow else "" end' <<<"$cfg" 2>/dev/null) || wf=""
  branch=$(jq -r 'if type == "object" and (.branch | type) == "string" then .branch else "" end' <<<"$cfg" 2>/dev/null) || branch=""
  repo=$(jq -r 'if type == "object" and (.repo | type) == "string" then .repo else "" end' <<<"$cfg" 2>/dev/null) || repo=""
  eta_on=$(jq -r 'if type == "object" and .eta == false then "false" else "true" end' <<<"$cfg" 2>/dev/null) || eta_on=true
  hci-valid workflow "$wf" || { printf 'null'; return 0; }
  [ -z "$branch" ] || hci-valid branch "$branch" || { printf 'null'; return 0; }
  [ -z "$repo" ] || hci-valid repo "$repo" || { printf 'null'; return 0; }
  [[ "$poll" =~ ^[0-9]+$ ]] || poll=0
  local ttl=$HCI_MIN_TTL
  [ "$poll" -le "$ttl" ] || ttl=$poll

  local dir key file now fetched=0 cached=""
  dir=$(hci-state-dir)
  key=$(printf '%s|%s|%s|%s' "$root" "$wf" "$branch" "$repo" | cksum | cut -d' ' -f1)
  file="$dir/$key.json"
  now=$(date +%s)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  fi

  if [ $((now - fetched)) -ge "$ttl" ] && command -v gh >/dev/null 2>&1 && mkdir -p "$dir" 2>/dev/null; then
    local lock="$dir/$key.lock"
    # A lock older than a minute is a dead refresh (integer -mmin: BSD find rejects fractions).
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${CCXP_HUD_CI_SYNC:-}" = 1 ]; then
        hci-refresh "$file" "$wf" "$branch" "$repo"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( hci-refresh "$file" "$wf" "$branch" "$repo"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi

  local out=""
  # Untrusted cache: only numbers survive in "eta"; it is dropped when ci.eta is false.
  [ -z "$cached" ] || out=$(jq -c --argjson eta "$eta_on" '
      (.eta // null) as $e
      | {state, at: (.at // 0)}
        + (if $eta and ($e | type) == "object" and all($e.start, $e.typ, $e.min, $e.max, $e.n; type == "number")
           then {eta: {start: ($e.start | floor), typ: ($e.typ | floor), min: ($e.min | floor), max: ($e.max | floor), n: ($e.n | floor)}} else {} end)
      | select(.state | IN("passing", "failing", "running", "unknown"))' <<<"$cached" 2>/dev/null | head -n1) || out=""
  printf '%s' "${out:-null}"
}
