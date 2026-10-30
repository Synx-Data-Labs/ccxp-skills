#!/usr/bin/env bash
# _threads/threads.sh — the single owner of .claude/state/drive-threads.json,
# the local (gitignored) record of Slack escalation threads that /drive opens,
# /slack-check-reply resolves and /ccxp and /retro prune and read. Before this
# lib, four skills edited the file with hand-written jq.
#
# File shape (object keyed by task id or "<task>-pr<N>"):
#   { "T1": { "channel_id": "C..", "message_ts": "..", "type": "..",
#             "summary": "..", "sent_at": "ISO", "resolved": false } }
#
# Sourceable (functions prefixed th_) or run directly:
#   threads.sh [--file F] [--dry-run] <command> ...
#   add <key> --channel C --ts TS --type T --summary S [--sent-at ISO]
#         create or REPLACE the entry for <key> (latest escalation wins; an
#         earlier unresolved one for the same key is superseded by definition)
#   resolve <key> [--at ISO] [--resolution TEXT]
#         mark resolved (adds resolved_at and optional resolution)
#   fix-ref <key> --channel C --ts TS
#         repair a stale reference in place (channel_id / message_ts only; the
#         type, summary, sent_at and resolved state are kept); exit 3 if absent
#   list [--unresolved] [--full]
#                            TSV: key, resolved, type, sent_at, summary
#                            (--full appends channel_id, message_ts)
#   prune [--days N]         drop resolved entries whose resolved_at (else
#                            sent_at) is older than N days (default 7);
#                            unresolved entries are always kept
# File: --file F, else $THREADS_FILE, else .claude/state/drive-threads.json.
# --dry-run: print what would be written to stdout, leave the file untouched.
# Writes are atomic (temp file in the same directory + mv). A malformed file is
# NEVER modified: exit 4. A missing file is created by `add` only.
# Exit codes: 0 ok, 2 usage, 3 nothing to do (absent key / already resolved /
# nothing to prune / missing file), 4 malformed state file.
# Clock: NOW=<YYYY-MM-DDTHH:MM:SSZ> pins "now" (see _date/date.sh).
set -euo pipefail

_TH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_date/date.sh
source "$_TH_DIR/../_date/date.sh"

TH_FILE="${THREADS_FILE:-.claude/state/drive-threads.json}"
TH_DRY=0

function th_die() { echo "threads.sh: $*" >&2; return "${2:-2}"; }

# th_arg <flag> <value...> -> the flag's value; a missing value is a usage
# error (exit 2 from the calling shell), not bash's ${x:?} exit 1.
function th_arg() {
  [[ $# -ge 2 ]] || { echo "threads.sh: $1 needs a value" >&2; exit 2; }
  printf '%s' "$2"
}

function th_now_iso() { d_fmt "$(d_now_epoch)" %Y-%m-%dT%H:%M:%SZ; }

# th_load -> prints the state JSON ("{}" when the file does not exist);
# returns 4 when the file is not a JSON object.
function th_load() {
  # A missing or zero-byte file is an empty state, not a malformed one.
  if [[ ! -s "$TH_FILE" ]]; then echo '{}'; return 0; fi
  if ! jq -e 'type == "object" and ([.[] | type == "object"] | all)' "$TH_FILE" >/dev/null 2>&1; then
    echo "threads.sh: $TH_FILE is not a JSON object of objects; refusing to modify it" >&2
    return 4
  fi
  cat "$TH_FILE"
}

# th_store <json> — atomic write (or dry-run echo).
function th_store() {
  local json="$1" tmp
  if [[ "$TH_DRY" == 1 ]]; then printf '%s\n' "$json"; return 0; fi
  mkdir -p "$(dirname "$TH_FILE")"
  tmp="$(mktemp "$(dirname "$TH_FILE")/.drive-threads.XXXXXX")"
  if printf '%s\n' "$json" > "$tmp" && mv "$tmp" "$TH_FILE"; then return 0; fi
  command -v trash >/dev/null 2>&1 && trash "$tmp" 2>/dev/null || true
  return 1
}

function th_add() {
  local key="${1:-}" channel="" ts="" type="" summary="" sent="" state
  [[ -n "$key" ]] || { th_die "add needs <key>"; return 2; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel) channel="$(th_arg "$@")"; shift 2 ;;
      --ts) ts="$(th_arg "$@")"; shift 2 ;;
      --type) type="$(th_arg "$@")"; shift 2 ;;
      --summary) summary="$(th_arg "$@")"; shift 2 ;;
      --sent-at) sent="$(th_arg "$@")"; shift 2 ;;
      *) th_die "add: unknown argument: $1"; return 2 ;;
    esac
  done
  [[ -n "$channel" && -n "$ts" && -n "$type" && -n "$summary" ]] \
    || { th_die "add needs --channel, --ts, --type and --summary"; return 2; }
  sent="${sent:-$(th_now_iso)}"
  state="$(th_load)" || return $?
  th_store "$(jq --arg k "$key" --arg c "$channel" --arg t "$ts" --arg ty "$type" \
    --arg s "$summary" --arg at "$sent" \
    '.[$k] = {channel_id: $c, message_ts: $t, type: $ty, summary: $s, sent_at: $at, resolved: false}' \
    <<<"$state")"
}

function th_resolve() {
  local key="${1:-}" at="" resolution="" state
  [[ -n "$key" ]] || { th_die "resolve needs <key>"; return 2; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="$(th_arg "$@")"; shift 2 ;;
      --resolution) resolution="$(th_arg "$@")"; shift 2 ;;
      *) th_die "resolve: unknown argument: $1"; return 2 ;;
    esac
  done
  [[ -f "$TH_FILE" ]] || return 3
  at="${at:-$(th_now_iso)}"
  state="$(th_load)" || return $?
  jq -e --arg k "$key" 'has($k) and (.[$k].resolved != true)' <<<"$state" >/dev/null || return 3
  th_store "$(jq --arg k "$key" --arg at "$at" --arg r "$resolution" \
    '.[$k] += {resolved: true, resolved_at: $at} | if $r != "" then .[$k].resolution = $r else . end' \
    <<<"$state")"
}

function th_fix_ref() {
  local key="${1:-}" channel="" ts="" state
  [[ -n "$key" ]] || { th_die "fix-ref needs <key>"; return 2; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channel) channel="$(th_arg "$@")"; shift 2 ;;
      --ts) ts="$(th_arg "$@")"; shift 2 ;;
      *) th_die "fix-ref: unknown argument: $1"; return 2 ;;
    esac
  done
  [[ -n "$channel" && -n "$ts" ]] || { th_die "fix-ref needs --channel and --ts"; return 2; }
  [[ -f "$TH_FILE" ]] || return 3
  state="$(th_load)" || return $?
  jq -e --arg k "$key" 'has($k)' <<<"$state" >/dev/null || return 3
  th_store "$(jq --arg k "$key" --arg c "$channel" --arg t "$ts" \
    '.[$k] += {channel_id: $c, message_ts: $t}' <<<"$state")"
}

function th_list() {
  local only=0 full=0 state
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unresolved) only=1; shift ;;
      --full) full=1; shift ;;
      *) th_die "list: unknown argument: $1"; return 2 ;;
    esac
  done
  [[ -s "$TH_FILE" ]] || return 0
  state="$(th_load)" || return $?
  jq -r --argjson only "$only" --argjson full "$full" 'to_entries[]
    | select($only == 0 or .value.resolved != true)
    | [.key, (.value.resolved // false | tostring), (.value.type // ""),
       (.value.sent_at // ""), (.value.summary // "" | gsub("[\t\n]"; " "))]
      + (if $full == 1 then [(.value.channel_id // ""), (.value.message_ts // "")] else [] end)
    | @tsv' <<<"$state"
}

function th_prune() {
  local days=7 state cutoff out
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$(th_arg "$@")"; shift 2 ;;
      *) th_die "prune: unknown argument: $1"; return 2 ;;
    esac
  done
  [[ -f "$TH_FILE" ]] || return 3
  state="$(th_load)" || return $?
  cutoff="$(d_ago "$days")" || return 2
  out="$(jq --arg cutoff "$cutoff" \
    'with_entries(select(.value.resolved != true or ((.value.resolved_at // .value.sent_at // "") > $cutoff)))' \
    <<<"$state")"
  # Nothing pruned -> leave the file byte-for-byte alone.
  if [[ "$(jq -S . <<<"$state")" == "$(jq -S . <<<"$out")" ]]; then return 3; fi
  th_store "$out"
}

function th_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) TH_FILE="$(th_arg "$@")"; shift 2 ;;
      --dry-run) TH_DRY=1; shift ;;
      *) break ;;
    esac
  done
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    add) th_add "$@" ;;
    resolve) th_resolve "$@" ;;
    list) th_list "$@" ;;
    fix-ref) th_fix_ref "$@" ;;
    prune) th_prune "$@" ;;
    *) echo "usage: threads.sh [--file F] [--dry-run] add|resolve|fix-ref|list|prune ..." >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  th_main "$@"
fi
