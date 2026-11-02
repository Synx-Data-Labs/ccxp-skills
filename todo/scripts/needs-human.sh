#!/usr/bin/env bash
# needs-human.sh — read, write and list the "needs a human" marker in a task
# file's `status:` line (T20261102-261809). The marker is the durable, visible-to-
# every-session replacement for autopilot's per-clone skip list: a driver that
# cannot proceed for an owner-only reason writes it, the owner removes it.
#
# Grammar (the parser lives in _lib.sh, todo-needs-human-kind):
#   status: <leading status text> — needs a human [<kind>]: <reason>
#   kind = blocked | decision | external
#
#   needs-human.sh kind  <task-file|T<id>>          print the kind; exit 1 when unmarked
#   needs-human.sh mark  [--release] <task-file|T<id>> <kind> <reason>
#                                                   write/replace the marker; --release also
#                                                   clears claimed_by/claimed_role
#   needs-human.sh clear <task-file|T<id>>          remove the marker; exit 1 when none
#   needs-human.sh list  [repo-root]                one "<id>\t<kind>\t<reason>" line per
#                                                   marked task in <repo-root>/dev/TODO
# A T<id> argument resolves to dev/TODO/<id>-*.md under $NEEDS_HUMAN_ROOT (default ".").
set -euo pipefail

NH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$NH_DIR/_lib.sh"

NH_SEP=' — '
NH_ID_RE='^T[0-9]{8}-[0-9]{6}$'

function nh-resolve() {
  local arg="${1:?task file or T<id>}" root="${NEEDS_HUMAN_ROOT:-.}" f
  if [[ "$arg" =~ $NH_ID_RE ]]; then
    for f in "$root"/dev/TODO/"$arg"-*.md; do
      [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    printf 'needs-human: no task file for %s under %s/dev/TODO\n' "$arg" "$root" >&2
    return 2
  fi
  [ -f "$arg" ] || { printf 'needs-human: no such file: %s\n' "$arg" >&2; return 2; }
  printf '%s\n' "$arg"
}

# The status value with any bracketed marker suffix removed.
function nh-base-status() {
  local s="$1" lc prefix
  lc="$(printf '%s' "$s" | tr 'A-Z' 'a-z')"
  prefix="${lc%%"${NH_SEP}needs a human ["*}"
  if [ "$prefix" = "$lc" ]; then printf '%s' "$s"; else printf '%s' "${s:0:${#prefix}}"; fi
}

function nh-set-status() {
  local file="$1" value="$2"
  # shellcheck source=../../_session/task_claim.sh
  source "$NH_DIR/../../_session/task_claim.sh"
  # _tc_fm_set hands the value to awk -v, which expands backslash escapes: double them.
  _tc_fm_set "$file" status "${value//\\/\\\\}"
}

function nh-kind() {
  local file kind
  file="$(nh-resolve "${1:-}")" || return 2
  kind="$(todo-needs-human-kind "$(todo-fm-get "$file" status)")" || return 1
  printf '%s\n' "$kind"
}

function nh-mark() {
  local release=0
  if [ "${1:-}" = "--release" ]; then release=1; shift; fi
  local arg="${1:-}" kind="${2:-}" reason="${3:-}" file base
  case "$kind" in
    blocked|decision|external) ;;
    *) printf 'usage: needs-human.sh mark [--release] <task-file|T<id>> blocked|decision|external <reason>\n' >&2; return 2 ;;
  esac
  reason="$(printf '%s' "$reason" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -n "$reason" ] || { printf 'needs-human: a reason is required\n' >&2; return 2; }
  file="$(nh-resolve "$arg")" || return 2
  base="$(nh-base-status "$(todo-fm-get "$file" status)")"
  [ -n "$base" ] || base="Open"
  nh-set-status "$file" "${base}${NH_SEP}needs a human [${kind}]: ${reason}"
  if [ "$release" = 1 ]; then
    _tc_fm_set "$file" claimed_by ""
    _tc_fm_set "$file" claimed_role ""
  fi
  printf 'marked %s\n' "$kind"
}

function nh-clear() {
  local file status base
  file="$(nh-resolve "${1:-}")" || return 2
  status="$(todo-fm-get "$file" status)"
  base="$(nh-base-status "$status")"
  if [ "$base" = "$status" ]; then
    printf 'noop\n'
    return 1
  fi
  nh-set-status "$file" "$base"
  printf 'cleared\n'
}

function nh-list() {
  local root="${1:-.}" f b id status kind reason
  for f in "$root"/dev/TODO/T*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    [[ "$b" =~ ^(T[0-9]{8}-[0-9]{6}) ]] || continue
    id="${BASH_REMATCH[1]}"
    status="$(todo-fm-get "$f" status)"
    kind="$(todo-needs-human-kind "$status")" || continue
    reason="$(printf '%s' "$status" | sed -nE 's/.*[Nn]eeds a human \[(blocked|decision|external)\]: //p')"
    [ -n "$reason" ] || reason="$status"
    printf '%s\t%s\t%s\n' "$id" "$kind" "$reason"
  done
}

function needs-human() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    kind) nh-kind "$@" ;;
    mark) nh-mark "$@" ;;
    clear) nh-clear "$@" ;;
    list) nh-list "$@" ;;
    *) sed -n '2,19p' "${BASH_SOURCE[0]}" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  needs-human "$@"
fi
