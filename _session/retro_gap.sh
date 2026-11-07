#!/usr/bin/env bash
# retro_gap.sh — detect a missed Friday retro (T20260813-392025).
#
# The Friday `/retro` (ccxp Phase 2b) tolerates one missed Friday, but nothing
# noticed when it had silently not run for several in a row. This is the
# detector, in the shape of claim_gap.sh: sourceable, function-wrapped,
# detector-only (never mutates, never runs /retro), idempotent.
#
# Usage: retro_gap.sh [journal-dir]       (default ./dev/JOURNAL)
# Env:   RETRO_GAP_TODAY=YYYY-MM-DD   override "today" (tests). Default: today
#                                      in America/Chicago, Phase 2b's frame.
# Output (stdout, one line, only when there is a gap; silent otherwise):
#   retro-gap <N>d — last retro-weekly <YYYY-MM-DD> (<file>)
#   retro-gap none — no retro-weekly file found in <dir>
# A retro is "late" when the newest one is MORE than 7 days old (so exactly 7
# days, a normal Friday-to-Friday cadence, is silent). The age counts from the
# date in the filename (the day /retro ran), never mtime (git checkout resets it).
# Always exits 0: visibility only, like claim_gap.sh.

set -uo pipefail

_rg_today() {
  if [ -n "${RETRO_GAP_TODAY:-}" ]; then printf '%s' "$RETRO_GAP_TODAY"; return; fi
  TZ=America/Chicago date +%Y-%m-%d
}

# YYYY-MM-DD -> days since epoch (GNU or BSD date; UTC so no DST skew).
_rg_days() {
  local s
  s="$(date -u -d "$1" +%s 2>/dev/null)" || s="$(date -u -j -f %Y-%m-%d "$1" +%s 2>/dev/null)" || return 1
  printf '%s' $(( s / 86400 ))
}

retro_gap() {
  local dir="${1:-dev/JOURNAL}" newest="" f d today a b age
  for f in "$dir"/????-??-??-retro-weekly.md; do
    [ -e "$f" ] || continue
    d="$(basename "$f")"; d="${d%%-retro-weekly.md}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    if [ -z "$newest" ] || [[ "$d" > "$newest" ]]; then newest="$d"; fi
  done
  if [ -z "$newest" ]; then
    printf 'retro-gap none — no retro-weekly file found in %s\n' "$dir"
    return 0
  fi
  today="$(_rg_today)"
  a="$(_rg_days "$today")" && b="$(_rg_days "$newest")" || return 0
  age=$(( a - b ))
  if [ "$age" -gt 7 ]; then
    printf 'retro-gap %sd — last retro-weekly %s (%s-retro-weekly.md)\n' "$age" "$newest" "$newest"
  fi
  return 0
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  retro_gap "$@"
fi
