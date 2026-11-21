#!/usr/bin/env bash
# Unhandled red-CI count for the ccxp-hud band (hud-data.sh sources this).
#
# hud-redci-json <repos_json_array> <poll_seconds> [todo_dir]
#   prints {"n":N,"items":[{"wf","at","repo","id","ev","br","url"}...]} (newest first, at most 3 items) or "null".
# hud-redci-list <repos_json> [poll] [todo_dir]   one tab-separated line per unhandled item (id, workflow, event, branch, age, url).
# CLI: `bash hud-redci.sh list [owner/name ...]` prints that list for the given repos (default: the HUD config's redci/ci repos).
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
# Cost: per repo one `gh run list --status <s>` for each of failure, timed_out and startup_failure (gh treats them
# as separate statuses) per refresh, plus (only when something failed) one `gh repo view` and, per distinct failing (workflow, branch) pair (at most HRC_MAX_PAIRS = 20), one `gh run list --workflow <id> --branch <b> --status success --limit 1`
# (a repo-wide success window loses the successes of workflows that ran long ago on a busy repo, so superseded failures stayed counted). Refreshes are at most every HRC_MIN_TTL (300 s,
# or the poll when longer), detached, 5 s timeout per call, lock dir per repo. The HUD never calls gh
# per redraw: it prints the cache at once.
#
# gh JSON is untrusted: only numbers, an enumerated repo name and a printable, truncated workflow name
# survive the jq mapping. Arguments go to gh as an argv array, never through a shell string. gh missing,
# signed out or offline keeps the old answer, but never longer than 6 hours (then the repo counts as unknown). Nothing from gh's stdout or stderr is passed on.
#
# Test hooks: CCXP_HUD_REDCI_SYNC=1 refreshes in the foreground; HUD_REDCI_STATE_DIR relocates the cache
# (default <profile>/state/hud-redci); HUD_REDCI_CONTEXT_DIR / HUD_REDCI_LEDGER_FILE relocate the handled sources.

# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
HRC_MIN_TTL=300
HRC_TIMEOUT=5
HRC_MAX_AGE_SEC=604800
HRC_MAX_REPOS=8
HRC_MAX_STALE=21600
HRC_MAX_PAIRS=20
HRC_URL_BASE="https://github.com"

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
  local file="$1" repo="$2" todo="$3" tmp fails succ branch now state="" handled cand one
  now=$(date +%s)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  fails="$tmp.f"; succ="$tmp.s"; handled="$tmp.h"; cand="$tmp.c"; one="$tmp.o"
  local st ok=1
  : >"$fails.all"
  for st in failure timed_out startup_failure; do
    if hrc-run-timeout "$HRC_TIMEOUT" gh run list --repo "$repo" --status "$st" --limit 30 --json databaseId,workflowDatabaseId,workflowName,event,headBranch,createdAt >"$fails.one" 2>/dev/null \
       && jq -e 'type == "array"' "$fails.one" >/dev/null 2>&1; then
      cat "$fails.one" >>"$fails.all"
    else
      ok=0; break
    fi
  done
  [ "$ok" = 1 ] && jq -s 'add' "$fails.all" >"$fails" 2>/dev/null || ok=0
  if [ "$ok" = 1 ] && jq -e 'type == "array"' "$fails" >/dev/null 2>&1; then
    if [ "$(jq 'length' "$fails" 2>/dev/null || echo 0)" = 0 ]; then
      state=$(jq -nc --argjson now "$now" '{items: [], fetched: $now, attempted: $now}')
    else
      branch=""
      hrc-run-timeout "$HRC_TIMEOUT" gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name >"$tmp" 2>/dev/null || true
      branch=$(head -n1 "$tmp" 2>/dev/null | head -c 200)
      [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$ ]] || branch=""
      hrc-handled-ids "$todo" >"$handled"
      # Candidates: failed runs inside the window that are on the default branch or scheduled and not handled.
      jq -c --argjson now "$now" --argjson maxage "$HRC_MAX_AGE_SEC" --arg branch "$branch" --rawfile handled "$handled" '
        def ts: (. // "") | tostring | fromdateiso8601? // 0;
        ($handled | split("\n") | map(select(. != ""))) as $h
        | [.[] | select(type == "object")
            | {id: ((.databaseId // 0) | tostring), wid: ((.workflowDatabaseId // 0) | tostring),
               wf: ((.workflowName // "") | tostring | gsub("[^ -~]"; "") | .[0:40]),
               br: ((.headBranch // "") | tostring | gsub("[^A-Za-z0-9._/-]"; "") | .[0:100]),
               ev: ((.event // "") | tostring | gsub("[^a-z_]"; "") | .[0:30]), at: (.createdAt | ts)}
            | select(.at > 0 and ($now - .at) <= $maxage)
            | select($branch != "" and .br == $branch or .ev == "schedule")
            | select(.wf != "")
            | select((.id | IN($h[])) | not)]' "$fails" >"$cand" 2>/dev/null || echo '[]' >"$cand"
      # Superseded: ask once per distinct (workflow, branch) for its newest success. Never a repo-wide window:
      # a busy repo pushes an older workflow's success out of any newest-N listing.
      : >"$succ"
      local wid wf br n=0 wsel
      while IFS=$'\t' read -r wid wf br; do
        [ -n "$br" ] || continue
        n=$((n + 1)); [ "$n" -le "$HRC_MAX_PAIRS" ] || break
        wsel="$wid"; { [ "$wid" != 0 ] && [[ "$wid" =~ ^[0-9]+$ ]]; } || wsel="$wf"
        if hrc-run-timeout "$HRC_TIMEOUT" gh run list --repo "$repo" --workflow "$wsel" --branch "$br" --status success --limit 1 --json createdAt >"$one" 2>/dev/null \
           && jq -e 'type == "array"' "$one" >/dev/null 2>&1; then
          jq -c --arg wf "$wf" --arg br "$br" '.[] | select(type == "object") | {k: ($wf + "|" + $br), at: ((.createdAt // "") | tostring | fromdateiso8601? // 0)}' "$one" >>"$succ" 2>/dev/null || true
        fi
      done < <(jq -r '[.[] | [.wid, .wf, .br]] | unique | .[] | @tsv' "$cand" 2>/dev/null)
      state=$(jq -c --argjson now "$now" --arg repo "${repo#*/}" --arg base "$HRC_URL_BASE/$repo/actions/runs" --slurpfile ok "$succ" '
        [.[] | . as $r | select(([$ok[] | select(.k == ($r.wf + "|" + $r.br) and .at > $r.at)] | length) == 0)]
        | sort_by(-.at) as $items
        | {items: ($items | map({wf, at, repo: $repo, id, ev, br, url: ($base + "/" + .id)})), fetched: $now, attempted: $now}' "$cand" 2>/dev/null) || state=""
    fi
  fi
  if [ -z "$state" ]; then
    # The data time (`fetched`) stays; only the attempt time moves, so a long outage cannot make old reds look fresh.
    state=$(jq -c --argjson now "$now" '.attempted = $now' "$file" 2>/dev/null) || state=""
    [ -n "$state" ] || state="{\"items\":null,\"fetched\":0,\"attempted\":$now}"
  fi
  printf '%s\n' "$state" >"$tmp" && mv -f "$tmp" "$file"
  rm -f "$tmp" "$fails" "$fails.all" "$fails.one" "$succ" "$handled" "$cand" "$one" 2>/dev/null
  return 0
}

# Every unhandled item of all watched repos (newest first) as a JSON array, or "null" when no repo has an answer.
hrc-all() {
  local repos_json="$1" poll="${2:-0}" todo="${3:-}" repo
  local -a repos=()
  while IFS= read -r repo; do
    hrc-valid-repo "$repo" && repos+=("$repo")
  done < <(jq -r 'if type == "array" then .[] | strings else empty end' <<<"${repos_json:-null}" 2>/dev/null | head -n "$HRC_MAX_REPOS")
  [ "${#repos[@]}" -gt 0 ] || { printf 'null'; return 0; }
  [[ "$poll" =~ ^[0-9]+$ ]] || poll=0
  local ttl=$HRC_MIN_TTL
  [ "$poll" -le "$ttl" ] || ttl=$poll

  local dir now key file fetched data_at cached lock all='[]' answered=0
  dir=$(hrc-state-dir)
  now=$(date +%s)
  for repo in "${repos[@]}"; do
    key=$(printf '%s' "$repo" | cksum | cut -d' ' -f1)
    file="$dir/$key.json"
    fetched=0; cached=""; data_at=0
    if [ -r "$file" ]; then
      cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      data_at=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || data_at=0
      fetched=$(jq -r '((.attempted // .fetched // 0) | floor)' <<<"${cached:-null}" 2>/dev/null) || fetched=0
      [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
      [[ "$data_at" =~ ^[0-9]+$ ]] || data_at=0
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
    part=$(jq -c 'if (.items | type) == "array" then [.items[] | select(type == "object" and (.wf | type) == "string" and (.at | type) == "number" and (.repo | type) == "string") | {wf: (.wf | .[0:40]), at: (.at | floor), repo: (.repo | .[0:100]), id: ((.id // "") | tostring | select(test("^[0-9]{1,20}$")) // ""), ev: ((.ev // "") | tostring | gsub("[^a-z_]"; "") | .[0:30]), br: ((.br // "") | tostring | gsub("[^A-Za-z0-9._/-]"; "") | .[0:100]), url: ((.url // "") | tostring | select(test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$")) // "")}] else null end' <<<"${cached:-null}" 2>/dev/null) || part=""
    # Data older than HRC_MAX_STALE (refreshes keep failing) counts as no answer for this repo.
    data_at=$(jq -r '(.fetched // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || data_at=0
    [[ "$data_at" =~ ^[0-9]+$ ]] || data_at=0
    [ $((now - data_at)) -le "$HRC_MAX_STALE" ] || part=""
    if [ -n "$part" ] && [ "$part" != "null" ]; then
      answered=1
      all=$(jq -c --argjson p "$part" '. + $p' <<<"$all")
    fi
  done
  [ "$answered" = 1 ] || { printf 'null'; return 0; }
  jq -c 'sort_by(-.at)' <<<"$all" 2>/dev/null || printf 'null'
}

hud-redci-json() {
  local all
  all=$(hrc-all "$@") || all=null
  [ -n "$all" ] && [ "$all" != null ] || { printf 'null'; return 0; }
  jq -c '{n: length, items: .[0:3]}' <<<"$all" 2>/dev/null || printf 'null'
}

# hud-redci-list <repos_json> [poll] [todo_dir]: one line per unhandled item, newest first (tab separated):
# run id, workflow, event, branch, age, url. Same cache and refresh rules as the cell.
hud-redci-list() {
  local all now
  all=$(hrc-all "${1:-null}" "${2:-0}" "${3:-}") || all=null
  [ -n "$all" ] && [ "$all" != null ] || { printf 'no answer (no watched repo, or gh unavailable)\n'; return 0; }
  now=$(date +%s)
  [ "$(jq 'length' <<<"$all")" != 0 ] || { printf 'all clear: no unhandled red CI\n'; return 0; }
  jq -r --argjson now "$now" '.[] | [.id, .wf, .ev, .br, "\(((($now - .at) / 3600) | floor))h ago", .url] | @tsv' <<<"$all"
}

# Watched repos for the CLI: args, else the HUD config (project file, then user file): redci.repos, else ci.repo.
hrc-config-repos() {
  local f out
  for f in "${PWD}/.claude/ccxp-hud.json" "${CCXP_PROFILE_DIR:-}/ccxp-hud.json"; do
    [ -r "$f" ] || continue
    out=$(jq -c 'if has("redci") then (.redci | if type == "array" then . else .repos end) elif (.ci | type) == "object" and (.ci.repo | type) == "string" then [.ci.repo] else empty end' "$f" 2>/dev/null) || out=""
    [ -n "$out" ] && [ "$out" != null ] && { printf '%s' "$out"; return 0; }
  done
  printf '[]'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    list)
      shift
      if [ "$#" -gt 0 ]; then rj=$(printf '%s\n' "$@" | jq -R . | jq -sc .); else rj=$(hrc-config-repos); fi
      CCXP_HUD_REDCI_SYNC=1 hud-redci-list "$rj" 0 "$PWD/dev/TODO" ;;
    *) printf 'usage: hud-redci.sh list [owner/name ...]\n' >&2; exit 2 ;;
  esac
fi
