#!/usr/bin/env bash
# _date/date.sh — portable (GNU + BSD/macOS) date arithmetic. One place for the
# calendar maths that retro, ipm and ccxp each re-derived with GNU-only
# `date -d` (which fails on macOS) or BSD-only `date -v`.
#
# Everything works on YYYY-MM-DD strings via UTC epoch seconds, so there is no
# DST drift and no dependence on which `date` flavor is installed.
#
# Sourceable (functions prefixed d_) or run directly:
#   date.sh today                        today, YYYY-MM-DD  (override: TODAY=YYYY-MM-DD)
#   date.sh dow    [DATE]                ISO weekday 1=Mon .. 7=Sun
#   date.sh add    DATE N                DATE plus N days (N may be negative)
#   date.sh monday [DATE] [--next]       the Monday on or BEFORE DATE (week start);
#                                        with --next, the Monday on or AFTER DATE.
#                                        DATE defaults to today.
#   date.sh ago    N                     UTC timestamp N days before now,
#                                        YYYY-MM-DDTHH:MM:SSZ (override: NOW=<same format>)
# Exit codes: 0 ok, 2 usage / invalid date.
# `monday` replaces `date -d monday` (GNU: the NEXT Monday) and `date -v-Mon`
# (BSD: the PREVIOUS Monday), which disagree from Tuesday to Sunday.
set -euo pipefail

if date -u -d @0 +%s >/dev/null 2>&1; then _D_FLAVOR=gnu; else _D_FLAVOR=bsd; fi

# d_epoch YYYY-MM-DD -> UTC midnight epoch; returns 2 on anything that is not a
# real calendar date (round-trips the result, so 2026-02-31 is rejected).
function d_epoch() {
  local ymd="${1:-}" e
  [[ "$ymd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "date.sh: invalid date: '$ymd' (want YYYY-MM-DD)" >&2; return 2; }
  if [[ "$_D_FLAVOR" == gnu ]]; then
    e="$(date -u -d "$ymd 00:00:00" +%s 2>/dev/null)" || e=""
  else
    e="$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$ymd 00:00:00" +%s 2>/dev/null)" || e=""
  fi
  if [[ -z "$e" || "$(d_fmt "$e" %Y-%m-%d)" != "$ymd" ]]; then
    echo "date.sh: invalid date: '$ymd'" >&2; return 2
  fi
  printf '%s\n' "$e"
}

# d_fmt EPOCH FORMAT -> formatted UTC time.
function d_fmt() {
  if [[ "$_D_FLAVOR" == gnu ]]; then date -u -d "@$1" "+$2"; else date -u -r "$1" "+$2"; fi
}

function d_today() { printf '%s\n' "${TODAY:-$(date +%Y-%m-%d)}"; }

function d_dow() {
  local ymd="${1:-$(d_today)}" e
  e="$(d_epoch "$ymd")" || return 2
  d_fmt "$e" %u
}

function d_add() {
  local ymd="${1:-}" n="${2:-}" e
  [[ "$n" =~ ^-?[0-9]+$ ]] || { echo "date.sh: add needs an integer day count, got '$n'" >&2; return 2; }
  e="$(d_epoch "$ymd")" || return 2
  d_fmt "$(( e + n * 86400 ))" %Y-%m-%d
}

function d_monday() {
  local ymd="" next=0 a dow
  for a in "$@"; do
    case "$a" in
      --next) next=1 ;;
      *) ymd="$a" ;;
    esac
  done
  ymd="${ymd:-$(d_today)}"
  dow="$(d_dow "$ymd")" || return 2
  if [[ "$next" == 1 ]]; then
    d_add "$ymd" "$(( (8 - dow) % 7 ))"
  else
    d_add "$ymd" "$(( 1 - dow ))"
  fi
}

# d_now_epoch -> epoch seconds of NOW (ISO UTC) or the real clock.
function d_now_epoch() {
  if [[ -n "${NOW:-}" ]]; then
    if [[ "$_D_FLAVOR" == gnu ]]; then date -u -d "$NOW" +%s
    else date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$NOW" +%s; fi
  else
    date -u +%s
  fi
}

function d_ago() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "date.sh: ago needs a non-negative integer day count, got '$n'" >&2; return 2; }
  d_fmt "$(( $(d_now_epoch) - n * 86400 ))" %Y-%m-%dT%H:%M:%SZ
}

function d_main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    today)  d_today ;;
    dow)    d_dow "$@" ;;
    add)    d_add "$@" ;;
    monday) d_monday "$@" ;;
    ago)    d_ago "$@" ;;
    *) echo "usage: date.sh today | dow [DATE] | add DATE N | monday [DATE] [--next] | ago N" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  d_main "$@"
fi
