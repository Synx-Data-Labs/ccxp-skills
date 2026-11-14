#!/usr/bin/env bash
# alerts-due.sh [check | done <newest-ts> | plan]
#
# Token-free, network-free state for the ccxp-agent persona's "Slack alerts check" (T20261113-631854,
# owner decision d115). The persona does the Slack read (MCP); this script owns the rate limit, the
# last-seen marker with its overlap window, and the "handled" lookup, so the persona prose only calls it.
#
#   check       rate limit: when the last check is at least CCXP_ALERTS_MIN_GAP seconds old (default 300) or
#               there is none, record this check and print the read window start: the last-seen message ts
#               minus CCXP_ALERTS_OVERLAP seconds (default 600) as "<sec>.000000", or "-" when no ts has been
#               seen yet (read only the newest 20). Exit 0. Too soon: print nothing, exit 1. A state failure
#               (no profile dir, unwritable dir) exits 3 with a message on stderr.
#   done <ts>   advance the last-seen marker to <ts> (the newest message ts the read returned); never moves back.
#   plan        stdin: one line per candidate failure alert, tab separated:
#                 <ts> <reply_count> <ack_only 0|1> <age_minutes>  (whitespace separated)
#               (age_minutes is whole minutes; a decimal part and CR are ignored)
#               stdout, oldest first: "dispatch <ts>" (at most CCXP_ALERTS_CAP = 3) and "next <ts>" for the rest;
#               handled alerts print nothing. Alerts held back by the cap pin the next `done` to just before the
#               oldest of them (state file `hold`), so the following read sees them again. Handled = the thread has a reply, OR a context file under
#               <context dir> or a ledger row carries the ts. Exception: an ack-only thread older than 60 minutes
#               with no live job (no context file touched within 60 minutes, no ledger row) is not handled.
#
# State: ${CCXP_ALERTS_DIR:-<profile dir>/ccxp-alerts}/{last-check,last-seen,hold}. Context dir:
# ${CCXP_CONTEXT_DIR:-<profile dir>/ccxp-context}. Ledger: ${CCXP_LEDGER_FILE:-<profile dir>/ccxp-ledger.json}.
# Off switch: CCXP_ALERTS=0. Test hook: CCXP_ALERTS_NOW (epoch seconds).
set -euo pipefail

[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"

function ad-now() { echo "${CCXP_ALERTS_NOW:-$(date +%s)}"; }

function ad-state-dir() {
  if [ -n "${CCXP_ALERTS_DIR:-}" ]; then echo "$CCXP_ALERTS_DIR"; return 0; fi
  [ -n "${CCXP_PROFILE_DIR:-}" ] || return 1
  echo "$CCXP_PROFILE_DIR/ccxp-alerts"
}

function ad-context-dir() {
  if [ -n "${CCXP_CONTEXT_DIR:-}" ]; then echo "$CCXP_CONTEXT_DIR"; return 0; fi
  [ -n "${CCXP_PROFILE_DIR:-}" ] || return 1
  echo "$CCXP_PROFILE_DIR/ccxp-context"
}

function ad-ledger-file() {
  if [ -n "${CCXP_LEDGER_FILE:-}" ]; then echo "$CCXP_LEDGER_FILE"; return 0; fi
  [ -n "${CCXP_PROFILE_DIR:-}" ] || return 1
  echo "$CCXP_PROFILE_DIR/ccxp-ledger.json"
}

function ad-is-ts() { [[ "${1:-}" =~ ^[0-9]{1,12}\.[0-9]{1,9}$ ]]; }

function ad-int() { if [[ "${2:-}" =~ ^[0-9]+$ ]]; then echo $((10#$2)); else echo "$1"; fi; }

function ad-check() {
  local dir now gap overlap last seen sec
  dir="$(ad-state-dir)" || { echo "alerts-due: no profile dir; set CCXP_ALERTS_DIR" >&2; return 3; }
  now="$(ad-now)"
  gap="$(ad-int 300 "${CCXP_ALERTS_MIN_GAP:-}")"
  overlap="$(ad-int 600 "${CCXP_ALERTS_OVERLAP:-}")"
  last=""
  [ -r "$dir/last-check" ] && last="$(cat "$dir/last-check" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && ((now - last < gap)); then return 1; fi
  { mkdir -p "$dir" && echo "$now" >"$dir/last-check"; } || { echo "alerts-due: cannot write $dir" >&2; return 3; }
  seen=""
  [ -r "$dir/last-seen" ] && seen="$(cat "$dir/last-seen" 2>/dev/null || true)"
  if ad-is-ts "$seen"; then
    sec=$((${seen%%.*} - overlap))
    ((sec < 0)) && sec=0
    printf '%s.000000\n' "$sec"
  else
    echo "-"
  fi
}

function ad-done() {
  local ts="${1:-}" dir seen hold
  ad-is-ts "$ts" || { echo "alerts-due: done needs a message ts like 1731500000.123456 (got '$ts')" >&2; return 2; }
  dir="$(ad-state-dir)" || { echo "alerts-due: no profile dir; set CCXP_ALERTS_DIR" >&2; return 3; }
  mkdir -p "$dir" || { echo "alerts-due: cannot write $dir" >&2; return 3; }
  # a plan that held alerts back (cap) pins the marker just before the oldest one, so the next read sees them again
  if [ -r "$dir/hold" ]; then
    hold="$(cat "$dir/hold" 2>/dev/null || true)"
    rm -f "$dir/hold"
    if ad-is-ts "$hold" && ad-newer "$ts" "$hold"; then ts="$(ad-before "$hold")"; fi
  fi
  seen=""
  [ -r "$dir/last-seen" ] && seen="$(cat "$dir/last-seen" 2>/dev/null || true)"
  # never move back; compare as whole seconds then microseconds so the check is exact
  if ad-is-ts "$seen" && ! ad-newer "$ts" "$seen"; then return 0; fi
  echo "$ts" >"$dir/last-seen"
}

# ts $1 minus one microsecond
function ad-before() {
  local s="${1%%.*}" u="${1#*.}"
  while ((${#u} < 6)); do u="${u}0"; done
  u="${u:0:6}"
  s=$((10#$s)); u=$((10#$u))
  if ((u == 0)); then s=$((s - 1)); u=999999; else u=$((u - 1)); fi
  printf '%d.%06d\n' "$s" "$u"
}

# true when ts $1 is strictly newer than ts $2
function ad-newer() {
  local a_s="${1%%.*}" a_u="${1#*.}" b_s="${2%%.*}" b_u="${2#*.}"
  while ((${#a_u} < 9)); do a_u="${a_u}0"; done
  while ((${#b_u} < 9)); do b_u="${b_u}0"; done
  if ((10#$a_s != 10#$b_s)); then ((10#$a_s > 10#$b_s)); return; fi
  ((10#$a_u > 10#$b_u))
}

# job evidence for ts: prints "live" (context file touched within 60 min, or a ledger row), "old" (older
# context file only), or nothing
function ad-job-evidence() {
  local ts="$1" cdir lf out="" f
  if cdir="$(ad-context-dir)" && [ -d "$cdir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      out=old
      if [ -n "$(find "$f" -mmin -60 2>/dev/null)" ]; then out=live; break; fi
    done < <(grep -rlF -- "$ts" "$cdir" 2>/dev/null || true)
  fi
  if [ "$out" != live ] && lf="$(ad-ledger-file)" && [ -r "$lf" ] && grep -qF -- "$ts" "$lf" 2>/dev/null; then out=live; fi
  [ -z "$out" ] || echo "$out"
}

function ad-plan() {
  local cap n=0 ts replies ack age ev handled line hold="" dir
  cap="$(ad-int 3 "${CCXP_ALERTS_CAP:-}")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line//$'\r'/}"
    read -r ts replies ack age <<<"$line"
    age="${age%%.*}"
    if ! ad-is-ts "$ts"; then echo "alerts-due: skipping bad ts '$ts'" >&2; continue; fi
    replies="$(ad-int 0 "$replies")"; age="$(ad-int 0 "$age")"
    ev="$(ad-job-evidence "$ts")"
    handled=0
    if ((replies > 0)) || [ -n "$ev" ]; then handled=1; fi
    if ((handled == 1)) && [ "$ack" = 1 ] && ((age > 60)) && [ "$ev" != live ]; then handled=0; fi
    ((handled == 0)) || continue
    if ((n < cap)); then echo "dispatch $ts"; else echo "next $ts"; [ -n "$hold" ] || hold="$ts"; fi
    n=$((n + 1))
  done < <(cat | LC_ALL=C sort -u -k1,1g)
  # remember where held-back alerts start (or clear a stale hold) for the next `done`
  if dir="$(ad-state-dir)" && mkdir -p "$dir" 2>/dev/null; then
    if [ -n "$hold" ]; then echo "$hold" >"$dir/hold"; else rm -f "$dir/hold"; fi
  fi
}

function alerts-due() {
  local verb="${1:-check}"
  [ $# -eq 0 ] || shift
  if [ "${CCXP_ALERTS:-1}" = 0 ]; then [ "$verb" = check ] && return 1; return 0; fi
  case "$verb" in
    check) ad-check ;;
    done) ad-done "$@" ;;
    plan) ad-plan ;;
    *) echo "usage: alerts-due.sh [check|done <newest-ts>|plan]" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  alerts-due "$@"
fi
