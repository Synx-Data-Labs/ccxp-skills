#!/usr/bin/env bash
# job-status.sh [<job-number>|<name>] [--report]
# Lists detached ccxp jobs (names `j<N>-...`) from `claude agents --json --all`,
# one line each: #N name state/status [waitingFor] id. With a job given and
# --report, also prints that job's last assistant message (its report) from the
# session transcript. Read-only; run it at turn start or when asked for status.
set -euo pipefail

function list-jobs() {
  local sel="${1:-}"
  claude agents --json --all | jq -r --arg sel "$sel" '
    .[] | select((.name // "") | test("^j[0-9]+-"))
    | select($sel == "" or .name == $sel or (.name | startswith("j" + $sel + "-")))
    | "#" + (.name | capture("^j(?<n>[0-9]+)-").n) + " " + .name + " "
      + (.state // "?") + "/" + (.status // "-")
      + (if .waitingFor then " waiting:" + (.waitingFor | gsub(" "; "_")) else "" end)
      + " " + .id'
}

function report() {
  local sel="$1" sid f
  sid="$(claude agents --json --all | jq -r --arg sel "$sel" '
    [.[] | select(.name == $sel or ((.name // "") | startswith("j" + $sel + "-")))][0].sessionId // empty')"
  [[ -n "$sid" ]] || { echo "no such job: $sel" >&2; return 1; }
  f="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "$sid.jsonl" 2>/dev/null | head -1)"
  [[ -n "$f" ]] || { echo "transcript not found for $sid" >&2; return 1; }
  jq -rs '[.[] | select(.type=="assistant") | .message.content
           | if type=="string" then . else map(select(.type=="text").text) | join("\n") end
           | select(length>0)] | last // "(no assistant text yet)"' "$f"
}

function main() {
  local sel="" want_report=0
  while (( $# )); do
    case "$1" in
      --report) want_report=1 ;;
      *) sel="$1" ;;
    esac
    shift
  done
  list-jobs "$sel"
  if (( want_report )); then
    [[ -n "$sel" ]] || { echo "--report needs a job number or name" >&2; return 2; }
    echo "--- report ---"; report "$sel"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
