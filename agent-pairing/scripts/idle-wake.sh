#!/usr/bin/env bash
# idle-wake.sh [plan [--wake] | status]
#
# Token-free, network-free state for the ccxp-agent persona's "Idle wake" (T20261120-105513, n362): with autopilot
# off and a session open, the persona schedules ONE ScheduleWakeup every 30 minutes that runs only the two read-only
# checks (alerts-due.sh check and the CI failure check) and starts a job only for something new. This script owns the
# "is a wake already pending" bookkeeping and the opt-out, so the persona prose only calls it.
#
#   plan     prints "schedule <seconds>" (and records the next wake time) when an idle wake should be scheduled now:
#            enabled, autopilot not on, and no wake still pending. Prints nothing and exits 1 otherwise (disabled,
#            autopilot on, or a wake is already pending). A state failure exits 3 with a message on stderr.
#            A recorded wake counts as pending until it is due plus a 2-minute grace; after that (the wake fired,
#            or the session ended and never fired it) the next `plan` schedules again. `plan --wake` is for the
#            `[idle-wake]` wake itself: the wake that just fired is the recorded one, so it ignores the pending
#            record and schedules the next wake at once (without it the chain would stop after the first wake).
#   status   one line: "enabled|disabled <reason>" and the recorded next wake epoch (0 = none).
#
# Opt-out: CCXP_IDLE_WAKE=0, or {"enabled": false} in ${CCXP_IDLE_DIR:-<profile dir>/ccxp-idle}/config.json.
# Interval: {"minutes": N} in that file or CCXP_IDLE_MINUTES (default 30, never below 5: the alerts check's own
# 5-minute rate limit). Autopilot state: `autopilot-state.sh status` of the working directory's repo (autopilot wakes
# already carry the checks, so autopilot on means no idle wake).
# State: ${CCXP_IDLE_DIR:-<profile dir>/ccxp-idle}/next-at. Test hook: CCXP_IDLE_NOW (epoch seconds).
set -euo pipefail

_IW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$_IW_DIR/../../_session/profile-dir.sh" ] && . "$_IW_DIR/../../_session/profile-dir.sh"

function iw-now() { echo "${CCXP_IDLE_NOW:-$(date +%s)}"; }

function iw-dir() {
  if [ -n "${CCXP_IDLE_DIR:-}" ]; then echo "$CCXP_IDLE_DIR"; return 0; fi
  [ -n "${CCXP_PROFILE_DIR:-}" ] || return 1
  echo "$CCXP_PROFILE_DIR/ccxp-idle"
}

# Prints "" when enabled, else the reason.
function iw-disabled() {
  local dir; dir="$(iw-dir 2>/dev/null || true)"
  [ "${CCXP_IDLE_WAKE:-1}" != 0 ] || { echo "CCXP_IDLE_WAKE=0"; return 0; }
  if [ -n "$dir" ] && [ -r "$dir/config.json" ] && [ "$(jq -r '.enabled == false' "$dir/config.json" 2>/dev/null || echo false)" = true ]; then
    echo "config.json enabled=false"; return 0
  fi
  return 0
}

function iw-minutes() {
  local dir m="${CCXP_IDLE_MINUTES:-}"; dir="$(iw-dir 2>/dev/null || true)"
  if ! [[ "$m" =~ ^[0-9]{1,4}$ ]] && [ -n "$dir" ] && [ -r "$dir/config.json" ]; then
    m="$(jq -r '(.minutes // empty) | numbers | floor' "$dir/config.json" 2>/dev/null || true)"
  fi
  [[ "$m" =~ ^[0-9]{1,4}$ ]] || m=30
  m=$((10#$m)); [ "$m" -ge 5 ] || m=5
  echo "$m"
}

function iw-autopilot-on() {
  [ "$(bash "$_IW_DIR/../../autopilot/scripts/autopilot-state.sh" status 2>/dev/null || echo off)" = on ]
}

function iw-next() {
  local dir v=0; dir="$(iw-dir 2>/dev/null)" || { echo 0; return 0; }
  [ -r "$dir/next-at" ] && v="$(head -c 20 "$dir/next-at" 2>/dev/null | tr -d '[:space:]')" || true
  [[ "$v" =~ ^[0-9]{1,12}$ ]] || v=0
  echo "$((10#$v))"
}

function iw-plan() {
  local dir now next gap why wake=0
  [ "${1:-}" != --wake ] || wake=1
  why="$(iw-disabled)"
  [ -z "$why" ] || return 1
  iw-autopilot-on && return 1
  dir="$(iw-dir)" || { echo "idle-wake: no profile dir; set CCXP_IDLE_DIR" >&2; return 3; }
  now="$(iw-now)"; next="$(iw-next)"
  # Pending: a wake is recorded and not yet more than 2 minutes past due.
  if [ "$wake" = 0 ] && [ "$next" -gt 0 ] && [ "$now" -le $((next + 120)) ]; then return 1; fi
  gap=$(( $(iw-minutes) * 60 ))
  { mkdir -p "$dir" && echo $((now + gap)) >"$dir/next-at"; } || { echo "idle-wake: cannot write $dir" >&2; return 3; }
  echo "schedule $gap"
}

function iw-status() {
  local why; why="$(iw-disabled)"
  if [ -n "$why" ]; then echo "disabled $why next=$(iw-next)"; return 0; fi
  if iw-autopilot-on; then echo "disabled autopilot on next=$(iw-next)"; return 0; fi
  echo "enabled minutes=$(iw-minutes) next=$(iw-next)"
}

function idle-wake() {
  case "${1:-}" in
    plan) shift; iw-plan "$@" ;;
    status) iw-status ;;
    *) echo "usage: idle-wake.sh plan [--wake] | status" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  idle-wake "$@"
fi
