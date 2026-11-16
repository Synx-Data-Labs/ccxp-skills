#!/usr/bin/env bash
# routine-due.sh [--repo DIR] [list | claim | done <routine> <key> | release <routine> <key> | show <routine> | check]
#
# Generic, config-driven generalization of ritual-due.sh (T20261114-144275). Token-free, network-free.
# Routines come from three merged layers (see routine-config.py and agent-pairing/rituals.md "Routines"):
#   1. built-in agent-pairing/routines.default.yml (standup, ipm, retro: identical to ritual-due.sh)
#   2. the tracked <repo>/dev/.routines.yml (or the profile's routines-file:)
#   3. the machine-local profile file ${CCXP_ROUTINES_PROFILE_FILE:-<profile dir>/ccxp-routines.yml}
#
#   list      read-only: "<routine> <key>" per due routine, declaration order ("<routine> every" for every: routines)
#   claim     print the highest-priority due at-routine after taking its claim (O_EXCL); every: routines are never claimed
#   done      finish a claimed routine (every: routine: rewrite its <routine>.last marker)
#   release   drop a claim without finishing (the routine is due again at the next check)
#   show      the merged definition of one routine
#   check     lint the merged config: "<file>[:<line>]: <message>" per problem, exit 1 when any
#
# Markers, TTL (CCXP_RITUAL_TTL), clock hook (CCXP_RITUAL_NOW), timezone (CCXP_RITUAL_TZ, routine tz: wins) and
# off switches (CCXP_RITUALS=0, `off` file) are those of ritual-due.sh, whose helpers this file sources.
# Scope repo routines need a git repo with dev/TODO; scope any routines keep markers under <base>/_any.
set -euo pipefail

_RT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ritual-due.sh
# shellcheck source-path=SCRIPTDIR
. "$_RT_DIR/ritual-due.sh"

# minutes since midnight in the given tz at the fake/real now
function rt-minutes() {
  local tz=$1 hm
  hm="$(TZ="$tz" date -d "@$(rd-now)" +%H:%M 2>/dev/null || TZ="$tz" date -r "$(rd-now)" +%H:%M)"
  echo $((10#${hm%%:*} * 60 + 10#${hm##*:}))
}

function rt-hm() { echo $((10#${1%%:*} * 60 + 10#${1##*:})); }

# the compiled-in built-ins (must equal the rows of routines.default.yml; a bats test guards the drift)
function rt-builtin-rows() {
  printf 'standup\tat\t-\t0\t1,2,3,4,5,6,7\tday\t-\t-\t-\trepo\tretro\nipm\tat\t-\t0\t1,2,3,4,5\tweek\t-\t-\t-\trepo\t-\nretro\tat\t-\t0\t5,6,7\tweek\t-\t-\t-\trepo\t-\n'
}

# Rows (TSV, "-" = empty) from the merged config; warnings go to stderr once per call.
function rt-config() {
  local mode=$1 repo_top=${2:-} profile tracked=""
  profile="${CCXP_ROUTINES_PROFILE_FILE:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-routines.yml}}"
  [ -n "$repo_top" ] && tracked="$repo_top/dev/.routines.yml"
  shift 2 || shift $#
  if ! python3 -I -c 'import yaml' 2>/dev/null && ! yq --version 2>&1 | grep -q mikefarah; then
    # no YAML reader: the compiled-in built-ins keep today's behavior (identical to ritual-due.sh)
    if [ "$mode" = rows ]; then
      echo "routine-due: warning: neither PyYAML nor yq found; using the built-in routines only" >&2
      rt-builtin-rows
      return 0
    fi
    echo "routine-due: neither PyYAML nor yq found; cannot read the routine config" >&2
    return 1
  fi
  python3 -I "$_RT_DIR/routine-config.py" --default "$_RT_DIR/../routines.default.yml" \
    ${tracked:+--tracked "$tracked"} ${profile:+--profile "$profile"} "$mode" "$@"
}

# the marker dir of a row's scope
function rt-dir() {
  local scope=$1 top=$2
  if [ "$scope" = any ]; then echo "$(rd-base)/_any"; else rd-marker-dir "$top"; fi
}

# key a routine uses now, or nothing when it is not in its window. Row fields are passed as arguments:
#   name at days once nb na tz
function rt-key() {
  local at=$1 days=$2 once=$3 nb=$4 na=$5 tz=$6 today dow first mins key
  [ "$tz" = - ] && tz="${CCXP_RITUAL_TZ:-America/Chicago}"
  read -r today dow < <(CCXP_RITUAL_TZ="$tz" rd-today)
  case ",$days," in *",$dow,"*) ;; *) return 0 ;; esac
  first="${days%%,*}"
  if [ "$once" = week ]; then key="$(rd-civil-from-days $((today - (dow - first))))"; else key="$(rd-civil-from-days "$today")"; fi
  mins="$(rt-minutes "$tz")"
  # `at` gates only the day the key names; later catch-up days of a week window are already past it
  if [ "$at" != - ] && [ "$key" = "$(rd-civil-from-days "$today")" ] && ((mins < $(rt-hm "$at"))); then return 0; fi
  if [ "$nb" != - ] && ((mins < $(rt-hm "$nb"))); then return 0; fi
  if [ "$na" != - ] && ((mins > $(rt-hm "$na"))); then return 0; fi
  echo "$key"
}

# due state of an every: routine: due | wait
function rt-every-state() {
  local dir=$1 name=$2 secs=$3 last
  last="$(cat "$dir/$name.last" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || { echo due; return; }
  (($(rd-now) - last >= secs)) && echo due || echo wait
}

# one row -> the key the routine would use now ("every" for every: routines), empty when not in its window
function rt-row-key() {
  local name kind at secs days once nb na tz scope also
  IFS=$'\t' read -r name kind at secs days once nb na tz scope also <<<"$1"
  if [ "$kind" = every ]; then
    # an every: routine still honors days and the not_before/not_after window; the key is the constant "every"
    [ -n "$(rt-key - "$days" day "$nb" "$na" "$tz")" ] && echo every || true
  else
    rt-key "$at" "$days" "$once" "$nb" "$na" "$tz"
  fi
}

function rt-list() {
  local top=$1 row name kind secs scope key dir
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r name kind _ secs _ _ _ _ _ scope _ <<<"$row"
    [ "$scope" = repo ] && [ -z "$top" ] && continue
    key="$(rt-row-key "$row")"
    [ -n "$key" ] || continue
    dir="$(rt-dir "$scope" "$top")"
    if [ "$kind" = every ]; then
      [ "$(rt-every-state "$dir" "$name" "$secs")" = due ] && echo "$name every"
    else
      [ "$(rd-state "$dir" "$name" "$key")" = due ] && echo "$name $key"
    fi
  done <<<"$2"
  return 0
}

# row of one routine name from the rows text
function rt-find() { awk -F'\t' -v n="$2" '$1==n' <<<"$1"; }

function rt-claim() {
  local top=$1 row name kind scope key dir gen also a arow akey agen
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r name kind _ _ _ _ _ _ _ scope also <<<"$row"
    [ "$kind" = every ] && continue
    [ "$scope" = repo ] && [ -z "$top" ] && continue
    key="$(rt-row-key "$row")"
    [ -n "$key" ] || continue
    dir="$(rt-dir "$scope" "$top")"
    gen="$(rd-gen "$dir" "$name" "$key")"   # read BEFORE the state: a claim taken since makes our take fail
    [ "$(rd-state "$dir" "$name" "$key")" = due ] || continue
    rd-take "$dir" "$name" "$key" "$gen" || continue
    if [ "$also" != - ]; then
      for a in ${also//,/ }; do   # names are validated ^[A-Za-z0-9_][A-Za-z0-9_.-]*$: no glob characters
        arow="$(rt-find "$2" "$a")"
        [ -n "$arow" ] || continue
        akey="$(rt-row-key "$arow")"
        if [ "$akey" = "$key" ] && [ "$(rd-state "$dir" "$a" "$key")" = due ]; then
          agen="$(rd-gen "$dir" "$a" "$key")"
          rd-take "$dir" "$a" "$key" "$agen" "$name:$key" || true
        fi
      done
    fi
    echo "$name $key"
    return 0
  done <<<"$2"
  return 0
}

# true when the newest <a>-<key> claim was taken by <name>'s own claim of that key
function rt-companion() {
  local dir=$1 a=$2 key=$3 name=$4 gen
  gen="$(rd-gen "$dir" "$a" "$key")"
  ((gen > 0)) || return 1
  grep -q " $name:$key\$" "$dir/$a-$key.claim.$gen" 2>/dev/null
}

function rt-finish() {
  local top=$1 rows=$2 verb=$3 name=${4:-} key=${5:-} row kind scope also dir a
  row="$(rt-find "$rows" "$name")"
  [ -n "$row" ] || { echo "routine-due: unknown or disabled routine '$name'" >&2; return 2; }
  IFS=$'\t' read -r _ kind _ _ _ _ _ _ _ scope also <<<"$row"
  if [ "$scope" = repo ] && [ -z "$top" ]; then return 0; fi
  dir="$(rt-dir "$scope" "$top")"
  mkdir -p "$dir"
  if [ "$kind" = every ]; then
    [ "$key" = every ] || { echo "routine-due: $verb of an every: routine needs the key 'every' (got '$key')" >&2; return 2; }
    [ "$verb" = "done" ] && rd-now >"$dir/$name.last"
    return 0
  fi
  # the key is mandatory: a job that crossed midnight must not finish the next day's routine
  [[ "$key" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "routine-due: $verb needs the <key> that claim printed (got '$key')" >&2; return 2; }
  if [ "$also" != - ]; then
    for a in ${also//,/ }; do
      if rt-companion "$dir" "$a" "$key" "$name"; then rd-finish-one "$dir" "$verb" "$a" "$key"; fi
    done
  fi
  rd-finish-one "$dir" "$verb" "$name" "$key"
}

function routine-due() {
  local repo="" verb top="" rows
  if [ "${1:-}" = --repo ]; then repo="${2:?--repo needs a directory}"; shift 2; fi
  verb="${1:-list}"
  [ $# -eq 0 ] || shift
  top="$(rd-repo-root "${repo:-.}")" || top=""
  # one clock reading per call, so the date and the time of day cannot straddle midnight
  CCXP_RITUAL_NOW="$(rd-now)"
  export CCXP_RITUAL_NOW
  case "$verb" in
    check) rt-config check "$top" ;;   # a lint is never silenced by the off switches
    show) rt-config show "$top" "${1:?show needs a routine name}" ;;
    list | claim | done | release)
      [ "${CCXP_RITUALS:-1}" = 0 ] && return 0
      [ -n "$(rd-base)" ] || return 0
      [ -e "$(rd-base)/off" ] && return 0
      rows="$(rt-config rows "$top")" || { echo "routine-due: warning: could not read the routine config; using the built-in routines" >&2; rows="$(rt-builtin-rows)"; }
      case "$verb" in
        list) rt-list "$top" "$rows" ;;
        claim) rt-claim "$top" "$rows" ;;
        *) rt-finish "$top" "$rows" "$verb" "$@" ;;
      esac ;;
    *) echo "usage: routine-due.sh [--repo DIR] [list|claim|done <routine> <key>|release <routine> <key>|show <routine>|check]" >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  routine-due "$@"
fi
