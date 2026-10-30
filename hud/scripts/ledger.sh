#!/usr/bin/env bash
# Job ledger writer for the HUD "jobs" section (schema v3).
#
#   ledger.sh start <n> <title> [--context <abs-path>]   job r<n> started (lifetime_jobs = highest n ever)
#   ledger.sh finish <n>                                 job r<n> no longer running
#   ledger.sh park <k> [--context <abs-path>] [--title <t>]   park id k<k> (k5, K5 or 5 all mean k5); re-park updates
#   ledger.sh unpark <k>
#   ledger.sh set-parked <n>      DEPRECATED no-op (the parked count is the array length)
#   ledger.sh next add "<text>" [--context <abs-path>] [--ref n<k>]   open a "Next:" item; prints its ref
#                                 (auto-increments the n counter; --ref picks one, error if taken)
#   ledger.sh next done <ref>     close it (n3, N3 or 3; legacy i3/a2 refs work too); kept in "done" (last 20)
#   ledger.sh next set <ref> [--text <t>] [--context <abs-path>]   edit an open item
#   ledger.sh set-counter <n|s|k> <value>   set a ref counter exactly (to initialise it)
#   ledger.sh render              print Next / Running / Parked as the reply sections + a "Ledger:" line
#   ledger.sh input|action add|done   DEPRECATED aliases of next add|done
#   ledger.sh ref next <n|s|k>    allocate and print the next ref (for s and k)
#   ledger.sh ref bump <ref>      raise that prefix's counter to at least this number (n22)
#   ledger.sh show [--brief]      print the ledger JSON, or one summary line (never fails)
#
# File: ${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}
# {"schema":3,"updated_at","next_job","lifetime_jobs",
#  "running":[{"job","title","context","started_at"}],     (started_at = HH:MM local)
#  "next":[{"ref","text","context","added_at"}],
#  "done":[{"ref","text","context","closed_at"}],           (closed Next items, newest last, max 20)
#  "parked":[{"id","context","title"?}],
#  "ref_counters":{"n","s","k"}}
# The JSON is the source of truth: compose replies from `render`/`show`, change it only via this script.
# context = absolute path of a context file ("" when none); this script only stores it.
# After every write, ccxp-ledger.md (same dir, same base name) is re-rendered: running, Next and
# parked items, each context path on its own line so a terminal makes it cmd-clickable.
# Migration (first write onto an older file): the old file is copied to
# <file>.bak-<UTC timestamp>-<pid>, parked_ids become parked items with empty context, inputs/actions
# merge into next (legacy refs kept), the parked count and i/a counters are dropped. A legacy
# parked count larger than the ids it came with is reported on stderr (no placeholders invented).
# Text is cut to 300 chars, control chars stripped.
# Writes are atomic (temp file + mv); a missing or corrupt file starts fresh.
# Not locked: concurrent writers are last-write-wins. Titles and paths only, NEVER secrets.

ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}"
}

ledger-md-file() {
  local f; f=$(ledger-file)
  printf '%s.md' "${f%.json}"
}

LEDGER_EMPTY='{"schema":3,"lifetime_jobs":0,"running":[],"next":[],"parked":[],"ref_counters":{"n":0,"s":0,"k":0}}'

# Current ledger, normalized to v3; defaults when missing/corrupt. Reads old shapes too.
ledger-read() {
  local f; f=$(ledger-file)
  jq -c 'if type == "object" then . else {} end
    | {schema: 3,
       updated_at: (.updated_at | strings // ""),
       lifetime_jobs: (.lifetime_jobs | numbers // 0),
       running: [(.running // [])[] | select(type == "object")
                 | {job: (.job | numbers // 0), title: (.title | strings // ""), context: (.context | strings // ""),
                  started_at: (.started_at | strings // "")}],
       next: [((.next // []) + (.inputs // []) + (.actions // []))[]
              | select(type == "object" and (.ref | strings))
              | {ref, text: (.text | strings // ""), context: (.context | strings // ""), added_at: (.added_at | strings // "")}],
       done: [(.done // [])[] | select(type == "object" and (.ref | strings))
              | {ref, text: (.text | strings // ""), context: (.context | strings // ""), closed_at: (.closed_at | strings // "")}],
       parked: [(if (.parked | type) == "array" then .parked else [(.parked_ids // [])[]] end)[]
                | (if type == "string" then {id: .} elif type == "object" then . else {} end)
                | select(.id | strings)
                | {id, context: (.context | strings // "")} + (if (.title | strings // "") != "" then {title} else {} end)],
       ref_counters: ((.ref_counters | if type == "object" then . else {} end) as $c
                      | {n: ($c.n | numbers // 0), s: ($c.s | numbers // 0), k: ($c.k | numbers // 0)})}' \
    "$f" 2>/dev/null || printf '%s' "$LEDGER_EMPTY"
}

# Render the markdown view of a normalized ledger ($1 = JSON) into ccxp-ledger.md. Best-effort.
ledger-render() {
  local md tmp; md=$(ledger-md-file)
  tmp=$(mktemp "$md.XXXXXX") || return 0
  if printf '%s' "$1" | jq -r '
      def item($head): "- " + $head + (if .context != "" then "\n  " + .context else "" end);
      def sect($name; $items): "## " + $name + " (" + ($items | length | tostring) + ")\n"
        + (if ($items | length) == 0 then "- none" else ($items | join("\n")) end) + "\n";
      "# CCXP ledger\n\nUpdated: " + (.updated_at // "") + "\n\n"
      + sect("Running"; [.running[] | item("r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)")]) + "\n"
      + sect("Next"; [.next[] | item("\(.ref) \(.text)")]) + "\n"
      + sect("Parked"; [.parked[] | item(.id + (if .title then " " + .title else "" end))])' > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$md" 2>/dev/null || unlink "$tmp" 2>/dev/null
  else
    unlink "$tmp" 2>/dev/null
  fi
  return 0
}

# Copy an existing pre-v3 (or unreadable) file aside before its first v3 write; report a legacy
# parked count that exceeds its ids.
ledger-migrate-backup() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  jq -e '.schema == 3' "$f" >/dev/null 2>&1 && return 0
  cp -p "$f" "$f.bak-$(date -u +%Y%m%dT%H%M%SZ)-$$" 2>/dev/null || true
  jq -r 'select(type == "object" and (.parked | type) == "number")
    | select(.parked > ((.parked_ids // []) | length))
    | "ledger: migrated old file: legacy parked count \(.parked) > \((.parked_ids // []) | length) ids; kept the ids only"' \
    "$f" >&2 2>/dev/null || true
}

# $1 jq filter over the normalized ledger; remaining args are jq args.
ledger-update() {
  local filter="$1"; shift
  local f tmp cur
  f=$(ledger-file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  cur=$(ledger-read)
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if printf '%s' "$cur" | jq -c "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$filter | .schema = 3 | .updated_at = \$now | .next_job = (.lifetime_jobs + 1)" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null
    LEDGER_LAST=$(<"$tmp")
    ledger-migrate-backup "$f"
    mv "$tmp" "$f"
    ledger-render "$LEDGER_LAST"
  else
    unlink "$tmp" 2>/dev/null
    return 1
  fi
}

ledger-int() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "ledger: not a number: $1" >&2; return 2; }; }

ledger-kid() { local k; k=$(ledger-refnum "${1:-}") || return 2; printf 'k%s' "$k"; }

# $1 text, $2 max chars
ledger-clip() { printf '%s' "${1:-}" | tr -d '\000-\037\177' | jq -Rrs --argjson n "${2:-300}" '.[0:$n]'; }

ledger-text() { ledger-clip "${1:-}" 300; }

# --context value: empty or an absolute path
ledger-ctx() {
  local c; c=$(ledger-clip "${1:-}" 500)
  [[ -z "$c" || "$c" == /* ]] || { echo "ledger: --context must be an absolute path: $c" >&2; return 2; }
  printf '%s' "$c"
}

# Split args into POS (positional), CTX/HAVE_CTX (--context) and TTL/HAVE_TTL (--title).
ledger-args() {
  POS=(); CTX=""; TTL=""; TXT=""; REF=""; HAVE_CTX=false; HAVE_TTL=false; HAVE_TXT=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) [[ $# -ge 2 ]] || { echo "ledger: --context needs a path" >&2; return 2; }
        CTX=$(ledger-ctx "$2") || return 2; HAVE_CTX=true; shift 2 ;;
      --text) [[ $# -ge 2 ]] || { echo "ledger: --text needs a value" >&2; return 2; }
        TXT=$(ledger-clip "$2" 300); HAVE_TXT=true; shift 2 ;;
      --ref) [[ $# -ge 2 ]] || { echo "ledger: --ref needs a value" >&2; return 2; }
        [[ "$2" =~ ^[nN][0-9]{1,9}$ ]] || { echo "ledger: --ref must look like n12: $2" >&2; return 2; }
        REF="n$((10#${2:1}))"; shift 2 ;;
      --title) [[ $# -ge 2 ]] || { echo "ledger: --title needs a value" >&2; return 2; }
        TTL=$(ledger-clip "$2" 120); HAVE_TTL=true; shift 2 ;;
      *) POS+=("$1"); shift ;;
    esac
  done
}

ledger-prefix() { [[ "${1:-}" =~ ^[nsk]$ ]] || { echo "ledger: prefix must be n, s or k: ${1:-}" >&2; return 2; }; }

# n3 / N3 / 3 -> 3 (legacy i3 / a3 also accepted)
ledger-refnum() {
  local n="${1:-}"; n="${n#[naskiNASKI]}"
  ledger-int "$n" || return 2
  [[ ${#n} -le 9 ]] || { echo "ledger: number too large: $n" >&2; return 2; }
  printf '%s' "$((10#$n))"
}

# $1 text, $2 context, $3 explicit ref (optional); prints the new n<k> ref
ledger-add() {
  local text; text=$(ledger-text "${1:-}")
  [[ -n "$text" ]] || { echo "ledger: empty text" >&2; return 2; }
  ledger-update '(if $r == "" then .ref_counters.n += 1
                  elif (.next | map(.ref) | index($r)) then error("ref taken")
                  else .ref_counters.n = ([.ref_counters.n, ($r[1:] | tonumber)] | max) end)
    | .next += [{ref: (if $r == "" then "n" + (.ref_counters.n | tostring) else $r end),
                 text: $t, context: $c, added_at: $now}]' \
    --arg t "$text" --arg c "${2:-}" --arg r "${3:-}" || { echo "ledger: could not add (ref already open?)" >&2; return 1; }
  jq -r '.next[-1].ref' <<<"$LEDGER_LAST"
}

# $1 ref: n3, N3, 3 (bare = n3), or a legacy i3 / a3
ledger-done() {
  local r="${1:-}" p="n" n
  n=$(ledger-refnum "$r") || return 2
  [[ "$r" =~ ^[iaIA] ]] && p=$(printf '%s' "${r:0:1}" | tr 'IA' 'ia')
  ledger-update '(.next | map(select(.ref == $r))) as $hit
    | .next |= map(select(.ref != $r))
    | .done = ((.done + ($hit | map({ref, text, context, closed_at: $now}))) | .[-20:])' --arg r "$p$n"
}

# $1 ref; uses TXT/CTX/HAVE_* from ledger-args
ledger-set() {
  local n x; n=$(ledger-refnum "${1:-}") || return 2
  [[ "$HAVE_TXT" == false || -n "$TXT" ]] || { echo "ledger: empty --text" >&2; return 2; }
  x=$(jq -nc --arg c "$CTX" --arg t "$TXT" --argjson hc "$HAVE_CTX" --argjson ht "$HAVE_TXT" \
    '(if $hc then {context: $c} else {} end) + (if $ht then {text: $t} else {} end)')
  ledger-update 'if (.next | map(.ref) | index($r)) then .next |= map(if .ref == $r then . + $x else . end)
                 else error("unknown ref") end' --arg r "n$n" --argjson x "$x" \
    || { echo "ledger: no open item n$n" >&2; return 1; }
}

# Reply sections as plain text, ready to paste: Next, Running, Parked (empty ones omitted), then the Ledger line.
ledger-render-text() {
  local md; md=$(ledger-md-file)
  [[ "$md" == /* ]] || md="$(pwd)/$md"
  ledger-read | jq -r --arg md "$md" '
    def ctx: if .context != "" then "\n  " + .context else "" end;
    def sect($name; $rows): if ($rows | length) == 0 then empty else $name + "\n" + ($rows | join("\n")) + "\n" end;
    sect("Next:"; [.next[] | "**\(.ref)** \(.text)" + ctx]),
    sect("Running:"; [.running[] | "r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)" + ctx]),
    sect("Parked:"; [.parked[] | "**\(.id)**" + (if .title then " " + .title else "" end) + ctx]),
    "Ledger: " + $md'
}

ledger() {
  local cmd="${1:-show}"; shift || true
  case "$cmd" in
    start)
      ledger-args "$@" || return 2
      ledger-int "${POS[0]:-}" || return 2
      local title; title=$(printf '%s' "${POS[1]:-}" | tr -d '\000-\037\177' | cut -c1-120)
      ledger-update '(.running | map(select(.job == $n)) | .[0]) as $old
        | .running = ([.running[] | select(.job != $n)]
                      + [{job: $n, title: $t, context: (if $hc then $c else ($old.context // "") end),
                          started_at: (if ($old.started_at // "") != "" then $old.started_at else $hm end)}] | sort_by(.job))
        | .lifetime_jobs = ([.lifetime_jobs, $n] | max)' \
        --argjson n "${POS[0]}" --arg t "$title" --arg c "$CTX" --argjson hc "$HAVE_CTX" --arg hm "$(date +%H:%M)" ;;
    finish)
      ledger-int "${1:-}" || return 2
      ledger-update '.running |= map(select(.job != $n))' --argjson n "$1" ;;
    park)
      ledger-args "$@" || return 2
      local k extra; k=$(ledger-kid "${POS[0]:-}") || return 2
      extra=$(jq -nc --arg c "$CTX" --arg t "$TTL" --argjson hc "$HAVE_CTX" --argjson ht "$HAVE_TTL" \
        '(if $hc then {context: $c} else {} end) + (if $ht and $t != "" then {title: $t} else {} end)')
      ledger-update '(if (.parked | map(.id) | index($k)) then .parked |= map(if .id == $k then . + $x else . end)
                      else .parked += [{id: $k, context: ""} + $x] end)
        | .ref_counters.k = ([.ref_counters.k, ($k[1:] | tonumber)] | max)' --arg k "$k" --argjson x "$extra" ;;
    unpark)
      local k; k=$(ledger-kid "${1:-}") || return 2
      ledger-update '.parked |= map(select(.id != $k))' --arg k "$k" ;;
    set-parked)
      ledger-int "${1:-}" || return 2
      echo "ledger: set-parked is deprecated and does nothing (the parked count is the length of the parked array)" >&2 ;;
    set-counter)
      [[ "${1:-}" =~ ^[nsk]$ ]] || { echo "ledger: set-counter prefix must be n, s or k: ${1:-}" >&2; return 2; }
      ledger-int "${2:-}" || return 2
      [[ ${#2} -le 9 ]] || { echo "ledger: number too large: $2" >&2; return 2; }
      ledger-update '.ref_counters[$p] = $v' --arg p "$1" --argjson v "$((10#$2))" ;;
    render) ledger-render-text ;;
    next | input | action) case "${1:-}" in
        add) shift; ledger-args "$@" || return 2; ledger-add "${POS[0]:-}" "$CTX" "$REF" ;;
        done) ledger-done "${2:-}" ;;
        set) shift; ledger-args "$@" || return 2; ledger-set "${POS[0]:-}" ;;
        *) echo "usage: ledger.sh next add <text> [--context <path>] [--ref nN] | next done <ref> | next set <ref> [--text t] [--context p]  (input/action: deprecated aliases)" >&2; return 2 ;;
      esac ;;
    ref) case "${1:-}" in
        next)
          [[ "${2:-}" =~ ^[nsk]$ ]] || { echo "ledger: ref next prefix must be n, s or k: ${2:-}" >&2; return 2; }
          ledger-update '.ref_counters[$p] += 1' --arg p "$2" || return 1
          jq -r --arg p "$2" '$p + (.ref_counters[$p] | tostring)' <<<"$LEDGER_LAST" ;;
        bump)
          local r p n; r=$(printf '%s' "${2:-}" | tr 'NSK' 'nsk'); p="${r:0:1}"
          ledger-prefix "$p" || return 2
          n=$(ledger-refnum "$r") || return 2
          ledger-update '.ref_counters[$p] = ([.ref_counters[$p], $n] | max)' --arg p "$p" --argjson n "$n" ;;
        *) echo "usage: ledger.sh ref next <n|s|k> | ref bump <ref>" >&2; return 2 ;;
      esac ;;
    show)
      if [[ "${1:-}" == "--brief" ]]; then
        ledger-read | jq -r '"running=\(.running | length) parked=\(.parked | length) next=\(.next | length)"'
      elif jq -e 'type == "object"' "$(ledger-file)" >/dev/null 2>&1; then
        ledger-read | jq -c '. + {next_job: (.lifetime_jobs + 1)}'
      else
        printf '{}\n'
      fi ;;
    *) echo "usage: ledger.sh start <n> <title> | finish <n> | park <k> | unpark <k> | next add|done|set | set-counter <n|s|k> <v> | ref next|bump | render | show [--brief]" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  ledger "$@"
fi
