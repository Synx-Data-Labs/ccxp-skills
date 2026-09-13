#!/usr/bin/env bash
# check-orphaned-refs.sh — find T<id> references OUTSIDE dev/ that don't
# resolve to an actual task file under dev/{TODO,PARKING,JOURNAL}.
#
# Catches a specific, easy-to-make mistake: minting an ID with
# `_taskid/new.sh`, then referencing it in code comments, test names, or
# commit messages — WITHOUT ever creating the task file. The ID looks real
# (it's in code, it's in the commit), but there is no dev/TODO/<id>-*.md a
# future reader can open to see what it's tracking, why it exists, or what
# "done" means. This is a real, observed failure mode — a fix once
# referenced its own task ID in two source files and a test before the
# task was ever filed.
#
# Usage:
#   bash ~/.claude/skills/_taskid/check-orphaned-refs.sh [--changed-only [<base>]] [path...]
#
# Default (no args): scans the whole repo (excluding dev/, .git/, and
# common vendor/cache dirs) for T<id> references.
#
# --changed-only [<base>]: scans only files changed vs <base> (default
# origin/main). Use this in CI / pre-merge checks — it's cheap and scoped
# to what the current PR actually touches.
#
# [path...]: scan only these paths/files instead of the whole repo.
#
# Exit 0: every T<id> reference outside dev/ resolves to a task file.
# Exit 1: prints each orphaned reference (file:line: id) and exits non-zero.
# Exit 2: usage error.
#
# Sourceable form:
#   source ~/.claude/skills/_taskid/check-orphaned-refs.sh
#   check-orphaned-refs "$@"

set -euo pipefail

function check-orphaned-refs() {
  local mode="scan-all"
  local base="origin/main"
  local -a paths=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --changed-only)
        mode="changed-only"
        shift
        if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
          base="$1"
          shift
        fi
        ;;
      -h|--help)
        sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      *)
        paths+=("$1")
        shift
        ;;
    esac
  done

  # Resolve taskid-path — source url.sh from the same directory as this
  # script (works whether this is run standalone or sourced from elsewhere).
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "${self_dir}/url.sh"

  local -a scan_files=()
  if [ "${#paths[@]}" -gt 0 ]; then
    scan_files=("${paths[@]}")
  elif [ "$mode" = "changed-only" ]; then
    # Fail loud, not quiet, if the base ref can't be resolved (shallow clone,
    # typo, unfetched branch) — silently treating that as "0 files changed"
    # would make this check pass vacuously in exactly the situation it's
    # meant to catch.
    if ! git rev-parse --verify "${base}" >/dev/null 2>&1; then
      echo "ERROR: base ref '${base}' not resolvable (git rev-parse failed) — fetch it or pass the right ref" >&2
      return 2
    fi
    mapfile -t scan_files < <(git diff --name-only "${base}...HEAD" -- . ':!dev')
  else
    mapfile -t scan_files < <(git ls-files -- . ':!dev' ':!.git' 2>/dev/null || find . -type f -not -path './dev/*' -not -path './.git/*')
  fi

  local orphaned=0
  local -A seen=()  # id -> first "file:line" seen at, to avoid re-checking the same id repeatedly per file but still report each occurrence
  local f
  for f in "${scan_files[@]}"; do
    [ -f "$f" ] || continue
    # Binary files, vendored caches, etc. — grep -I skips binaries; still
    # cheap to exclude obvious noise dirs defensively even in explicit-path mode.
    case "$f" in
      */.git/*|*/node_modules/*|*/.cache/*) continue ;;
    esac
    while IFS=: read -r lineno match; do
      [ -n "$match" ] || continue
      if ! taskid-path "$match" >/dev/null 2>&1; then
        echo "  ❌ ${f}:${lineno}: ${match} — no dev/{TODO,PARKING,JOURNAL} file found"
        orphaned=$((orphaned + 1))
      fi
    done < <(grep -InoE 'T[0-9]{8}-[0-9]{6}' "$f" 2>/dev/null || true)
  done

  if [ "$orphaned" -gt 0 ]; then
    echo "" >&2
    echo "${orphaned} orphaned task-ID reference(s) — an ID referenced in code/docs with no" >&2
    echo "corresponding dev/TODO/PARKING/JOURNAL file. File the task (or fix the typo) before merging." >&2
    return 1
  fi

  echo "✅ No orphaned task-ID references"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check-orphaned-refs "$@"
fi
