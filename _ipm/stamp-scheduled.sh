#!/usr/bin/env bash
# stamp-scheduled.sh <task-file> [current|next] [journal-dir]
#
# Stamp a task file's `scheduled:` YAML frontmatter with the Monday of the
# current (default) or next iteration, so an on-the-fly-created task is mapped to
# a board iteration (the `sync-tasks` mirror reads `scheduled` → Iteration). The
# Monday is resolved by a token-free-first 3-tier hybrid:
#
#   1. IPM file   — newest committed `*-ipm-weekly.md` (via _ipm/current.sh),
#                   staging-aware, no token. Monday == the filename date.
#                   Staleness-bound: a result more than 14 days behind today
#                   is discarded and Tier 2/3 is tried instead — this tier
#                   maps to the *current/upcoming* iteration, so an old
#                   result would be silently wrong, not just old (T20260810-632933).
#   2. Project API — $STAMP_ITER_HELPER (default _session/iteration.sh), the
#                   board's Iteration field. Token-gated; empty without a PAT.
#   3. next-Monday — computed from today: the Monday that starts next week.
#
# `next` mode adds 7 days to whatever tier 1/2/3 resolved (iterations are weekly
# Mondays by convention, so current+7 == next). The write is **update-forward-
# only**: an existing later `scheduled:` is never moved backward. Best-effort —
# a non-YAML/legacy file or an unresolved date never hard-fails the caller; it
# prints the effective date on success, nothing otherwise.
#
# Used by /rca, /retro, /address-pr, /drive (see those SKILL.md files).
#
# Date injection for tests: IPM_TODAY=YYYY-MM-DD (today, shared with
# _ipm/current.sh + the next-Monday tier); STAMP_ITER_HELPER overrides the API
# tier with a stub command.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASKFILE="${1:-}"
MODE="${2:-current}"
JOURNAL="${3:-dev/JOURNAL}"

[ -n "$TASKFILE" ] || { echo "usage: stamp-scheduled.sh <task-file> [current|next] [journal-dir]" >&2; exit 64; }
[ "$MODE" = next ] || MODE=current        # normalize empty / garbage → current
TODAY="${IPM_TODAY:-$(date +%F)}"

# --- resolve the base Monday (token-free first) ------------------------------
BASE=""

# Tier 1: committed IPM file (sourcing current.sh is side-effect-free — its
# dispatch block is guarded). It flips `set -e`, so relax it afterwards.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/current.sh"
set +e
ipm="$(_ipm_current "$JOURNAL" 2>/dev/null)"
if [ -n "$ipm" ]; then
  b="$(basename "$ipm")"
  BASE="${b%-ipm-weekly.md}"
fi

# Staleness bound: _ipm_current() intentionally serves other callers (rca,
# ccxp Phase 1.1/2a.1.5/2a.5b) "newest committed, however old" — but here BASE
# maps a task to the *current/upcoming* board iteration, so an old result is
# wrong, not just old. If BASE is more than 14 days behind TODAY, discard it
# and let the existing Tier-2 fallthrough below take over. GNU date then BSD
# date, same idiom as _session/task_claim.sh's _tc_iso_to_epoch.
if [ -n "$BASE" ]; then
  base_epoch="$(date -u -d "$BASE" +%s 2>/dev/null)"
  [ -n "$base_epoch" ] || base_epoch="$(date -u -j -f '%Y-%m-%d' "$BASE" +%s 2>/dev/null)"
  today_epoch="$(date -u -d "$TODAY" +%s 2>/dev/null)"
  [ -n "$today_epoch" ] || today_epoch="$(date -u -j -f '%Y-%m-%d' "$TODAY" +%s 2>/dev/null)"
  if [ -n "$base_epoch" ] && [ -n "$today_epoch" ]; then
    age_days=$(( (today_epoch - base_epoch) / 86400 ))
    [ "$age_days" -gt 14 ] && BASE=""
  fi
fi

# Tier 2: Project-API fallback (token-gated, best-effort-empty).
if [ -z "$BASE" ]; then
  if [ -n "${STAMP_ITER_HELPER:-}" ]; then
    api="$($STAMP_ITER_HELPER current 2>/dev/null)"          # override: a command string, word-split (tests)
  else
    api="$(bash "$SCRIPT_DIR/../_session/iteration.sh" current 2>/dev/null)"  # default: space-safe (no word-split)
  fi
  [ -n "$api" ] && BASE="$api"
fi

# --- compute final date, write frontmatter (forward-only), print effective ---
TASKFILE="$TASKFILE" BASE="$BASE" MODE="$MODE" TODAY="$TODAY" python3 - <<'PY'
import os, sys, re, datetime

tf   = os.environ["TASKFILE"]
base = os.environ.get("BASE", "")
mode = os.environ.get("MODE", "current")
today = os.environ.get("TODAY", "")

def parse_iso(s):
    """Lenient ISO-date parse: tolerate surrounding quotes/space. None on failure."""
    if not s:
        return None
    try:
        return datetime.date.fromisoformat(s.strip().strip('"').strip("'"))
    except (ValueError, AttributeError):
        return None

def final_date():
    d = parse_iso(base)                                     # tier 1/2 source (may be malformed → None)
    if d is None:
        t = parse_iso(today) or datetime.date.today()       # never crash on a bad TODAY
        monday = t - datetime.timedelta(days=t.weekday())   # this week's Monday
        d = monday + datetime.timedelta(days=7)             # next week's Monday
    if mode == "next":
        d = d + datetime.timedelta(days=7)
    return d.isoformat()

newdate = final_date()

try:
    with open(tf) as f:
        lines = f.read().split("\n")
except OSError:
    sys.exit(0)

# YAML frontmatter only: first line must be a `---` fence with a closing fence.
if not lines or lines[0].strip() != "---":
    sys.exit(0)
end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
if end is None:
    sys.exit(0)

sched_idx = status_idx = None
existing = None
for i in range(1, end):
    m = re.match(r"^scheduled:\s*(.*)$", lines[i])
    if m:
        sched_idx, existing = i, m.group(1).strip()
    if re.match(r"^status:", lines[i]):
        status_idx = i

effective = newdate
existing_d = parse_iso(existing)            # None if absent, empty, or unparseable
if sched_idx is not None:
    if existing_d is not None and newdate < existing_d.isoformat():
        effective = existing_d.isoformat()  # keep the later date, never move back (forward-only)
    else:                                   # forward / equal / empty / unparseable → (over)write
        lines[sched_idx] = f"scheduled: {newdate}"
else:                                       # absent key → insert after status:, else before fence
    ins = (status_idx + 1) if status_idx is not None else end
    lines.insert(ins, f"scheduled: {newdate}")

with open(tf, "w") as f:
    f.write("\n".join(lines))
print(effective)
PY
