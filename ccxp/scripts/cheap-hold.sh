#!/usr/bin/env bash
# cheap-hold.sh — the ccxp Phase 1.1a gate: does this tick have anything to do?
#
# Pure decision over counts the caller already gathered (no gh, no Slack, no
# repo reads). A tick is a "cheap hold" only when ALL of these are clear:
#   replies           new maintainer replies found by /slack-check-reply   == 0
#   nightly-failures  new failed runs on main since the last tick          == 0
#   drainable         PRs Phase 0 /address-pr could still drain            == 0
#   clean-leg         autonomous /todo next candidates that are workable   == 0
#   not a Friday      retro always runs the full ritual
#
# Usage:
#   cheap-hold.sh --replies N --nightly-failures N --drainable N --clean-leg N [--dow D]
#   cheap-hold.sh ... --note [--time HH:MM] [--why TEXT]
#
# Stdout (KEY=value):
#   DECISION=hold|full
#   REASONS=<comma list of blocking reasons, or "none">
# Reasons: replies, nightly-red, drainable-pr, clean-leg, friday, and
#   unknown-<input> when an input was not supplied (a check that did not run
#   can never justify holding).
# --dow D   ISO weekday 1..7 of the reference day (default: today in
#           $CCXP_REF_TZ, default America/Chicago, the cron's frame).
# --note    when DECISION=hold, also print the Slack hold note (mrkdwn bullets)
#           after a blank line; --time sets HH:MM (default: now, UTC) and --why
#           the one-line "why each top candidate is gated" text. Nothing is sent.
# Exit: 0 decision printed, 2 bad usage or non-integer input (stdout still says
# DECISION=full, REASONS=invalid-input, so a caller that ignores the exit code
# fails closed to the full standup).
set -euo pipefail

replies="" failures="" drain="" leg="" dow="" note=0 when="" why=""
bad() { echo "cheap-hold: $*" >&2; printf 'DECISION=full\nREASONS=invalid-input\n'; exit 2; }

while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || [ "$1" = --note ] || bad "missing value for $1"
  case "$1" in
    --replies) replies="$2"; shift 2 ;;
    --nightly-failures) failures="$2"; shift 2 ;;
    --drainable) drain="$2"; shift 2 ;;
    --clean-leg) leg="$2"; shift 2 ;;
    --dow) dow="$2"; shift 2 ;;
    --note) note=1; shift ;;
    --time) when="$2"; shift 2 ;;
    --why) why="$2"; shift 2 ;;
    *) bad "unknown argument: $1" ;;
  esac
done

for pair in "replies:$replies" "nightly-failures:$failures" "drainable:$drain" "clean-leg:$leg"; do
  v="${pair#*:}"
  [ -z "$v" ] || [[ "$v" =~ ^[0-9]{1,9}$ ]] || bad "${pair%%:*} must be a non-negative integer (max 9 digits), got '$v'"
done
if [ -z "$dow" ]; then dow="$(TZ="${CCXP_REF_TZ:-America/Chicago}" date +%u)"; fi
[[ "$dow" =~ ^[1-7]$ ]] || bad "--dow must be 1..7, got '$dow'"
[ -z "$when" ] || [[ "$when" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || bad "--time must be HH:MM, got '$when'"

reasons=()
chk() { # name value reason
  if [ -z "$2" ]; then reasons+=("unknown-$1"); elif [ "$2" -ne 0 ]; then reasons+=("$3"); fi
}
chk replies "$replies" replies
chk nightly-failures "$failures" nightly-red
chk drainable "$drain" drainable-pr
chk clean-leg "$leg" clean-leg
[ "$dow" = 5 ] && reasons+=(friday)

if [ "${#reasons[@]}" -eq 0 ]; then
  printf 'DECISION=hold\nREASONS=none\n'
  if [ "$note" = 1 ]; then
    [ -n "$when" ] || when="$(date -u +%H:%M)"
    printf '\n*hold %sZ*\n• slack: 0 new\n• nightly: green\n• drainable PR: 0\n' "$when"
    if [ -n "$why" ]; then printf '• clean leg: 0 (%s)\n' "$why"; else printf '• clean leg: 0\n'; fi
  fi
else
  printf 'DECISION=full\nREASONS=%s\n' "$(IFS=,; echo "${reasons[*]}")"
fi
