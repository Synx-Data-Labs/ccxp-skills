#!/usr/bin/env bash
# _queue/queue.sh — the one implementation of dev/TODO/queue.md editing.
# Used by /stage, /top, /bottom, /todo sweep and migrate-task/scripts/migrate.sh.
# Queue entries are single lines: "- [T<id>](<file>.md): <title>". Everything
# else in the file (header, prose) is left untouched.
#
# Sourceable (functions prefixed q_) or run directly:
#   queue.sh has           <queue> <id>                         exit 0 if queued
#   queue.sh pos           <queue> <id>                         1-based entry position
#   queue.sh remove        <queue> <id>
#   queue.sh append        <queue> <id> <file> <title>          no-op if already queued
#   queue.sh insert-before <queue> <id> <file> <title> <target> moves if queued; appends if target unqueued
#   queue.sh top           <queue> <id> <file> <title>          move/add as the first entry
#   queue.sh bottom        <queue> <id> <file> <title>          move/add as the last entry
set -euo pipefail

Q_HEADER=$'# TODO Queue\n\nOrdered priority queue. Top = highest priority. One line per task.\n'

function q_init() {
  local q="$1"
  [[ -f "$q" ]] || { mkdir -p "$(dirname "$q")"; printf '%s\n' "$Q_HEADER" > "$q"; }
}

function q_has() { grep -qE "^- \[${2}\]" "$1" 2>/dev/null; }

function q_pos() {
  local q="$1" id="$2"
  awk -v id="$id" '/^- \[/ { n++; if (index($0, "- [" id "]") == 1) { print n; found=1; exit } } END { exit !found }' "$q"
}

function q_remove() {
  local q="$1" id="$2" tmp
  [[ -f "$q" ]] || return 0
  tmp="$(mktemp)"
  grep -vE "^- \[${id}\]" "$q" > "$tmp" || true
  cat "$tmp" > "$q"; rm -f "$tmp"
}

function q_line() { printf -- '- [%s](%s): %s' "$1" "$2" "$3"; }

# _q_put_before_line <queue> <line> <anchor-regex|"">: insert <line> above the
# first line matching the anchor; no anchor/no match -> append. Line goes via
# ENVIRON, not `awk -v` (which would escape-process a "\n" in a title).
function _q_put_before() {
  local q="$1" line="$2" anchor="$3" tmp
  tmp="$(mktemp)"
  Q_NEW="$line" Q_ANCHOR="$anchor" awk '
    !done && ENVIRON["Q_ANCHOR"] != "" && $0 ~ ENVIRON["Q_ANCHOR"] { print ENVIRON["Q_NEW"]; done=1 }
    { print }
    END { if (!done) print ENVIRON["Q_NEW"] }' "$q" > "$tmp"
  cat "$tmp" > "$q"; rm -f "$tmp"
}

function q_append() {
  local q="$1" id="$2"
  q_init "$q"
  q_has "$q" "$id" && return 0
  _q_put_before "$q" "$(q_line "$id" "$3" "$4")" ""
}

function q_insert_before() {
  local q="$1" id="$2" file="$3" title="$4" target="$5"
  q_init "$q"
  [[ "$id" == "$target" ]] && return 0  # self-target: leave position unchanged
  q_remove "$q" "$id"
  if [[ -n "$target" ]] && q_has "$q" "$target"; then
    _q_put_before "$q" "$(q_line "$id" "$file" "$title")" "^- \\[${target}\\]"
  else
    _q_put_before "$q" "$(q_line "$id" "$file" "$title")" ""
  fi
}

function q_top() {
  local q="$1" id="$2"
  q_init "$q"
  q_remove "$q" "$id"
  _q_put_before "$q" "$(q_line "$id" "$3" "$4")" '^- \['
}

function q_bottom() {
  local q="$1" id="$2"
  q_init "$q"
  q_remove "$q" "$id"
  _q_put_before "$q" "$(q_line "$id" "$3" "$4")" ""
}

function queue_main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    has) q_has "$@" ;;
    pos) q_pos "$@" ;;
    remove) q_remove "$@" ;;
    append) q_append "$@" ;;
    insert-before) q_insert_before "$@" ;;
    top) q_top "$@" ;;
    bottom) q_bottom "$@" ;;
    *) echo "usage: queue.sh {has|pos|remove|append|insert-before|top|bottom} <queue-file> <id> ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  queue_main "$@"
fi
