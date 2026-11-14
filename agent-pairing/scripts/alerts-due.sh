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
#               seen yet (read only the newest 20). Exit 0. Too soon: print nothing, exit 1.
#   done <ts>   advance the last-seen marker to <ts> (the newest message ts the read returned); never moves back.
#   plan        stdin: one line per candidate failure alert, tab separated:
#                 <ts> <reply_count> <ack_only 0|1> <age_minutes>
#               stdout, oldest first: "dispatch <ts>" (at most CCXP_ALERTS_CAP = 3) and "next <ts>" for the rest;
#               handled alerts print nothing. Handled = the thread has a reply, OR a context file under
#               <context dir> or a ledger row carries the ts. Exception: an ack-only thread older than 60 minutes
#               with no live job (no context file touched within 60 minutes, no ledger row) is not handled.
#
# State: ${CCXP_ALERTS_DIR:-<profile dir>/ccxp-alerts}/{last-check,last-seen}. Context dir:
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

function ad-int() { [[ "${2:-}" =~ ^[0-9]+$ ]] && echo "$2" || echo "$1"; }

function ad-check() {
  local dir now gap overlap last seen sec
  dir="$(ad-state-dir)" || return 1
  now="$(ad-now)"
  gap="$(ad-int 300 "${CCXP_ALERTS_MIN_GAP:-}")"
  overlap="$(ad-int 600 "${CCXP_ALERTS_OVERLAP:-}")"
  last=""
  [ -r "$dir/last-check" ] && last="$(cat "$dir/last-check" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && ((now - last < gap)); then return 1; fi
  mkdir -p "$dir"
  echo "$now" >"$dir/last-check"
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
  local ts="${1:-}" dir seen
  ad-is-ts "$ts" || { echo "alerts-due: done needs a message ts like 1731500000.123456 (got '$ts')" >&2; return 2; }
  dir="$(ad-state-dir)" || return 1
  mkdir -p "$dir"
  seen=""
  [ -r "$dir/last-seen" ] && seen="$(cat "$dir/last-seen" 2>/dev/null || true)"
  # never move back; compare as whole seconds then microseconds so the check is exact
  if ad-is-ts "$seen" && ! ad-newer "$ts" "$seen"; then return 0; fi
  echo "$ts" >"$dir/last-seen"
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
  local cap n=0 ts replies ack age ev handled line
  cap="$(ad-int 3 "${CCXP_ALERTS_CAP:-}")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r ts replies ack age <<<"$line"
    if ! ad-is-ts "$ts"; then echo "alerts-due: skipping bad ts '$ts'" >&2; continue; fi
    replies="$(ad-int 0 "$replies")"; age="$(ad-int 0 "$age")"
    ev="$(ad-job-evidence "$ts")"
    handled=0
    if ((replies > 0)) || [ -n "$ev" ]; then handled=1; fi
    if ((handled == 1)) && [ "$ack" = 1 ] && ((age > 60)) && [ "$ev" != live ]; then handled=0; fi
    ((handled == 0)) || continue
    if ((n < cap)); then echo "dispatch $ts"; else echo "next $ts"; fi
    n=$((n + 1))
  done < <(cat | LC_ALL=C sort -t$'\t' -k1,1g)
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
