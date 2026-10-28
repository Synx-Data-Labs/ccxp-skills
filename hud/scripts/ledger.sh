#!/usr/bin/env bash
# Job ledger writer for the HUD "jobs" section.
#
#   ledger.sh start <n> <title>   job r<n> started (lifetime_jobs = highest n ever)
#   ledger.sh finish <n>          job r<n> no longer running
#   ledger.sh park <k>            park id k<k> (k5, K5 or 5 all mean k5)
#   ledger.sh unpark <k>
#   ledger.sh set-parked <n>      overwrite the parked count (ids kept as-is)
#   ledger.sh input add "<text>"  open "Needs input" item; prints its ref (i<n>)
#   ledger.sh input done <ref>    close it (i3, I3 or 3)
#   ledger.sh action add "<text>" open "Needs your action" item; prints its ref (a<n>)
#   ledger.sh action done <ref>
#   ledger.sh ref next <i|a|s|k>  allocate and print the next ref (for s and k)
#   ledger.sh ref bump <ref>      raise that prefix's counter to at least this number
#   ledger.sh show [--brief]      print the ledger JSON, or one summary line (never fails)
#
# File: ${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}
# {"updated_at","next_job","lifetime_jobs","parked","parked_ids":[],"running":[{"job","title"}],
#  "inputs":[{"ref","text","added_at"}],"actions":[...],"ref_counters":{"i","a","s","k"}}
# ref_counters = highest number ever used per prefix, so refs are never reused after a restart.
# Old files without the newer fields keep working (defaults are filled in on read).
# Text is cut to 300 chars, control chars stripped.
# Writes are atomic (temp file + mv); a missing or corrupt file starts fresh.
# Not locked: concurrent writers are last-write-wins. Titles only, NEVER secrets.

ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}"
}

LEDGER_EMPTY='{"lifetime_jobs":0,"parked":0,"parked_ids":[],"running":[],"inputs":[],"actions":[],"ref_counters":{"i":0,"a":0,"s":0,"k":0}}'

# Current ledger, normalized; defaults when missing/corrupt.
ledger-read() {
  local f; f=$(ledger-file)
  jq -c 'if type == "object" then . else {} end
    | {lifetime_jobs: (.lifetime_jobs | numbers // 0),
       parked: (.parked | numbers // 0),
       parked_ids: [(.parked_ids // [])[] | strings],
       running: [(.running // [])[] | select(type == "object")
                 | {job: (.job | numbers // 0), title: (.title | strings // "")}],
       inputs: [(.inputs // [])[] | select(type == "object" and (.ref | strings))
                | {ref, text: (.text | strings // ""), added_at: (.added_at | strings // "")}],
       actions: [(.actions // [])[] | select(type == "object" and (.ref | strings))
                 | {ref, text: (.text | strings // ""), added_at: (.added_at | strings // "")}],
       ref_counters: ((.ref_counters | if type == "object" then . else {} end) as $c
                      | {i: ($c.i | numbers // 0), a: ($c.a | numbers // 0),
                         s: ($c.s | numbers // 0), k: ($c.k | numbers // 0)})}' \
    "$f" 2>/dev/null || printf '%s' "$LEDGER_EMPTY"
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
    LEDGER_LAST=$(<"$tmp")
    mv "$tmp" "$f"
  else
    unlink "$tmp" 2>/dev/null
    return 1
  fi
}

ledger-int() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "ledger: not a number: $1" >&2; return 2; }; }

ledger-kid() { local k="${1#[kK]}"; ledger-int "$k" || return 2; printf 'k%s' "$k"; }

ledger-text() { printf '%s' "${1:-}" | tr -d '\000-\037\177' | cut -c1-300; }

ledger-prefix() { [[ "${1:-}" =~ ^[iask]$ ]] || { echo "ledger: prefix must be i, a, s or k: ${1:-}" >&2; return 2; }; }

# i3 / I3 / 3 -> 3
ledger-refnum() { local n="${1:-}"; n="${n#[iaskIASK]}"; ledger-int "$n" || return 2; printf '%s' "$n"; }

# $1 list field (inputs|actions), $2 prefix, $3 text; prints the new ref
ledger-add() {
  local text; text=$(ledger-text "${3:-}")
  [[ -n "$text" ]] || { echo "ledger: empty text" >&2; return 2; }
  ledger-update '.ref_counters[$p] += 1
    | .[$f] += [{ref: ($p + (.ref_counters[$p] | tostring)), text: $t, added_at: $now}]' \
    --arg f "$1" --arg p "$2" --arg t "$text" || return 1
  jq -r --arg p "$2" '$p + (.ref_counters[$p] | tostring)' <<<"$LEDGER_LAST"
}

ledger-done() {
  local n; n=$(ledger-refnum "${3:-}") || return 2
  ledger-update '.[$f] |= map(select(.ref != $r))' --arg f "$1" --arg r "$2$n"
}

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
      ledger-update '(if (.parked_ids | index($k)) then . else .parked_ids += [$k] | .parked += 1 end)
        | .ref_counters.k = ([.ref_counters.k, ($k[1:] | tonumber)] | max)' --arg k "$k" ;;
    unpark)
      local k; k=$(ledger-kid "${1:-}") || return 2
      ledger-update 'if (.parked_ids | index($k)) then .parked_ids -= [$k] | .parked -= 1 else . end' --arg k "$k" ;;
    set-parked)
      ledger-int "${1:-}" || return 2
      ledger-update '.parked = $n' --argjson n "$1" ;;
    input) case "${1:-}" in
        add) ledger-add inputs i "${2:-}" ;;
        done) ledger-done inputs i "${2:-}" ;;
        *) echo "usage: ledger.sh input add <text> | input done <ref>" >&2; return 2 ;;
      esac ;;
    action) case "${1:-}" in
        add) ledger-add actions a "${2:-}" ;;
        done) ledger-done actions a "${2:-}" ;;
        *) echo "usage: ledger.sh action add <text> | action done <ref>" >&2; return 2 ;;
      esac ;;
    ref) case "${1:-}" in
        next)
          ledger-prefix "${2:-}" || return 2
          ledger-update '.ref_counters[$p] += 1' --arg p "$2" || return 1
          jq -r --arg p "$2" '$p + (.ref_counters[$p] | tostring)' <<<"$LEDGER_LAST" ;;
        bump)
          local r p n; r=$(printf '%s' "${2:-}" | tr 'IASK' 'iask'); p="${r:0:1}"
          ledger-prefix "$p" || return 2
          n=$(ledger-refnum "$r") || return 2
          ledger-update '.ref_counters[$p] = ([.ref_counters[$p], $n] | max)' --arg p "$p" --argjson n "$n" ;;
        *) echo "usage: ledger.sh ref next <i|a|s|k> | ref bump <ref>" >&2; return 2 ;;
      esac ;;
    show)
      if [[ "${1:-}" == "--brief" ]]; then
        ledger-read | jq -r '"running=\(.running | length) parked=\(.parked) inputs_open=\(.inputs | length) actions_open=\(.actions | length)"'
      else
        jq -c '. + {inputs: (.inputs // []), actions: (.actions // []),
                    ref_counters: (.ref_counters // {i:0,a:0,s:0,k:0})}
               | . + {inputs_open: (.inputs | length), actions_open: (.actions | length)}' \
          "$(ledger-file)" 2>/dev/null || printf '{}\n'
      fi ;;
    *) echo "usage: ledger.sh start <n> <title> | finish <n> | park <k> | unpark <k> | set-parked <n> | input add|done | action add|done | ref next|bump | show [--brief]" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  ledger "$@"
fi
