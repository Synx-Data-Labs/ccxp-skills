#!/usr/bin/env bash
# Shared bash data layer for the ccxp-hud mod (sourced by hud-data.sh): the task
# claimed by THIS clone, branch, autopilot state, job ledger and last-input time.
# It was the statusLine command's library; the statusLine itself (the
# statusline-setup skill) is retired in favour of the ccxp-hud band.
#
# Repo root, TODO dir, and clone-id are all derived from the SESSION cwd, so the
# same data works across every clone/session regardless of which folder Claude
# was launched in.
#
# The clone-id is NOT reimplemented here. It used to be (`$(hostname):$root`),
# coupled to task_claim.sh by nothing but a comment, which meant a format change
# there left this silently matching nothing — and `sl-claimed-task-label` prints
# nothing on a miss, so a stale copy renders exactly like "no task claimed"
# (T20260911-698434). It now sources the single definition instead.
#
# _session/_lib.sh is deliberately NOT sourced: it runs `set -uo pipefail` and
# loads ~/.claude/.env at source time, and this runs on every HUD poll.
# claimant-id.sh is side-effect-free for exactly this caller.

# Last-user-input timestamp dir: last-input-hook.sh's UserPromptSubmit hook
# touches <dir>/<session_id> on every prompt, and only that file's mtime is
# read (sl-last-input-epoch, for the hud `lastat` field). The files hold no
# prompt text. Mirrors claimant-id.sh's CLAIMANT_STATE_DIR override
# convention so BATS can isolate reads under $BATS_TEST_TMPDIR.
LAST_INPUT_STATE_DIR="${LAST_INPUT_STATE_DIR:-${HOME}/.claude/state/last-input}"

_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _sl_cand in "$_SL_DIR/../../_session/claimant-id.sh" \
                "$HOME/.claude/skills/_session/claimant-id.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_sl_cand" ] && { . "$_sl_cand"; break; }
done
unset _sl_cand

# Resolve the repo root from a session cwd (fall back to cwd if not a git repo).
sl-repo-root() {
  local cwd="$1"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd"
}

sl-clone-id() {
  # Must equal `_tc_claimant_id` for this clone or the HUD silently shows no
  # task; tests/hud_lib.bats pins that equality directly.
  local repo_root="$1"
  if declare -F claimant_id >/dev/null 2>&1; then
    claimant_id "$repo_root"
  else
    # Lib not found (unusual install layout). Emit nothing rather than a
    # wrong-format guess: a guess would match no task anyway, and this must
    # never fail.
    printf ''
  fi
}

# Current git branch for repo_root, or empty (detached HEAD / not a repo).
# symbolic-ref (not `branch --show-current`) so this also works pre-first-commit,
# when HEAD is an unborn symbolic ref with no commit behind it yet.
sl-branch-name() {
  local repo_root="$1"
  git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true
}

# --- Repo identity for the HUD `repo` cell (repo_slug, head, dirty, gh_account) -------------
# All of it is derived from the SESSION cwd the mod passes in, never from this
# process's inherited environment (the launch directory's direnv env is stale
# after `/cd`). No network. Read-only, except the tiny per-root gh-account
# cache below.

# Run "$@" with a wall-clock limit of $1 seconds; non-zero when it timed out.
# macOS ships no `timeout`, so fall back to a background watchdog.
sl-run-timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return; fi
  local pid watcher rc=0
  "$@" & pid=$!
  # The watchdog must not hold the caller's stdout open (a $(...) would wait for it).
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  return "$rc"
}

# Short commit id when HEAD is detached, else nothing.
sl-detached-head() {
  local repo_root="$1"
  git -C "$repo_root" symbolic-ref -q HEAD >/dev/null 2>&1 && return 0
  git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || true
}

# owner/name from remote.origin.url (https, ssh, scp-style and ssh-alias hosts
# all end in owner/name[.git]); with no remote, the basename of the main
# worktree (so a linked worktree still names its repo, not its own folder).
sl-repo-slug() {
  local repo_root="$1" url name rest owner common
  url=$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null) || url=""
  url="${url%/}"; url="${url%.git}"
  if [ -n "$url" ]; then
    name="${url##*[/:]}"
    rest="${url%"$name"}"; rest="${rest%[/:]}"
    owner="${rest##*[/:]}"
    case "$owner" in ''|*@*) owner="" ;; esac
    if [ -n "$name" ]; then
      if [ -n "$owner" ]; then printf '%s/%s' "$owner" "$name"; else printf '%s' "$name"; fi
      return 0
    fi
  fi
  common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  case "$common" in
    */.git) basename "$(dirname "$common")" ;;
    *) basename "$repo_root" ;;
  esac
}

# Count of changed TRACKED files (capped at 99); nothing when git is slow or
# fails (the HUD then shows no marker). Untracked files are not scanned (slow
# on big trees) and optional locks are off so this never writes to the repo.
sl-dirty-count() {
  local repo_root="$1" out
  out=$(GIT_OPTIONAL_LOCKS=0 sl-run-timeout 2 git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null) || return 0
  if [ -z "$out" ]; then printf '0'; return 0; fi
  out=$(printf '%s\n' "$out" | grep -c .) || out=0
  [ "$out" -gt 99 ] && out=99
  printf '%s' "$out"
}

# GH_CONFIG_DIR a shell started in $1 would have, from .envrc files only:
# direnv loads the NEAREST .envrc, which may chain to a parent with source_up.
# Understands `export GH_CONFIG_DIR=<path>` with ~, $HOME, ${HOME} and quotes;
# anything else (other variables, command substitution) is treated as unknown.
sl-gh-config-dir-from-envrc() {
  local dir="$1" f line val
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    f="$dir/.envrc"
    if [ -r "$f" ]; then
      line=$(grep -E '^[[:space:]]*(export[[:space:]]+)?GH_CONFIG_DIR=' "$f" 2>/dev/null | tail -n 1) || line=""
      if [ -n "$line" ]; then
        val="${line#*GH_CONFIG_DIR=}"
        val="${val%%[[:space:]]#*}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        val="${val//\$\{HOME\}/$HOME}"; val="${val//\$HOME/$HOME}"
        if [ "${val:0:1}" = "~" ] && { [ "${#val}" -eq 1 ] || [ "${val:1:1}" = "/" ]; }; then val="$HOME${val:1}"; fi
        case "$val" in *'$'*|*'`'*|'') return 0 ;; esac
        printf '%s' "$val"
        return 0
      fi
      grep -qE '^[[:space:]]*source_up(_if_exists)?([[:space:]]|$)' "$f" 2>/dev/null || return 0
    fi
    dir=$(dirname "$dir")
  done
}

# gh's own config dir for a shell in $1: direnv's answer when direnv is
# installed and allows the .envrc, else the .envrc parse, else empty.
sl-gh-config-dir() {
  local root="$1" d=""
  if command -v direnv >/dev/null 2>&1; then
    # The launch directory's value must not leak into the answer.
    d=$( (unset GH_CONFIG_DIR; cd "$root" 2>/dev/null && sl-run-timeout 2 direnv exec "$root" printenv GH_CONFIG_DIR) 2>/dev/null ) || d=""
  fi
  [ -n "$d" ] || d=$(sl-gh-config-dir-from-envrc "$root")
  printf '%s' "$d"
}

# Account name (the `user:` line only; never the token) from <dir>/hosts.yml,
# preferring the github.com host.
sl-gh-hosts-user() {
  local f="$1/hosts.yml" u
  [ -r "$f" ] || return 0
  u=$(awk '/^github\.com:/ {g=1; next} /^[^[:space:]#]/ {g=0} g && $1=="user:" {print $2; exit}' "$f" 2>/dev/null)
  [ -n "$u" ] || u=$(awk '$1=="user:" {print $2; exit}' "$f" 2>/dev/null)
  u="${u%\"}"; u="${u#\"}"; u="${u%\'}"; u="${u#\'}"
  printf '%s' "$u"
}

# gh account for a shell in repo_root $1, cached per root for
# CCXP_HUD_CACHE_TTL seconds (default 60; 0 disables) so the 15 s poll stays
# cheap. Cache: $CCXP_HUD_CACHE_DIR (default ${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-cache), one
# tiny file per root; failures to write are ignored.
sl-gh-account() {
  local root="$1" ttl="${CCXP_HUD_CACHE_TTL:-60}" cdir="${CCXP_HUD_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/state/hud-cache}"
  local key f now stamp croot cacct dir acct
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=60
  now=$(date +%s)
  key=$(printf '%s' "$root" | cksum | awk '{print $1}')
  f="$cdir/gh-account-$key"
  if [ "$ttl" -gt 0 ] && [ -r "$f" ]; then
    IFS=$'\t' read -r stamp croot cacct < "$f" || true
    if [[ "$stamp" =~ ^[0-9]+$ ]] && [ "$croot" = "$root" ] && [ $(( now - stamp )) -lt "$ttl" ] && [ $(( now - stamp )) -ge 0 ]; then
      printf '%s' "$cacct"
      return 0
    fi
  fi
  dir=$(sl-gh-config-dir "$root")
  [ -n "$dir" ] || dir="${XDG_CONFIG_HOME:-${HOME}/.config}/gh"
  acct=$(sl-gh-hosts-user "$dir")
  if [ "$ttl" -gt 0 ]; then
    { mkdir -p "$cdir" && printf '%s\t%s\t%s\n' "$now" "$root" "$acct" > "$f.$$" && mv "$f.$$" "$f"; } 2>/dev/null || rm -f "$f.$$" 2>/dev/null || true
  fi
  printf '%s' "$acct"
}

# Find the task file whose frontmatter `claimed_by:` matches this clone-id and
# print "<task-id>: <title>" (or just "<task-id>" if no title), else nothing.
sl-claimed-task-label() {
  local todo_dir="$1" clone_id="$2"
  [ -d "$todo_dir" ] || return 0

  # Escape regex-special chars in the id (realistically just '.') and anchor
  # the tail so a longer sibling path can't match as a prefix.
  local esc_id="${clone_id//\\/\\\\}"
  esc_id="${esc_id//./\\.}"
  local claimed_file
  claimed_file=$(grep -rlE "^claimed_by:[[:space:]]+${esc_id}([[:space:]]|$)" "$todo_dir" 2>/dev/null | head -1)
  [ -n "$claimed_file" ] || return 0

  # Task ID from the filename (e.g. T20260427-242654).
  local task_id task_title
  task_id=$(basename "$claimed_file" .md | grep -oE 'T[0-9]+-[0-9]+')
  # Title from the first "# T<id>: Title" / "# T<id> Title" heading — strip the
  # leading "# T<id>" + optional ": "/" " so we don't double the ID below.
  task_title=$(grep -m1 '^# T' "$claimed_file" 2>/dev/null | sed -E 's/^# T[0-9]+-[0-9]+:? +//; s/^# //')

  if [ -n "$task_id" ] && [ -n "$task_title" ]; then
    printf '%s: %s' "$task_id" "$task_title"
  elif [ -n "$task_id" ]; then
    printf '%s' "$task_id"
  fi
}

# $1 ISO-8601 UTC -> epoch seconds, or empty. GNU date then BSD date — same
# two-line fallback shape as ccxp/scripts/epic-status.sh's _epic_iso_to_epoch.
# Empty input -> empty: GNU `date -d ""` means "today 00:00", which would turn a
# missing timestamp into a time-of-day-dependent bogus epoch.
sl-iso-to-epoch() {
  local iso="$1" e
  [ -n "$iso" ] || { printf ''; return 0; }
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  printf ''
}

# $1 repo_root -> one record (fields joined by the ASCII unit separator, 0x1f,
# so an empty field survives `read`):
#   <status> <prefix> <elapsed_hr> <requested_hr> <stuck> <cycle> <last_outcome>
#   <last_task_id> <stuck_reason> <stop_reason> <merged_count> <next_wake_epoch>
#   <busy> <current_task>
# (next_wake_epoch: next_wake_at as epoch seconds, empty when absent or unparseable;
# busy: 1 while a cycle is marked running (busy_since set and under 3 h old, else
# empty); current_task: the task id that cycle drives, only when busy, else empty)
# when /autopilot's dev/.autopilot-state.json (schema 2) has status "on" or
# "paused", else nothing (off, a legacy pre-redesign file, missing or malformed:
# the band then shows AP off). prefix: [p] paused (clock frozen at paused_at),
# [b] on but backing off (last_outcome == "stuck"), [i] on and idle or capped
# (last_outcome idle|capped), [r] on and working. requested_hr is always 0
# (there is no duration any more) and stop_reason is empty; both keep the
# record shape stable for hud-data.sh. Never fails the prompt: any
# missing/malformed field degrades to printing nothing (same convention as every
# other sl- helper). The ONE place the state file is parsed; hud-data.sh (--json)
# renders from this record.
sl-autopilot-fields() {
  local repo_root="$1" state_file line
  state_file="$repo_root/dev/.autopilot-state.json"
  [ -f "$state_file" ] || return 0

  # One jq call for all fields (not several separate ones) — avoids a TOCTOU
  # gap where /autopilot could rewrite the file between separate reads.
  line=$(jq -r 'select(.schema == 2) | [.status, .started_at, .stuck_count, .cycle_count, .last_outcome, .paused_at, (.last_task | if type == "object" then .id else . end), .last_stuck_reason, .merged_count, .next_wake_at, .busy_since, .current_task] | map(. // "" | tostring) | join("\u001f")' \
    "$state_file" 2>/dev/null) || return 0
  [ -n "$line" ] || return 0

  local ap_status started_at stuck_count cycle_count last_outcome paused_at last_task stuck_reason merged_count next_wake_at busy_since current_task
  IFS=$'\x1f' read -r ap_status started_at stuck_count cycle_count last_outcome paused_at last_task stuck_reason merged_count next_wake_at busy_since current_task <<<"$line"
  case "$ap_status" in on|paused) ;; *) return 0 ;; esac

  # stuck_count/cycle_count must be non-negative integers — a missing,
  # negative, or non-numeric value degrades to nothing rather than a
  # garbled segment.
  [[ "$stuck_count" =~ ^[0-9]+$ ]] || return 0
  [[ "$cycle_count" =~ ^[0-9]+$ ]] || return 0
  [[ "$merged_count" =~ ^[0-9]+$ ]] || merged_count=0

  local started_epoch now_epoch
  started_epoch=$(sl-iso-to-epoch "$started_at")
  [ -n "$started_epoch" ] || return 0
  now_epoch=$(date +%s)
  [ "$started_epoch" -le "$now_epoch" ] || return 0

  local prefix elapsed_secs
  if [ "$ap_status" = "paused" ]; then
    # Pausing stops the clock: elapsed is frozen at paused_at, not live.
    local paused_epoch
    paused_epoch=$(sl-iso-to-epoch "$paused_at")
    [ -n "$paused_epoch" ] && [ "$paused_epoch" -ge "$started_epoch" ] || return 0
    prefix='[p]'
    elapsed_secs=$(( paused_epoch - started_epoch ))
  else
    case "$last_outcome" in
      stuck) prefix='[b]' ;;
      idle|capped) prefix='[i]' ;;
      *) prefix='[r]' ;;
    esac
    elapsed_secs=$(( now_epoch - started_epoch ))
  fi

  local elapsed_hr sep=$'\x1f'
  elapsed_hr=$(awk -v s="$elapsed_secs" 'BEGIN{printf "%.0f", s/3600}')

  local next_wake_epoch=""
  [ -z "$next_wake_at" ] || next_wake_epoch=$(sl-iso-to-epoch "$next_wake_at")

  # A busy mark older than 3 h is a crashed cycle (same rule as autopilot-state.sh): not busy.
  local busy="" busy_epoch
  if [ -n "$busy_since" ]; then
    busy_epoch=$(sl-iso-to-epoch "$busy_since")
    if [ -n "$busy_epoch" ] && [ "$busy_epoch" -le "$now_epoch" ] && [ $(( now_epoch - busy_epoch )) -lt 10800 ]; then busy=1; fi
  fi
  [[ "$current_task" =~ ^T[0-9]{8}-[0-9]{6}$ ]] && [ -n "$busy" ] || current_task=""

  printf '%s' "${ap_status}${sep}${prefix}${sep}${elapsed_hr}${sep}0${sep}${stuck_count}${sep}${cycle_count}${sep}${last_outcome}${sep}${last_task}${sep}${stuck_reason}${sep}${sep}${merged_count}${sep}${next_wake_epoch}${sep}${busy}${sep}${current_task}"
}

# $1 repo_root -> compact JSON of the autopilot's rolling-24h and lifetime progress
# {has_history, approx, merged_24h, cycles_24h, avg_merged_24h, trend (up|down|flat)}, or
# nothing when there is nothing to show (no counters and no history) or anything
# fails. The math lives in `autopilot-state.sh stats` (one jq pass, no network,
# read-only); this only points it at the repo's files. Never fails the prompt.
sl-autopilot-stats() {
  local repo_root="$1" script="$_SL_DIR/../../autopilot/scripts/autopilot-state.sh" out
  [ -f "$script" ] || return 0
  out=$(AUTOPILOT_STATE_FILE="$repo_root/dev/.autopilot-state.json" AUTOPILOT_HISTORY_FILE="$repo_root/dev/.autopilot-history.jsonl" \
    bash "$script" stats --json 2>/dev/null) || return 0
  printf '%s' "$out" | jq -c 'select(type == "object" and (.has_history or ((.lifetime_cycles // 0) > 0)))
    | {has_history, approx, merged_24h, cycles_24h, avg_merged_24h, trend}' 2>/dev/null || true
}

# Job ledger (written by ledger.sh). Same default path convention as the other
# state files: CLAUDE_CONFIG_DIR, else ~/.claude. CCXP_LEDGER_FILE overrides.
sl-ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/ccxp-ledger.json}"
}

# -> one normalized compact JSON object, or nothing when the ledger is
# missing/unreadable/not an object (callers hide the section or show a dash).
sl-ledger-json() {
  local f; f=$(sl-ledger-file)
  [ -f "$f" ] || return 0
  jq -c 'select(type == "object") | {
      updated_at: (.updated_at | strings // ""),
      next_job: (.next_job | numbers // 0),
      lifetime_jobs: (.lifetime_jobs | numbers // 0),
      parked: [(if (.parked | type) == "array" then .parked else [(.parked_ids // [])[]] end)[]
               | (if type == "string" then {id: .} elif type == "object" then . else {} end)
               | select(.id | strings) | {id}],
      running: [(.running // [])[] | select(type == "object")
                | {job: (.job | numbers // 0), title: (.title | strings // ""), flags: (.flags | strings // "")}]}' "$f" 2>/dev/null || true
}

# Queue breakdown of <repo>/dev/TODO/queue.md -> one compact JSON object, or nothing
# when the repo has no queue (the HUD then shows no queue cell). Deterministic, no LLM,
# one awk over the queued task files plus one jq; read-only, never fails.
#   {"total","ready","blocked","decision","external","epic","claimed"}
# Every queued task line (`- [T<id>](file.md)...`, struck-through lines are not tasks)
# lands in EXACTLY ONE bucket, first match wins, so the buckets always sum to total:
#   epic      kind=epic in autopilot's needs_attention, or the title/status says umbrella,
#             epic or "tracking task|issue", or the frontmatter has a `children:` key.
#             (Plain members of a dev/EPICS epic are ordinary work and stay takeable.)
#   blocked   kind=blocked, or status `Blocked by T<id>` while that blocker is still in
#             dev/TODO/, or the status contains BLOCKED or SUPERVISED (case-sensitive,
#             so a resolved "Blocked by" is not blocked)
#   external  kind=external, or the status mentions upstream, HashData, Apache, customer
#             or external (waiting on an outside party)
#   decision  kind=decision, or the status says needs/owner decision, "needs a human",
#             "needs manual", sign-off; also an id in autopilot's skip_ids with no kind
#             and no hint (a skipped task needs a human look)
#   claimed   `claimed_by:` set to a clone other than this one / the autopilot clone
#   ready     everything else: what the autopilot can take
# autopilot state (dev/.autopilot-state.json) is read only while status is on|paused;
# its `needs_attention[].kind` wins over the frontmatter hints. A queue line whose task
# file is missing has no hints and counts as ready.
sl-queue-json() {
  local repo_root="$1" todo q
  todo="$repo_root/dev/TODO"; q="$todo/queue.md"
  [ -f "$q" ] || return 0
  local rows="" files=() id file base
  while IFS='|' read -r id file; do
    [ -n "$id" ] || continue
    base="${file##*/}"
    rows+="$id"$'\n'
    [ -f "$todo/$base" ] && files+=("$todo/$base")
  done < <(grep -E '^- \[T[0-9]+-[0-9]+\]\(' "$q" 2>/dev/null | sed -E 's/^- \[(T[0-9]+-[0-9]+)\]\(([^)]*)\).*/\1|\2/')
  local info=""
  if [ "${#files[@]}" -gt 0 ]; then
    info=$(awk '
      function flush() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\n", id, status, claimed, title, kids; id = "" }
      FNR == 1 { flush(); n = 0; status = claimed = title = ""; kids = 0
        id = FILENAME; sub(/^.*\//, "", id); if (match(id, /^T[0-9]+-[0-9]+/)) id = substr(id, RSTART, RLENGTH); else id = "" }
      /\r$/ { sub(/\r$/, "") }
      $0 == "---" && n < 2 { n++; next }
      n == 1 && /^status:/ { v = $0; sub(/^status:[ \t]*/, "", v); gsub(/\t/, " ", v); status = v; next }
      n == 1 && /^claimed_by:/ { v = $0; sub(/^claimed_by:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v); if (v ~ /^(null|~|"")$/) v = ""; claimed = v; next }
      n == 1 && /^children:/ { kids = 1; next }
      n >= 2 && title == "" && /^# / { title = $0; gsub(/\t/, " ", title) }
      END { flush() }' "${files[@]}" 2>/dev/null) || info=""
  fi
  local open_ids; open_ids=$(ls "$todo" 2>/dev/null | grep -oE '^T[0-9]+-[0-9]+' || true)
  local state='{"skip":[],"att":{},"clone":""}' sf="$repo_root/dev/.autopilot-state.json" st
  if [ -f "$sf" ]; then
    st=$(jq -c 'select(.schema == 2 and (.status == "on" or .status == "paused")) | {
        skip: [(.skip_ids // [])[] | strings],
        att: ([(.needs_attention // [])[] | select(type == "object" and (.id | type) == "string") | {key: .id, value: ((.kind // "") | strings)}] | from_entries),
        clone: ((.dispatch_clone_path // "") | strings)}' "$sf" 2>/dev/null) || st=""
    [ -z "$st" ] || state="$st"
  fi
  local me1 me2="" ap_clone
  me1=$(sl-clone-id "$repo_root")
  ap_clone=$(printf '%s' "$state" | jq -r '.clone' 2>/dev/null) || ap_clone=""
  [ -z "$ap_clone" ] || [ ! -d "$ap_clone" ] || me2=$(sl-clone-id "$ap_clone")
  jq -n -c --arg rows "$rows" --arg info "$info" --arg open "$open_ids" --argjson st "$state" --arg me1 "$me1" --arg me2 "$me2" '
    ($info | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {status: (.[1] // ""), claimed: (.[2] // ""), title: (.[3] // ""), kids: ((.[4] // "0") == "1")}}) | from_entries) as $meta
    | ($open | split("\n") | map(select(. != ""))) as $openIds
    | ($rows | split("\n") | map(select(. != ""))) as $ids
    | [$ids[] | . as $id | ($meta[$id] // {status: "", claimed: "", title: "", kids: false}) as $m
        | ($st.att[$id] // "") as $kind
        | ($m.status) as $s
        | (if $kind == "epic" or $m.kids or ($m.title + " " + $s | test("umbrella|\\bepic\\b|tracking (task|issue)"; "i")) then "epic"
           elif $kind == "blocked" or ($s | test("\\b(BLOCKED|SUPERVISED)\\b")) or ([$s | scan("(?i:blocked by) (T[0-9]+-[0-9]+)") | .[0]] | any(. as $b | $openIds | index($b) != null)) then "blocked"
           elif $kind == "external" or ($s | test("upstream|HashData|Apache|customer|external"; "i")) then "external"
           elif $kind == "decision" or ($s | test("needs? (a )?(owner |user |your )?decision|owner decision|needs a human|needs manual|sign-off"; "i")) then "decision"
           elif $m.claimed != "" and $m.claimed != $me1 and $m.claimed != $me2 then "claimed"
           elif ($st.skip | index($id)) != null then "decision"
           else "ready" end)] as $b
    | {total: ($ids | length)} + (["ready", "blocked", "decision", "external", "epic", "claimed"] | map({key: ., value: (. as $k | $b | map(select(. == $k)) | length)}) | from_entries)' 2>/dev/null || true
}

# $1 last-input state dir, $2 session_id -> epoch seconds of the last prompt
# this session submitted (the cache file's mtime, written by the
# UserPromptSubmit hook), or nothing. A session_id with a path separator (or
# exactly "." / "..") is rejected, mirroring last-input-hook.sh's
# li-safe-session-id, so a payload can never make this read outside the dir.
sl-last-input-epoch() {
  local dir="$1" session_id="$2" file mtime
  [ -n "$session_id" ] || return 0
  case "$session_id" in
    */*|.|..) return 0 ;;
  esac
  file="$dir/$session_id"
  [ -r "$file" ] || return 0
  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || return 0
  [[ "$mtime" =~ ^[0-9]+$ ]] && printf '%s' "$mtime"
  return 0
}
