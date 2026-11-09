#!/usr/bin/env bash
# ritual-due.sh [--repo DIR] [list | claim | done <ritual> <key> | release <ritual> <key>]
#
# Token-free, network-free "what is due" check for the ccxp-agent persona (T20261107-228304).
# Rituals: standup (every day), ipm (Mon-Fri, once per ISO week), retro (Fri-Sun, once per week).
# Day boundaries and weekdays use CCXP_RITUAL_TZ (default America/Chicago).
#
#   list      (default) read-only: print each due ritual as "<ritual> <key>", highest priority first.
#   claim     print the single highest-priority due ritual (one line, "<ritual> <key>") after taking
#             its claim atomically; prints nothing when nothing is due or another session won the race.
#             Writes only its own marker file, and only when it prints a line.
#   done      mark a claimed ritual finished (the dispatched job runs this last, on success).
#   release   drop a claim without marking done (job failed; the next check may retry it).
#
# Markers live in ${CCXP_RITUAL_DIR:-<profile dir>/ccxp-rituals}/<repo-key>/ (profile dir: _session/profile-dir.sh):
#   <ritual>-<key>.claim.<n>  generation n+1 is created O_EXCL (set -C): exactly one session wins a
#                             generation; content = "<epoch> [via]", or "released" after `release`
#   <ritual>-<key>.done       created by `done`
# A claim with no .done older than CCXP_RITUAL_TTL seconds (default 21600 = 6 h) counts as abandoned
# (the job died): the next check supersedes it with a new generation. A Friday `standup` claim also claims `retro`
# (same key), because the standup job runs /ccxp, whose Phase 2b is the retro; `done`/`release` of that standup
# follow it, and only it. `done` and `release` require the key `claim` printed. Known limit: a job running longer
# than the TTL whose claim was superseded can still `release` and drop the newer claim.
#
# Scope: only a git repo with a dev/TODO directory (silent no-op elsewhere). Off switch: CCXP_RITUALS=0
# or a file named `off` in the marker base dir (the ccxp-rituals dir itself, above the per-repo dirs). Test hooks: CCXP_RITUAL_NOW (epoch seconds).
set -euo pipefail

# Active profile dir (CCXP_PROFILE_DIR), see _session/profile-dir.sh.
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"

RITUALS=(standup ipm retro)

# days since 1970-01-01 for a civil date (proleptic Gregorian), pure arithmetic: no date(1) portability issues
function rd-days-from-civil() {
  local y=$1 m=$((10#$2)) d=$((10#$3))
  if ((m <= 2)); then y=$((y - 1)); fi
  local era=$(((y >= 0 ? y : y - 399) / 400))
  local yoe=$((y - era * 400))
  local mp=$(((m + 9) % 12))
  local doy=$(((153 * mp + 2) / 5 + d - 1))
  local doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

# "YYYY-MM-DD" for days since 1970-01-01
function rd-civil-from-days() {
  local z=$(($1 + 719468))
  local era=$(((z >= 0 ? z : z - 146096) / 146097))
  local doe=$((z - era * 146097))
  local yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
  local y=$((yoe + era * 400))
  local doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
  local mp=$(((5 * doy + 2) / 153))
  local d=$((doy - (153 * mp + 2) / 5 + 1))
  local m=$((mp < 10 ? mp + 3 : mp - 9))
  if ((m <= 2)); then y=$((y + 1)); fi
  printf '%04d-%02d-%02d' "$y" "$m" "$d"
}

function rd-now() { echo "${CCXP_RITUAL_NOW:-$(date +%s)}"; }

# local calendar date "YYYY-MM-DD" of an epoch in the ritual timezone (GNU date -d, else BSD date -r)
function rd-local-date() {
  local epoch=$1 tz="${CCXP_RITUAL_TZ:-America/Chicago}"
  TZ="$tz" date -d "@$epoch" +%Y-%m-%d 2>/dev/null || TZ="$tz" date -r "$epoch" +%Y-%m-%d
}

# prints "<today-days> <weekday 1=Mon..7=Sun>"
function rd-today() {
  local ymd y m d days
  ymd="$(rd-local-date "$(rd-now)")"
  IFS=- read -r y m d <<<"$ymd"
  days="$(rd-days-from-civil "$y" "$m" "$d")"
  echo "$days $(((days + 3) % 7 + 1))"
}

# the key (a date) a ritual uses today, or nothing when it is not in its window
function rd-key() {
  local ritual=$1 days dow
  read -r days dow < <(rd-today)
  case "$ritual" in
    standup) rd-civil-from-days "$days" ;;
    ipm) ((dow <= 5)) && rd-civil-from-days $((days - (dow - 1))) || true ;;
    retro) ((dow >= 5)) && rd-civil-from-days $((days - (dow - 5))) || true ;;
    *) return 2 ;;
  esac
}

function rd-repo-root() {
  local dir="${1:-.}" top
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -d "$top/dev/TODO" ] || return 1
  echo "$top"
}

# empty when the profile dir is unknown: the check then skips (never guesses a location)
function rd-base() { echo "${CCXP_RITUAL_DIR:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-rituals}}"; }

# marker dir for the repo: <name>-<hash of the origin URL> (same across worktrees), else of the toplevel path
function rd-marker-dir() {
  local top=$1 id
  id="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
  [ -n "$id" ] || id="$top"
  # a hash, never the URL itself: a remote may embed credentials, and sanitized URLs can collide
  local h name
  h="$( (printf '%s' "$id" | sha256sum || printf '%s' "$id" | shasum -a 256 || printf '%s' "$id" | cksum) 2>/dev/null | cut -c1-16)"
  name="$(basename "${id%.git}")"
  echo "$(rd-base)/${name//[^A-Za-z0-9._-]/_}-${h//[^A-Za-z0-9]/_}"
}

# newest generation number n of <ritual>-<key>.claim.<n> (0 when none)
function rd-gen() {
  local dir=$1 ritual=$2 key=$3 f n max=0
  for f in "$dir/$ritual-$key.claim."*; do
    [ -e "$f" ] || continue
    n="${f##*.}"
    [[ "$n" =~ ^[0-9]+$ ]] && ((n > max)) && max=$n
  done
  echo "$max"
}

# state of one ritual: done | busy | due
function rd-state() {
  local dir=$1 ritual=$2 key=$3 gen claim ts now ttl
  now="$(rd-now)"
  ttl="${CCXP_RITUAL_TTL:-21600}"
  [ -e "$dir/$ritual-$key.done" ] && { echo "done"; return; }
  gen="$(rd-gen "$dir" "$ritual" "$key")"
  ((gen > 0)) || { echo due; return; }
  claim="$dir/$ritual-$key.claim.$gen"
  ts="$(cat "$claim" 2>/dev/null || true)"
  [ "${ts%% *}" = released ] && { echo due; return; }
  ts="${ts%% *}"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    ((now - ts > ttl)) && echo due || echo busy
  else
    # empty file: another session is mid-write; abandoned only once the file itself is older than the TTL
    [ -n "$(find "$claim" -mmin "+$((ttl / 60))" 2>/dev/null)" ] && echo due || echo busy
  fi
}

# Take the claim: create generation n+1 with O_EXCL (set -C). Of any number of sessions that saw
# generation n, exactly one creates n+1; nothing is renamed or removed, so a stale claim is superseded safely.
function rd-take() {
  local dir=$1 ritual=$2 key=$3 gen=$4 via="${5:-}"
  mkdir -p "$dir"
  (
    set -C
    printf '%s %s\n' "$(rd-now)" "$via" >"$dir/$ritual-$key.claim.$((gen + 1))"
  ) 2>/dev/null
}

function rd-list() {
  local dir=$1 r key
  for r in "${RITUALS[@]}"; do
    key="$(rd-key "$r")" || continue
    [ -n "$key" ] || continue
    [ "$(rd-state "$dir" "$r" "$key")" = due ] && echo "$r $key"
  done
  return 0
}

function rd-claim() {
  local dir=$1 r key gen rkey rgen
  for r in "${RITUALS[@]}"; do
    key="$(rd-key "$r")" || continue
    [ -n "$key" ] || continue
    gen="$(rd-gen "$dir" "$r" "$key")"   # read BEFORE the state: a claim taken since makes our take fail
    [ "$(rd-state "$dir" "$r" "$key")" = due ] || continue
    rd-take "$dir" "$r" "$key" "$gen" || continue
    if [ "$r" = standup ]; then
      # the standup job is /ccxp, whose Phase 2b is the Friday retro: on a Friday claim it too
      rkey="$(rd-key retro)" || rkey=""
      if [ "$rkey" = "$key" ]; then
        rgen="$(rd-gen "$dir" retro "$rkey")"
        if [ "$(rd-state "$dir" retro "$rkey")" = due ]; then rd-take "$dir" retro "$rkey" "$rgen" "standup:$key" || true; fi
      fi
    fi
    echo "$r $key"
    return 0
  done
  return 0
}

# true when the newest retro-<key> claim was taken by the standup of that same key (a Friday standup)
function rd-companion() {
  local dir=$1 key=$2 gen
  gen="$(rd-gen "$dir" retro "$key")"
  ((gen > 0)) || return 1
  grep -q " standup:$key\$" "$dir/retro-$key.claim.$gen" 2>/dev/null
}

function rd-finish() {
  local dir=$1 verb=$2 ritual=${3:-} key=${4:-}
  case " ${RITUALS[*]} " in *" $ritual "*) ;; *) echo "ritual-due: unknown ritual '$ritual'" >&2; return 2 ;; esac
  # the key is mandatory: a job that crossed midnight must not finish the next day's ritual
  [[ "$key" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ritual-due: $verb needs the <key> that claim printed (got '$key')" >&2; return 2; }
  if [ "$ritual" = standup ] && rd-companion "$dir" "$key"; then
    rd-finish-one "$dir" "$verb" retro "$key"
  fi
  rd-finish-one "$dir" "$verb" "$ritual" "$key"
}

# done: touch <ritual>-<key>.done. release: a newer generation marked "released" (the ritual is due again)
function rd-finish-one() {
  local dir=$1 verb=$2 ritual=$3 key=$4 gen
  mkdir -p "$dir"
  if [ "$verb" = "done" ]; then
    : >"$dir/$ritual-$key.done"
  else
    gen="$(rd-gen "$dir" "$ritual" "$key")"
    ((gen > 0)) || return 0
    ( set -C; echo released >"$dir/$ritual-$key.claim.$((gen + 1))" ) 2>/dev/null || true
  fi
}

function ritual-due() {
  local repo="" verb
  if [ "${1:-}" = --repo ]; then repo="${2:?--repo needs a directory}"; shift 2; fi
  verb="${1:-list}"
  [ $# -eq 0 ] || shift
  [ "${CCXP_RITUALS:-1}" = 0 ] && return 0
  [ -n "$(rd-base)" ] || return 0
  [ -e "$(rd-base)/off" ] && return 0
  local top dir
  top="$(rd-repo-root "${repo:-.}")" || return 0
  dir="$(rd-marker-dir "$top")"
  case "$verb" in
    list) rd-list "$dir" ;;
    claim) rd-claim "$dir" ;;
    done | release) rd-finish "$dir" "$verb" "$@" ;;
    *) echo "usage: ritual-due.sh [--repo DIR] [list|claim|done <ritual> <key>|release <ritual> <key>]" >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ritual-due "$@"
fi
