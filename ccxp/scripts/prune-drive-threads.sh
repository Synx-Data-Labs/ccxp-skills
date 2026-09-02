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
# Idempotent — a no-op on a missing file or a file with nothing to prune. The
# `&& mv` guard leaves the original untouched if jq errors (e.g. a malformed
# file). Unresolved escalations are always kept regardless of age.
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

if [ -f "$file" ]; then
  cutoff=$(date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ")
  tmp=$(mktemp)
  jq --arg cutoff "$cutoff" \
    'with_entries(select(.value.resolved != true or .value.sent_at > $cutoff))' \
    "$file" > "$tmp" && mv "$tmp" "$file"
fi
