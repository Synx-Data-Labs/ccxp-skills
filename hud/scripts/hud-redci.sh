#!/usr/bin/env bash
# Unhandled red-CI count for the ccxp-hud band (hud-data.sh sources this).
#
# hud-redci-json <repos_json_array> <poll_seconds> [todo_dir]
#   prints {"n":N,"items":[{"wf","at","repo"}...]} (newest first, at most 3 items) or "null".
#
# Red is red: for every watched repo (an `owner/name` list from the HUD config, never guessed from the
# session repo) a run counts when it FAILED (failure, timed_out, startup_failure) on the repo's default
# branch or from a schedule, within the last 7 days, whatever the workflow (Upstream Sync and Tests too).
# It is dropped when
#   - superseded: a later successful run of the same workflow on the same branch exists, or
#   - handled: its run id appears in a ccxp-context file, the job ledger or a dev/TODO file
#     (local greps, no network; the dispatcher writes the id there when it takes the failure on).
# n = 0 prints {"n":0,"items":[]} (answered, all clear); no repos, bad input or no answer yet prints "null".
#
# Cost: per repo ONE `gh run list --status failure` per refresh, plus (only when something failed) one
# `gh repo view` and one `gh run list --status success`. Refreshes are at most every HRC_MIN_TTL (300 s,
# or the poll when longer), detached, 5 s timeout per call, lock dir per repo. The HUD never calls gh
# per redraw: it prints the cache at once.
#
# gh JSON is untrusted: only numbers, an enumerated repo name and a printable, truncated workflow name
# survive the jq mapping. Arguments go to gh as an argv array, never through a shell string. gh missing,
# signed out or offline keeps the old answer. Nothing from gh's stdout or stderr is passed on.
#
# Test hooks: CCXP_HUD_REDCI_SYNC=1 refreshes in the foreground; HUD_REDCI_STATE_DIR relocates the cache
# (default <profile>/state/hud-redci); HUD_REDCI_CONTEXT_DIR / HUD_REDCI_LEDGER_FILE relocate the handled sources.

# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
HRC_MIN_TTL=300
HRC_TIMEOUT=5
HRC_MAX_AGE_SEC=604800
HRC_MAX_REPOS=8

hrc-state-dir() { printf '%s' "${HUD_REDCI_STATE_DIR:-${CCXP_PROFILE_DIR:-}/state/hud-redci}"; }

hrc-valid-repo() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$ ]]; }

hrc-run-timeout() {
  local secs="$1" pid watcher rc; shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return "$rc"
}

# Prints every run-id-looking number (8+ digits) found in the handled sources, one per line.
# $1 = dev/TODO dir ("" = none)
hrc-handled-ids() {
  local ctx led
  ctx="${HUD_REDCI_CONTEXT_DIR:-${CCXP_PROFILE_DIR:-}/ccxp-context}"
  led="${HUD_REDCI_LEDGER_FILE:-${CCXP_LEDGER_FILE:-${CCXP_PROFILE_DIR:-}/ccxp-ledger.json}}"
  {
    [ -d "$ctx" ] && grep -rhoE '[0-9]{8,}' "$ctx" 2>/dev/null
    [ -r "$led" ] && grep -hoE '[0-9]{8,}' "$led" 2>/dev/null
    [ -n "$1" ] && [ -d "$1" ] && grep -rhoE '[0-9]{8,}' "$1" 2>/dev/null
  } | sort -u
  return 0
}

# $1 cache file $2 repo $3 todo dir
hrc-refresh() {
  local file="$1" repo="$2" todo="$3" tmp fails succ branch now state="" handled
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  fails="$tmp.f"; succ="$tmp.s"; handled="$tmp.h"
  if hrc-run-timeout "$HRC_TIMEOUT" gh run list --repo "$repo" --status failure --limit 30 --json databaseId,workflowName,event,headBranch,createdAt >"$fails" 2>/dev/null \
     && jq -e 'type == "array"' "$fails" >/dev/null 2>&1; then
    if [ "$(jq 'length' "$fails" 2>/dev/null || echo 0)" = 0 ]; then
      state=$(jq -nc --argjson now "$now" '{items: [], fetched: $now}')
    else
      branch=""
      hrc-run-timeout "$HRC_TIMEOUT" gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name >"$tmp" 2>/dev/null || true
      branch=$(head -n1 "$tmp" 2>/dev/null | head -c 200)
      [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ ]] || branch=""
      hrc-run-timeout "$HRC_TIMEOUT" gh run list --repo "$repo" --status success --limit 50 --json workflowName,headBranch,createdAt >"$succ" 2>/dev/null || echo '[]' >"$succ"
      jq -e 'type == "array"' "$succ" >/dev/null 2>&1 || echo '[]' >"$succ"
      hrc-handled-ids "$todo" >"$handled"
      state=$(jq -c --argjson now "$now" --argjson maxage "$HRC_MAX_AGE_SEC" --arg branch "$branch" --arg repo "${repo#*/}" \
        --slurpfile succ "$succ" --rawfile handled "$handled" '
        def ts: (. // "") | tostring | fromdateiso8601? // 0;
        ($handled | split("\n") | map(select(. != ""))) as $h
        | ($succ[0] | map(select(type == "object") | {k: ((.workflowName // "") + "|" + (.headBranch // "")), at: (.createdAt | ts)})) as $ok
        | [.[] | select(type == "object")
            | {id: ((.databaseId // 0) | tostring), wf: ((.workflowName // "") | tostring | gsub("[^ -~]"; "") | .[0:40]),
               br: ((.headBranch // "") | tostring), ev: ((.event // "") | tostring), at: (.createdAt | ts)}
            | select(.at > 0 and ($now - .at) <= $maxage)
            | select($branch != "" and .br == $branch or .ev == "schedule")
            | select(.wf != "")
            | select((.id | IN($h[])) | not)
            | . as $r | select(([$ok[] | select(.k == ($r.wf + "|" + $r.br) and .at > $r.at)] | length) == 0)]
        | sort_by(-.at) as $items
        | {items: ($items | map({wf, at, repo: $repo})), fetched: $now}' "$fails" 2>/dev/null) || state=""
    fi
  fi
  if [ -z "$state" ]; then
    state=$(jq -c --argjson now "$now" '.fetched = $now' "$file" 2>/dev/null) || state=""
    [ -n "$state" ] || state="{\"items\":null,\"fetched\":$now}"
  fi
  printf '%s\n' "$state" >"$tmp" && mv -f "$tmp" "$file"
  rm -f "$tmp" "$fails" "$succ" "$handled" 2>/dev/null
  return 0
}

hud-redci-json() {
  local repos_json="$1" poll="${2:-0}" todo="${3:-}" repo
  local -a repos=()
  while IFS= read -r repo; do
    hrc-valid-repo "$repo" && repos+=("$repo")
  done < <(jq -r 'if type == "array" then .[] | strings else empty end' <<<"${repos_json:-null}" 2>/dev/null | head -n "$HRC_MAX_REPOS")
  [ "${#repos[@]}" -gt 0 ] || { printf 'null'; return 0; }
  [[ "$poll" =~ ^[0-9]+$ ]] || poll=0
  local ttl=$HRC_MIN_TTL
  [ "$poll" -le "$ttl" ] || ttl=$poll

  local dir now key file fetched cached lock all='[]' answered=0
  dir=$(hrc-state-dir)
  now=$(date +%s)
  for repo in "${repos[@]}"; do
    key=$(printf '%s' "$repo" | cksum | cut -d' ' -f1)
    file="$dir/$key.json"
    fetched=0; cached=""
    if [ -r "$file" ]; then
      cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      fetched=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
      [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
    fi
    if [ $((now - fetched)) -ge "$ttl" ] && command -v gh >/dev/null 2>&1 && mkdir -p "$dir" 2>/dev/null; then
      lock="$dir/$key.lock"
      if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
      if mkdir "$lock" 2>/dev/null; then
        if [ "${CCXP_HUD_REDCI_SYNC:-}" = 1 ]; then
          hrc-refresh "$file" "$repo" "$todo"
          rmdir "$lock" 2>/dev/null || true
          cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
        else
          ( hrc-refresh "$file" "$repo" "$todo"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
          disown 2>/dev/null || true
        fi
      fi
    fi
    # Untrusted cache: only the known keys, typed, survive.
    local part
    part=$(jq -c 'if (.items | type) == "array" then [.items[] | select(type == "object" and (.wf | type) == "string" and (.at | type) == "number" and (.repo | type) == "string") | {wf: (.wf | .[0:40]), at: (.at | floor), repo: (.repo | .[0:100])}] else null end' <<<"${cached:-null}" 2>/dev/null) || part=""
    if [ -n "$part" ] && [ "$part" != "null" ]; then
      answered=1
      all=$(jq -c --argjson p "$part" '. + $p' <<<"$all")
    fi
  done
  [ "$answered" = 1 ] || { printf 'null'; return 0; }
  jq -c '{n: length, items: (sort_by(-.at) | .[0:3])}' <<<"$all" 2>/dev/null || printf 'null'
}
