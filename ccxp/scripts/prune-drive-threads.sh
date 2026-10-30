#!/usr/bin/env bash
# prune-drive-threads.sh [--file PATH] [--days N]
#
# ccxp Phase 0.5 (Prune stale state): drops resolved entries older than the
# grace window from .claude/state/drive-threads.json. /drive records Slack
# escalations there (gitignored — local session state, never committed) and
# /slack-check-reply flips them to resolved: true once a reply lands.
# Resolved entries are dead weight: nothing reads them, but every /drive
# Phase 0.5 re-reads the whole file. The grace window keeps recently-resolved
# threads scrollable for a few days before they're dropped.
#
# Idempotent — a no-op on a missing file or a file with nothing to prune; a
# malformed file is left untouched (non-zero exit). Unresolved escalations are
# always kept regardless of age. A resolved entry's age is measured from its
# resolved_at, falling back to sent_at.
#
# Options:
#   --file PATH   Path to drive-threads.json (default: .claude/state/drive-threads.json).
#   --days N      Grace window in days (default: 7).
set -euo pipefail

file=".claude/state/drive-threads.json"
days=7
while [ $# -gt 0 ]; do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    *) echo "prune-drive-threads: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The prune logic (and the portable date maths behind its cutoff) lives in
# _threads/threads.sh, the single owner of drive-threads.json. Exit 3 there
# means "nothing to prune / no file", which this wrapper has always treated as
# success.
threads="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_threads/threads.sh"
rc=0
bash "$threads" --file "$file" prune --days "$days" || rc=$?
[ "$rc" -eq 3 ] && rc=0
exit "$rc"
