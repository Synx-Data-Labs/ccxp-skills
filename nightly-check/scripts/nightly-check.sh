#!/usr/bin/env bash
# nightly-check.sh plan [opts]   (T20261116-179192, routines part 3b)
#
# The mechanical filter of /nightly-check: reads `gh run list --json databaseId,workflowName,event,headBranch,
# conclusion,createdAt,url` (a JSON array) on stdin and prints what to investigate. It never calls gh, Slack or
# /rca; the skill does that.
#
#   plan [--window-hours N] [--now EPOCH] [--alerts FILE] [--handled FILE] [--max N]
#       --window-hours N  only runs created in the last N hours (default 26)
#       --now EPOCH       clock override (tests)
#       --alerts FILE     one alert per line, "<message_ts><TAB><flattened text>"; a run whose id appears in the
#                         text routes to labrun-rca with that ts, every other run to rca
#       --handled FILE    any text (task files, context files); a run id found in it is skipped (dedupe)
#       --max N           at most N `run` lines (default 3); the rest print as `next` lines
#
# A nightly run is a failed run of event `schedule`, or of event `workflow_dispatch` whose workflow name contains
# "nightly" (case-insensitive). PR-branch and tag runs are not nightly runs: the persona's inline path keeps them.
#
# stdout, one line per run, oldest first:
#   run<TAB>rca|labrun-rca<TAB><run id><TAB><workflow><TAB><url><TAB><alert ts or ->
#   next<TAB>... (same columns; over the cap)
# Nothing printed (exit 0) when no failed nightly run needs work. Exit 2 usage, 3 stdin is not a JSON array.
set -euo pipefail

function nc-die() { echo "nightly-check: $*" >&2; return "${NC_RC:-2}"; }

# nc-plan <json-file> <window-hours> <now> <alerts-file|""> <handled-file|""> <max>
function nc-plan() {
  local json=$1 hours=$2 now=$3 alerts=$4 handled=$5 max=$6
  local cutoff id wf url ts n=0 route rows
  cutoff=$((now - hours * 3600))
  command -v jq >/dev/null 2>&1 || { NC_RC=3 nc-die "jq is required"; return; }
  jq -e 'type == "array"' "$json" >/dev/null 2>&1 || { NC_RC=3 nc-die "stdin is not a JSON array"; return; }
  rows="$(mktemp)"
  jq -r --argjson cutoff "$cutoff" '
      [ .[] | select((.conclusion // "failure") == "failure")
            | select(.event == "schedule"
                     or (.event == "workflow_dispatch" and ((.workflowName // "") | test("nightly"; "i"))))
            | select(((.createdAt // "" | try fromdateiso8601 catch 0)) >= $cutoff)
            | {id: (.databaseId | tostring), wf: (if (.workflowName // "") == "" then "?" else .workflowName end), url: (if (.url // "") == "" then "-" else .url end), at: (.createdAt // "")} ]
      | sort_by(.at) | .[] | [.id, .wf, .url] | @tsv' "$json" > "$rows" || { command rm -f "$rows"; NC_RC=3 nc-die "cannot filter the run list"; return; }
  while IFS=$'\t' read -r id wf url; do
    [ -n "$id" ] || continue
    if [ -n "$handled" ] && grep -Fwq -- "$id" "$handled"; then continue; fi
    route=rca ts=-
    if [ -n "$alerts" ]; then
      ts="$(nc-alert-ts "$alerts" "$id")"
      if [ -n "$ts" ]; then route=labrun-rca; else ts=-; fi
    fi
    n=$((n + 1))
    if [ "$n" -le "$max" ]; then printf 'run\t%s\t%s\t%s\t%s\t%s\n' "$route" "$id" "$wf" "$url" "$ts"
    else printf 'next\t%s\t%s\t%s\t%s\t%s\n' "$route" "$id" "$wf" "$url" "$ts"; fi
  done < "$rows"
  command rm -f "$rows"
}

# first alert ts whose text mentions run id $2 (a whole number, so a longer id does not match)
function nc-alert-ts() {
  local file=$1 id=$2 ts text
  while IFS=$'\t' read -r ts text || [ -n "$ts" ]; do
    if printf '%s' "$text" | grep -Eq "(^|[^0-9])${id}([^0-9]|$)"; then echo "$ts"; return 0; fi
  done < "$file"
  return 0
}

function nightly-check() {
  local verb=${1:-}
  [ "$verb" = plan ] || { nc-die "usage: nightly-check.sh plan [--window-hours N] [--now EPOCH] [--alerts FILE] [--handled FILE] [--max N]"; return; }
  shift
  local hours=26 now="" alerts="" handled="" max=3 json
  while [ "$#" -gt 0 ]; do
    case "$1" in --*) [ "$#" -ge 2 ] || { nc-die "option '$1' needs a value"; return; } ;; esac
    case "$1" in
      --window-hours) hours=${2:-}; shift 2 ;;
      --now) now=${2:-}; shift 2 ;;
      --alerts) alerts=${2:-}; shift 2 ;;
      --handled) handled=${2:-}; shift 2 ;;
      --max) max=${2:-}; shift 2 ;;
      *) nc-die "unknown option '$1'"; return ;;
    esac
  done
  [[ "$hours" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || { nc-die "--window-hours and --max take a whole number"; return; }
  [ -n "$now" ] || now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || { nc-die "--now takes epoch seconds"; return; }
  hours=$((10#$hours)) max=$((10#$max)) now=$((10#$now))   # no octal reading of 08 or 09
  for f in "$alerts" "$handled"; do
    [ -z "$f" ] || [ -r "$f" ] || { nc-die "cannot read '$f'"; return; }
  done
  json="$(mktemp)"
  cat > "$json"
  nc-plan "$json" "$hours" "$now" "$alerts" "$handled" "$max" || { local rc=$?; command rm -f "$json" 2>/dev/null; return "$rc"; }
  command rm -f "$json" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  nightly-check "$@"
fi
