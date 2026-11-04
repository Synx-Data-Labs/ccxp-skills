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
# `stats` ({approx, avg_approx, jobs_24h, avg_jobs_day, trend}: jobs started in the rolling last 24 h vs the
# lifetime average per day) comes from `ledger.sh stats --json` (read-only, from the start log ledger.sh writes);
# absent when the ledger has never counted a job or the call fails.
sl-ledger-json() {
  local f stats script="$_SL_DIR/ledger.sh"; f=$(sl-ledger-file)
  [ -f "$f" ] || return 0
  stats=""
  [ -f "$script" ] && stats=$(CCXP_LEDGER_FILE="$f" bash "$script" stats --json 2>/dev/null | jq -c '{approx, avg_approx, jobs_24h, avg_jobs_day, trend}' 2>/dev/null) || stats=""
  jq -c --argjson st "${stats:-null}" 'select(type == "object") | {
      updated_at: (.updated_at | strings // ""),
      next_job: (.next_job | numbers // 0),
      lifetime_jobs: (.lifetime_jobs | numbers // 0),
      parked: [(if (.parked | type) == "array" then .parked else [(.parked_ids // [])[]] end)[]
               | (if type == "string" then {id: .} elif type == "object" then . else {} end)
               | select(.id | strings) | {id}],
      running: [(.running // [])[] | select(type == "object")
                | {job: (.job | numbers // 0), title: (.title | strings // ""), flags: (.flags | strings // "")}]}
    + (if $st then {stats: $st} else {} end)' "$f" 2>/dev/null || true
}

# --- Queue source: the repo's default branch instead of this clone's working tree (T20261104-420419) ---
# `queue.source = "default-branch"` reads dev/TODO and dev/EPICS from origin/<default> with git object
# reads only (no checkout, nothing written in the working tree), so a clone that is far behind origin
# still shows what origin has. The fetch that keeps origin/<default> fresh is cached, detached and rate
# limited, like the CI and version lookups. Test hooks: HUD_QUEUE_STATE_DIR (stamp dir),
# HUD_QUEUE_FETCH_SYNC=1 (fetch in the foreground), HUD_QUEUE_FETCH_TTL (seconds between fetches).
HUD_QUEUE_FETCH_TTL="${HUD_QUEUE_FETCH_TTL:-120}"
HUD_QUEUE_FETCH_TIMEOUT=15
HUD_QUEUE_BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$'

# $1 repo root -> the default branch name (from refs/remotes/origin/HEAD, else origin/main, else
# origin/master when that remote-tracking ref exists), or nothing. No network, no gh.
sl-default-branch() {
  local root="$1" ref b=""
  if ref=$(git -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$ref" ]; then
    # origin/HEAD is authoritative: an unusable name or a missing target means "unknown" (marked
    # working-tree fallback), never a guess at main/master.
    b="${ref#refs/remotes/origin/}"
    [[ "$b" =~ $HUD_QUEUE_BRANCH_RE ]] && git -C "$root" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null 2>&1 && printf '%s' "$b"
    return 0
  fi
  local cand
  for cand in main master; do
    if git -C "$root" rev-parse --verify -q "refs/remotes/origin/$cand" >/dev/null 2>&1; then printf '%s' "$cand"; return 0; fi
  done
  return 0
}

# $1 repo root $2 branch -> at most one detached `git fetch origin <branch>` per HUD_QUEUE_FETCH_TTL
# (stamped BEFORE the attempt, so an offline remote is not retried every poll). Never blocks, never
# prompts for credentials, silent on failure, no garbage collection, nothing in the working tree.
sl-queue-fetch() {
  local root="$1" branch="$2" dir stamp now last=0 key
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  dir="${HUD_QUEUE_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/hud-queue}"
  mkdir -p "$dir" 2>/dev/null || return 0
  key=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
  stamp="$dir/fetch-$key"
  now=$(date +%s)
  if [ -f "$stamp" ]; then
    last=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null) || last=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ "$last" -le "$now" ] || last=0 # a future stamp (clock skew) must not stop fetching
  fi
  [ $((now - last)) -ge "$HUD_QUEUE_FETCH_TTL" ] || return 0
  : > "$stamp" 2>/dev/null || return 0
  if [ "${HUD_QUEUE_FETCH_SYNC:-}" = 1 ]; then
    _sl-queue-fetch-run "$root" "$branch"
  else
    ( _sl-queue-fetch-run "$root" "$branch" ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  return 0
}

# git >= 2.29 can fetch without overwriting .git/FETCH_HEAD (so a user's `git fetch x; git merge FETCH_HEAD` is never disturbed).
_sl-git-has-no-fetch-head() {
  local v; v=$(git --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')
  set -- $v
  [ -n "${1:-}" ] && { [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "${2:-0}" -ge 29 ]; }; }
}

_sl-queue-fetch-run() {
  local nofh=()
  _sl-git-has-no-fetch-head && nofh=(--no-write-fetch-head)
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GCM_INTERACTIVE=never GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand 2>/dev/null || echo ssh)} -o BatchMode=yes -o ConnectTimeout=5" \
    sl-run-timeout "$HUD_QUEUE_FETCH_TIMEOUT" git -C "$1" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags --no-recurse-submodules "${nofh[@]}" origin "$2" >/dev/null 2>&1 || true
}

# $1 repo root $2 ref $3 empty dest dir -> dev/TODO and dev/EPICS of $2 extracted under $3 (object reads
# only: `git archive` of the commit; the working tree is never touched). Non-zero when dev/TODO is absent.
sl-queue-materialize() {
  local root="$1" ref="$2" dest="$3" paths=() p
  for p in dev/TODO dev/EPICS; do
    git -C "$root" cat-file -e "$ref:$p" 2>/dev/null && paths+=("$p")
  done
  [ "${#paths[@]}" -gt 0 ] || return 1
  # No lazy fetch from a promisor remote (partial clone) and no credential prompt: an unreadable blob means fallback.
  GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GCM_INTERACTIVE=never \
    git -C "$root" archive --format=tar "$ref" "${paths[@]}" 2>/dev/null | tar -x -C "$dest" 2>/dev/null
  local rcs=("${PIPESTATUS[@]}")
  [ "${rcs[0]}" -eq 0 ] && [ "${rcs[1]}" -eq 0 ]
}

# Queue breakdown of <repo>/dev/TODO/queue.md -> one compact JSON object, or nothing
# when the repo has no queue (the HUD then shows no queue cell). Deterministic, no LLM,
# one awk over the queued task files plus one jq; read-only, never fails.
#   {"total","ready","held","epic","claimed","revisited","autoparked"}
# Every queued task line (`- [T<id>](file.md)...`, struck-through lines are not tasks)
# lands in EXACTLY ONE of ready|held|epic|claimed, first match wins, so those four always
# sum to total; revisited and autoparked are extra counts from the autopilot state file:
#   epic      the frontmatter has a `children:` key, or the task is the parent of a dev/EPICS/E*.md epic (that file has a
#             `Parent design task:` / `Parent:` line naming it), or a deliberate uppercase
#             marker: the title starts with `EPIC` / contains `— EPIC`, or the status has the
#             standalone word EPIC. Free-text "umbrella"/"epic" is NOT a signal (product
#             terms and prose misfire). Plain members of a dev/EPICS epic stay takeable.
#   held      a status the HUD counts as not takeable: `Blocked by T<id>` while that blocker
#             is still in dev/TODO/, or BLOCKED / SUPERVISED (case-sensitive, so a resolved
#             "Blocked by" is not held), or "needs manual" / sign-off (case-insensitive). This
#             is the HUD's stricter display rule: auto-pick (`todo-gated`) is a little wider
#             (case-insensitive words, any `Blocked by`), so `ready` can include a task
#             auto-pick skips. Nothing is derived from any marker text (T20261102-296642).
#   claimed   `claimed_by:` set to a clone other than this one / the autopilot clone
#   ready     everything else: what the autopilot can take
#   revisited tasks still queued that the autopilot visited without progress (the state file's
#             `visits` entries above 0); autoparked = tasks the autopilot parked since this
#             run started (`parked` entries at or after `run_started_at`, else `started_at`)
# autopilot state (dev/.autopilot-state.json) is read only while status is on|paused, for its
# dispatch clone path (so the clone's own claims count as this clone's) and the two counts above.
# A queue line whose task file is missing has no hints and counts as ready.
sl-queue-json() {
  local repo_root="$1" want_src="${2:-working-tree}" src_root todo q
  local extra='{}' tmp=""
  src_root="$repo_root"
  if [ "$want_src" = default-branch ]; then
    # Never fatal: when origin/<default> cannot be read, fall back to the working tree and say so.
    local br; br=$(sl-default-branch "$repo_root")
    extra='{"source":"working-tree","fallback":true}'
    if [ -n "$br" ]; then
      sl-queue-fetch "$repo_root" "$br"
      if git -C "$repo_root" rev-parse --verify -q "refs/remotes/origin/$br^{commit}" >/dev/null 2>&1; then
        # A helper killed mid-archive (the mod's 5 s limit) cannot clean up: sweep our own stale temp dirs first.
        find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'hud-queue.??????' -mmin +10 -exec rm -rf {} + 2>/dev/null || true
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/hud-queue.XXXXXX" 2>/dev/null) || tmp=""
        if [ -n "$tmp" ] && sl-queue-materialize "$repo_root" "refs/remotes/origin/$br" "$tmp"; then
          src_root="$tmp"
          extra=$(jq -n -c --arg b "$br" '{source: "default-branch", branch: $b}')
        fi
      fi
    fi
  fi
  _sl-queue-json "$repo_root" "$src_root" "$extra"
  local rc=$?
  [ -z "$tmp" ] || rm -rf "$tmp" 2>/dev/null || true
  return $rc
}

# $1 repo root (clone identity, autopilot state) $2 root holding dev/TODO and dev/EPICS to read $3 extra JSON to merge in
_sl-queue-json() {
  local repo_root="$1" src_root="$2" extra="$3" todo q
  todo="$src_root/dev/TODO"; q="$todo/queue.md"
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
  local parents; parents=$(cat "$src_root"/dev/EPICS/E*.md 2>/dev/null \
    | grep -iE '^[*_ ]*parent( design task)?[*_ ]*:' | sed -E 's/^[^T]*(T[0-9]+-[0-9]+).*/\1/' | grep -E '^T[0-9]+-[0-9]+$' || true)
  local open_ids; open_ids=$(ls "$todo" 2>/dev/null | grep -oE '^T[0-9]+-[0-9]+' || true)
  local state='{"clone":""}' sf="$repo_root/dev/.autopilot-state.json" st
  if [ -f "$sf" ]; then
    st=$(jq -c 'select(.schema == 2 and (.status == "on" or .status == "paused")) | (((.run_started_at | strings) // (.started_at | strings)) // "") as $s0 | {
        clone: ((.dispatch_clone_path // "") | strings),
        visits: ((.visits | objects // {}) | with_entries(select(.value | type == "number" and . > 0)) | keys),
        parked: [(.parked | arrays // [])[] | select(type == "object" and (((.at // "") | strings) >= $s0)) | .id | strings]}' "$sf" 2>/dev/null) || st=""
    [ -z "$st" ] || state="$st"
  fi
  local me1 me2="" ap_clone
  me1=$(sl-clone-id "$repo_root")
  ap_clone=$(printf '%s' "$state" | jq -r '.clone' 2>/dev/null) || ap_clone=""
  [ -z "$ap_clone" ] || [ ! -d "$ap_clone" ] || me2=$(sl-clone-id "$ap_clone")
  jq -n -c --arg rows "$rows" --arg info "$info" --arg open "$open_ids" --arg parents "$parents" --argjson st "$state" --arg me1 "$me1" --arg me2 "$me2" --argjson extra "$extra" '
    ($info | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: {status: (.[1] // ""), claimed: (.[2] // ""), title: (.[3] // ""), kids: ((.[4] // "0") == "1")}}) | from_entries) as $meta
    | ($open | split("\n") | map(select(. != ""))) as $openIds
    | ($parents | split("\n") | map(select(. != ""))) as $epicParents
    | ($rows | split("\n") | map(select(. != ""))) as $ids
    | [$ids[] | . as $id | ($meta[$id] // {status: "", claimed: "", title: "", kids: false}) as $m
        | ($m.status) as $s
        | (if $m.kids or ($epicParents | index($id)) != null or ($m.title | test("^# T[0-9]+-[0-9]+: EPIC\\b|— EPIC\\b")) or ($s | test("\\bEPIC\\b")) then "epic"
           elif ($s | test("\\b(BLOCKED|SUPERVISED)\\b")) or ([$s | scan("(?i:blocked by) (T[0-9]+-[0-9]+)") | .[0]] | any(. as $b | $openIds | index($b) != null)) or ($s | test("needs manual|sign-off"; "i")) then "held"
           elif $m.claimed != "" and $m.claimed != $me1 and $m.claimed != $me2 then "claimed"
           else "ready" end)] as $b
    | {total: ($ids | length)} + (["ready", "held", "epic", "claimed"] | map({key: ., value: (. as $k | $b | map(select(. == $k)) | length)}) | from_entries)
      + {revisited: ([($st.visits // [])[] | select(. as $v | $ids | index($v) != null)] | length), autoparked: (($st.parked // []) | unique | length)} + $extra' 2>/dev/null || true
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
