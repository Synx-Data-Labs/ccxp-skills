#!/usr/bin/env bash
# in-this-repo.sh — clone-locality guard for pick-by-id skills (T20260626-298293).
#
# A task's claim, journal, and task file all live in ONE repo. Working a task
# from a DIFFERENT clone takes the claim against the wrong dev/ tree and leaves
# the clone-scoped status line blind to it (the failure observed 2026-06-26:
# T20260626-190842 worked from the build-pipeline-repo clone, whose dev/TODO
# has no such file). This helper is the missing precondition: a purely-local
# file-presence check, run at every pick-by-id entry point before any claim or
# status write.
#
# Detection is local only — it does NOT read `target-repo` frontmatter (the
# task file isn't in this repo when the guard fires, so there's nothing to
# read). The cwd repo's dev/{TODO,PARKING,JOURNAL} is the entire signal.
#
# Exit codes (so callers can branch on the situation, not just pass/fail):
#   0  present here (dev/TODO or dev/PARKING)         -> proceed
#   3  closed here  (dev/JOURNAL only)                -> don't re-work; file new
#   2  cross-repo, warn-only (default)                -> advisory; caller may continue
#   1  cross-repo, refuse   (DRIVE_STRICT_CLONE=1)    -> caller should abort
#
# Warn-only vs refuse is policy, not detection: by default a cross-repo id is a
# loud warning a caller MAY ignore (deliberate cross-clone work via absolute
# paths is legitimate); with DRIVE_STRICT_CLONE=1 it is a hard refuse, so an
# unattended ccxp loop never picks a task it can't fully own from its own clone.
#
# Usage (CLI):
#   bash ~/.claude/skills/_taskid/in-this-repo.sh T20260626-190842
#   DRIVE_STRICT_CLONE=1 bash ~/.claude/skills/_taskid/in-this-repo.sh T...   # refuse
#
# Sourceable form:
#   source ~/.claude/skills/_taskid/in-this-repo.sh
#   taskid-in-this-repo T20260626-190842 || handle "$?"
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
fi

# Reuse taskid-repo-slug (origin -> owner/repo) rather than re-deriving it.
# Sourcing url.sh is side-effect-free (its CLI dispatch is BASH_SOURCE-guarded).
# shellcheck source=/dev/null
source "$(dirname -- "${BASH_SOURCE[0]}")/url.sh"

# in-this-repo--match-in <dir> <id> — first dev/<dir> file matching the id, or "".
function in-this-repo--match-in() {
  local dir="${1:-}" id="${2:-}"
  [ -n "$dir" ] && [ -n "$id" ] || return 0
  find "$dir" -maxdepth 1 -name "*${id}*.md" 2>/dev/null | sort | head -n1
}

# in-this-repo--sibling-path <id> — if EXACTLY ONE sibling clone (a peer dir of
# the cwd repo) has dev/TODO/T<id>-*.md, print its repo root; else print nothing.
# Best-effort: ambiguity (0 or >1 matches) prints nothing rather than guess.
function in-this-repo--sibling-path() {
  local id="${1:-}" parent hit n=0 found=""
  [ -n "$id" ] || return 0
  parent="$(dirname -- "$PWD")"        # PWD is absolute, so glob hits are too
  for hit in "$parent"/*/dev/TODO/*"${id}"*.md; do
    [ -e "$hit" ] || continue          # no-match glob stays literal; skip it
    found="${hit%/dev/TODO/*}"
    [ "$found" = "$PWD" ] && { found=""; continue; }   # ignore the cwd repo itself
    n=$((n+1))
  done
  # Explicit if/return, NOT a trailing `[ ] && printf`: a falsy trailing test
  # returns 1, which under the CLI's `set -e` aborts the caller's command
  # substitution mid-flight (the warn-only/refuse banner would never print).
  if [ "$n" -eq 1 ]; then
    printf '%s\n' "$found"
  fi
  return 0
}

# taskid-in-this-repo <id> — the guard. Prints any banner to stderr; returns
# the exit code documented in the header.
function taskid-in-this-repo() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "taskid-in-this-repo: missing task ID" >&2; return 2; }

  # Present + actionable here -> proceed silently.
  if [ -n "$(in-this-repo--match-in dev/TODO "$id")" ] \
     || [ -n "$(in-this-repo--match-in dev/PARKING "$id")" ]; then
    return 0
  fi

  local slug
  slug="$(taskid-repo-slug 2>/dev/null || true)"
  [ -n "$slug" ] || slug="$(basename "$PWD")"

  # Closed here (JOURNAL only) -> distinct message, don't re-work.
  if [ -n "$(in-this-repo--match-in dev/JOURNAL "$id")" ]; then
    echo "⚠ $id is already closed in this repo ($slug) — its task file is in dev/JOURNAL." >&2
    echo "  Don't re-work it; file a new task if there's follow-up." >&2
    return 3
  fi

  # Cross-repo: absent from all three.
  echo "⚠ $id is not defined in this repo ($slug) — it's a cross-repo task." >&2
  echo "  Its task file lives in another clone. Switch to that clone before working it." >&2

  local sib
  sib="$(in-this-repo--sibling-path "$id")"
  [ -n "$sib" ] && echo "  Found it in: $sib" >&2

  if [ "${DRIVE_STRICT_CLONE:-0}" = "1" ]; then
    echo "  Refusing (DRIVE_STRICT_CLONE=1)." >&2
    return 1
  fi
  echo "  (warn-only — set DRIVE_STRICT_CLONE=1 to refuse on the wrong clone.)" >&2
  return 2
}

# Run only when executed directly (not when sourced).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  taskid-in-this-repo "$@"
fi
