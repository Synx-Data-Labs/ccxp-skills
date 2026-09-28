#!/usr/bin/env bash
# _ipm/current.sh — select "the current committed IPM" file, staging-aware.
#
# Several skills locate the active iteration's IPM with a naive
# `ls -t dev/JOURNAL/*-ipm-weekly.md | head -1`. That idiom mis-selects the
# pre-IPM staging stub the `/stage` skill writes (named with the *upcoming*
# Monday's date, header `**Status**: Pre-IPM staging`), because the stub sorts
# newest. See T20260604-194697.
#
# This helper returns the newest *committed* IPM — newest file that is NOT a
# pre-IPM staging stub and whose filename date is <= today. The header-sniff is
# the load-bearing filter; the date check is a belt-and-suspenders guard against
# a committed-but-future file. Filename dates are YYYY-MM-DD, which sort
# lexically == chronologically.
#
# A SINGLE selector serves every caller:
#   - /rca Step 6 (Tier-3 auto-promote target)      -> newest committed
#   - /ccxp Phase 1.1 standup "current weekly focus" -> newest committed
#   - /ccxp Phase 2a.1.5 (seed carry-over from last IPM) -> 2a.1.5 runs BEFORE
#       2a.5, so this week's file is still a staging stub (excluded) and "newest
#       committed" already means last week's. An index-based "previous" would
#       wrongly return empty here.
#   - /ccxp Phase 2a.5b (ROADMAP) -> runs AFTER 2a.5, so this week's file is now
#       committed and is "newest committed".
#
# Usage:
#   bash current.sh [journal-dir]   # prints path or empty
#   source current.sh && _ipm_current [journal-dir]
#
# "today" is dependency-injected via $IPM_TODAY (YYYY-MM-DD) for testability;
# it defaults to the system date.
set -euo pipefail

function _ipm_current() {
  local dir="${1:-dev/JOURNAL}"
  local today="${IPM_TODAY:-$(date +%F)}"
  local f base fdate
  for f in "$dir"/*-ipm-weekly.md; do
    [ -e "$f" ] || continue                                   # no glob match -> literal path, skip
    grep -qi 'Status.*Pre-IPM staging' "$f" && continue       # exclude staging stubs (primary)
    base="$(basename "$f")"
    fdate="${base%%-ipm-weekly.md}"
    case "$fdate" in                                          # the glob "*-ipm-weekly.md" also matches
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;          #   a task journal like "…-to-ipm-weekly.md";
      *) continue ;;                                          #   real IPM files are date-prefixed (YYYY-MM-DD)
    esac
    [ "$fdate" \> "$today" ] && continue                      # exclude future-dated (guard)
    printf '%s\n' "$f"
  done | sort | tail -1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _ipm_current "${1:-dev/JOURNAL}"
fi
