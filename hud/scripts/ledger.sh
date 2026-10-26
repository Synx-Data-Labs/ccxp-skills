#!/usr/bin/env bash
# Job ledger writer for the HUD "jobs" section.
#
#   ledger.sh start <n> <title>   job r<n> started (lifetime_jobs = highest n ever)
#   ledger.sh finish <n>          job r<n> no longer running
#   ledger.sh park <k>            park id k<k> (k5, K5 or 5 all mean k5)
#   ledger.sh unpark <k>
#   ledger.sh set-parked <n>      overwrite the parked count (ids kept as-is)
#   ledger.sh show                print the ledger JSON (never fails)
#
# File: ${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}
# {"updated_at","next_job","lifetime_jobs","parked","parked_ids":[],"running":[{"job","title"}]}
# Writes are atomic (temp file + mv); a missing or corrupt file starts fresh.
# Not locked: concurrent writers are last-write-wins. Titles only, no secrets.

ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}"
}

# Current ledger, normalized; defaults when missing/corrupt.
ledger-read() {
  local f; f=$(ledger-file)
  jq -c 'if type == "object" then . else {} end
    | {lifetime_jobs: (.lifetime_jobs | numbers // 0),
       parked: (.parked | numbers // 0),
       parked_ids: [(.parked_ids // [])[] | strings],
       running: [(.running // [])[] | select(type == "object")
                 | {job: (.job | numbers // 0), title: (.title | strings // "")}]}' \
    "$f" 2>/dev/null || printf '{"lifetime_jobs":0,"parked":0,"parked_ids":[],"running":[]}'
}

# $1 jq filter over the normalized ledger; remaining args are jq args.
ledger-update() {
  local filter="$1"; shift
  local f tmp cur
  f=$(ledger-file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  cur=$(ledger-read)
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if printf '%s' "$cur" | jq "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$filter | .updated_at = \$now | .next_job = (.lifetime_jobs + 1)
       | .parked = (if .parked < 0 then 0 else .parked end)" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$f"
  else
    unlink "$tmp" 2>/dev/null
    return 1
  fi
}

ledger-int() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "ledger: not a number: $1" >&2; return 2; }; }

ledger-kid() { local k="${1#[kK]}"; ledger-int "$k" || return 2; printf 'k%s' "$k"; }

ledger() {
  local cmd="${1:-show}"; shift || true
  case "$cmd" in
    start)
      ledger-int "${1:-}" || return 2
      local title; title=$(printf '%s' "${2:-}" | tr -d '\000-\037\177' | cut -c1-120)
      ledger-update '.running = ([.running[] | select(.job != $n)] + [{job: $n, title: $t}] | sort_by(.job))
        | .lifetime_jobs = ([.lifetime_jobs, $n] | max)' --argjson n "$1" --arg t "$title" ;;
    finish)
      ledger-int "${1:-}" || return 2
      ledger-update '.running |= map(select(.job != $n))' --argjson n "$1" ;;
    park)
      local k; k=$(ledger-kid "${1:-}") || return 2
      ledger-update 'if (.parked_ids | index($k)) then . else .parked_ids += [$k] | .parked += 1 end' --arg k "$k" ;;
    unpark)
      local k; k=$(ledger-kid "${1:-}") || return 2
      ledger-update 'if (.parked_ids | index($k)) then .parked_ids -= [$k] | .parked -= 1 else . end' --arg k "$k" ;;
    set-parked)
      ledger-int "${1:-}" || return 2
      ledger-update '.parked = $n' --argjson n "$1" ;;
    show)
      jq -c . "$(ledger-file)" 2>/dev/null || printf '{}\n' ;;
    *) echo "usage: ledger.sh start <n> <title> | finish <n> | park <k> | unpark <k> | set-parked <n> | show" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  ledger "$@"
fi
