#!/usr/bin/env bash
# Job ledger writer for the HUD "jobs" section (schema v3).
#
#   ledger.sh start <n> <title> [--context <abs-path>]   job r<n> started (lifetime_jobs = highest n ever)
#       start also takes [--started-at HH:MM] [--prompt-file <abs-path> | --prompt-stdin] [--agent <type[/model]>] [--flags a,b]
#       (flags: autopilot, needs-confirmation, detached); --prompt-stdin saves stdin as <ledger dir>/ccxp-prompts/<n>.md (mode 600)
#   ledger.sh finish <n>                                 job r<n> no longer running (drops its saved prompt copy)
#   ledger.sh reconcile --alive <n,n,...|->              print running rows NOT in the alive list, one TSV line each:
#                                 job title context prompt started_at agent flags resumed prompt_check started_on   ("-" = empty / no prompt file)
#   ledger.sh set-started <n> HH:MM   set a running row's start time (24h, validated)
#   ledger.sh resumed <n>         count a restart of running row r<n> (keeps its number)
#   ledger.sh park <k> [--context <abs-path>] [--title <t>]   park id k<k> (k5, K5 or 5 all mean k5); re-park updates
#   ledger.sh unpark <k>
#   ledger.sh set-parked <n>      DEPRECATED no-op (the parked count is the array length)
#   ledger.sh next add "<text>" [--context <abs-path>] [--ref n<k>]   open a "Next:" item; prints its ref
#                                 (auto-increments the n counter; --ref picks one, error if taken)
#   ledger.sh next done <ref>     close it (n3, N3 or 3; legacy i3/a2 refs work too); kept in "done" (last 20)
#   ledger.sh next set <ref> [--text <t>] [--context <abs-path>]   edit an open item
#   ledger.sh set-counter <n|s|k> <value>   set a ref counter exactly (to initialise it)
#   ledger.sh render              print Next / Running / Parked as the reply sections + a "Ledger:" line
#   ledger.sh reply [--tldr "<text>"]   the reply tail, plain text, to paste verbatim: Running (r<n> [HH:MM] title, context path),
#                                 Next: (n<k>, context path), Parked: (k<n>, context path), then "Ledger: <abs path of ccxp-ledger.md>"
#   ledger.sh check <replyfile|->   compare the r<n>/n<k>/k<n> refs that open a line of a draft reply with the ledger;
#                                 prints each MISSING (in ledger, not in reply) / EXTRA (in reply, not in ledger) ref, and each
#                                 NO-CONTEXT ref (a running, next or parked item with an empty context); exit 1 on any
#   context is required for every running, next and parked item: reply shows "context: MISSING", next add / park warn on stderr
#   ledger.sh input|action add|done   DEPRECATED aliases of next add|done
#   ledger.sh ref next <n|s|k>    allocate and print the next ref (for s and k)
#   ledger.sh ref bump <ref>      raise that prefix's counter to at least this number (n22)
#   ledger.sh show [--brief]      print the ledger JSON, or one summary line (never fails)
#
# File: ${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-ledger.json}
# {"schema":3,"updated_at","next_job","lifetime_jobs",
#  "running":[{"job","title","context","prompt","agent","flags","resumed","started_at"}],  (started_at = HH:MM local;
#                prompt = abs path of the saved job prompt, "" = not resumable; resumed = restart count)
#  "next":[{"ref","text","context","added_at"}],
#  "done":[{"ref","text","context","closed_at"}],           (closed Next items, newest last, max 20)
#  "parked":[{"id","context","title"?}],
#  "ref_counters":{"n","s","k"}}
# The JSON is the source of truth: compose replies from `render`/`show`, change it only via this script.
# context = absolute path of a context file ("" when none); this script only stores it.
# After every write, ccxp-ledger.md (same dir, same base name) is re-rendered: running, Next and
# parked items, each with a file:// link and the plain absolute context path (cmd-clickable in a terminal).
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
  local f out; f=$(ledger-file)
  out=$(jq -c 'if type == "object" then . else {} end
    | {schema: 3,
       updated_at: (.updated_at | strings // ""),
       lifetime_jobs: (.lifetime_jobs | numbers // 0),
       running: [(.running // [])[] | select(type == "object")
                 | {job: (.job | numbers // 0), title: (.title | strings // ""), context: (.context | strings // ""),
                  prompt: (.prompt | strings // ""), sha: (.sha | strings // ""), started_on: (.started_on | strings // ""), agent: (.agent | strings // ""), flags: (.flags | strings // ""),
                  resumed: (.resumed | numbers // 0), started_at: (.started_at | strings // "")}],
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
    "$f" 2>/dev/null) || out=""
  printf '%s' "${out:-$LEDGER_EMPTY}"
}

# Render the markdown view of a normalized ledger ($1 = JSON) into ccxp-ledger.md. Best-effort.
ledger-render() {
  local md tmp; md=$(ledger-md-file)
  tmp=$(mktemp "$md.XXXXXX") || return 0
  if printf '%s' "$1" | jq -r --arg md "$md" '
      def enc: split("/") | map(@uri) | join("/");
      def item($head): "- " + $head + "\n  context: "
        + (if .context != "" then "[context](file://" + (.context | enc) + ")\n  " + .context else "(none)" end);
      def sect($name; $items): "## " + $name + " (" + ($items | length | tostring) + ")\n"
        + (if ($items | length) == 0 then "- none" else ($items | join("\n")) end) + "\n";
      "# CCXP ledger\n\nUpdated: " + (.updated_at // "") + "\n\nLedger: [ledger](file://" + ($md | enc) + ") " + $md + "\n\n"
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
  cp -p "$f" "$f.bak-$(date -u +%Y%m%dT%H%M%SZ)-$$" 2>/dev/null \
    || { echo "ledger: cannot back up $f; not migrating" >&2; return 1; }
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
  if jq -e '(.schema | numbers // 0) > 3' "$f" >/dev/null 2>&1; then
    echo "ledger: $f has a newer schema than this script (3); not writing" >&2; return 1
  fi
  cur=$(ledger-read)
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if printf '%s' "$cur" | jq -c "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$filter | .schema = 3 | .updated_at = \$now | .next_job = (.lifetime_jobs + 1)" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null
    LEDGER_LAST=$(<"$tmp")
    ledger-migrate-backup "$f" || { unlink "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$f"
    ledger-render "$LEDGER_LAST"
  else
    unlink "$tmp" 2>/dev/null
    return 1
  fi
}

ledger-int() {
  [[ "$1" =~ ^[0-9]{1,9}$ ]] || { echo "ledger: not a number (1-9 digits): $1" >&2; return 2; }
}

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
  PF=""; AGT=""; FLG=""; HAVE_PF=false; HAVE_AGT=false; HAVE_FLG=false; PSTDIN=false; SAT=""; HAVE_SAT=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) [[ $# -ge 2 ]] || { echo "ledger: --context needs a path" >&2; return 2; }
        CTX=$(ledger-ctx "$2") || return 2; HAVE_CTX=true; shift 2 ;;
      --text) [[ $# -ge 2 ]] || { echo "ledger: --text needs a value" >&2; return 2; }
        TXT=$(ledger-clip "$2" 300); HAVE_TXT=true; shift 2 ;;
      --ref) [[ $# -ge 2 ]] || { echo "ledger: --ref needs a value" >&2; return 2; }
        [[ "$2" =~ ^[nN][0-9]{1,9}$ ]] || { echo "ledger: --ref must look like n12: $2" >&2; return 2; }
        REF="n$((10#${2:1}))"; shift 2 ;;
      --prompt-file) [[ $# -ge 2 ]] || { echo "ledger: --prompt-file needs a path" >&2; return 2; }
        PF=$(ledger-ctx "$2") || return 2; HAVE_PF=true; shift 2 ;;
      --prompt-stdin) PSTDIN=true; shift ;;
      --started-at) [[ $# -ge 2 ]] || { echo "ledger: --started-at needs HH:MM" >&2; return 2; }
        ledger-hm "$2" || return 2; SAT="$2"; HAVE_SAT=true; shift 2 ;;
      --agent) [[ $# -ge 2 ]] || { echo "ledger: --agent needs a value" >&2; return 2; }
        AGT=$(ledger-clip "$2" 80); HAVE_AGT=true; shift 2 ;;
      --flags) [[ $# -ge 2 ]] || { echo "ledger: --flags needs a value" >&2; return 2; }
        [[ -z "$2" || "$2" =~ ^(autopilot|needs-confirmation|detached)(,(autopilot|needs-confirmation|detached))*$ ]] \
          || { echo "ledger: --flags takes autopilot, needs-confirmation, detached (comma list): $2" >&2; return 2; }
        FLG="$2"; HAVE_FLG=true; shift 2 ;;
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
  [[ "$r" =~ ^[sSkK] ]] && { echo "ledger: next refs are n<k> (or legacy i/a): $r" >&2; return 2; }
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

# Reply tail in the user-mandated order (Running, Next, Parked, Ledger line), plain text, no markdown.
# $1 optional TL;DR text (printed first).
ledger-reply() {
  local md; md=$(ledger-md-file)
  [[ "$md" == /* ]] || md="$(pwd)/$md"
  ledger-read | jq -r --arg md "$md" --arg tldr "${1:-}" '
    def ctx: if .context != "" then "\n  " + .context else "\n  context: MISSING" end;
    def sect($name; $rows): if ($rows | length) == 0 then empty else $name + "\n" + ($rows | join("\n")) + "\n" end;
    (if $tldr != "" then "TL;DR: " + $tldr + "\n" else empty end),
    sect("Running:"; [.running[] | "r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)" + ctx]),
    sect("Next:"; [.next[] | "\(.ref) \(.text)" + ctx]),
    sect("Parked:"; [.parked[] | .id + (if .title then " " + .title else "" end) + ctx]),
    "Ledger: " + $md'
}

# $1 file or "-" (stdin). Refs count only when they open a line (after list/bold markers), so prose is ignored.
ledger-check() {
  local src="${1:-}" draft want got missing extra rc=0
  [[ -n "$src" ]] || { echo "usage: ledger.sh check <replyfile|->" >&2; return 2; }
  if [[ "$src" == "-" ]]; then draft=$(cat); else [[ -r "$src" ]] || { echo "ledger: cannot read $src" >&2; return 2; }; draft=$(<"$src"); fi
  want=$(ledger-read | jq -r '[(.running[] | "r\(.job)"), (.next[] | .ref), (.parked[] | .id)] | .[]' | sort -u)
  got=$(printf '%s\n' "$draft" | sed -nE 's/^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*[*_]*([rRnNkK][0-9]{1,9})([^0-9A-Za-z].*)?$/\2/p' \
    | tr 'RNK' 'rnk' | sed -E 's/^([rnk])0+([0-9])/\1\2/' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
  extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
  [[ -z "$missing" ]] || { while read -r r; do echo "MISSING $r (in ledger, not in reply)"; done <<<"$missing"; rc=1; }
  local nocx; nocx=$(ledger-read | jq -r '[(.running[] | select(.context == "") | "r\(.job)"), (.next[] | select(.context == "") | .ref),
    (.parked[] | select(.context == "") | .id)] | .[]')
  [[ -z "$nocx" ]] || { while read -r r; do echo "NO-CONTEXT $r (context file is required)"; done <<<"$nocx"; rc=1; }
  [[ -z "$extra" ]] || { while read -r r; do echo "EXTRA $r (in reply, not in ledger)"; done <<<"$extra"; rc=1; }
  return $rc
}

ledger-hm() { [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ledger: time must be HH:MM (24h): ${1:-}" >&2; return 2; }; }

ledger-sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1; }

ledger-prompt-dir() { printf '%s/ccxp-prompts' "$(dirname "$(ledger-file)")"; }

# Save stdin as the job prompt for job $1; prints the path. Refuses text that looks like a credential.
ledger-save-prompt() {
  local d f text; d=$(ledger-prompt-dir); f="$d/$1.md"
  text=$(head -c 200000)
  [[ -n "$text" ]] || { echo "ledger: empty prompt on stdin" >&2; return 2; }
  if printf '%s' "$text" | grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY'; then
    echo "ledger: prompt looks like it holds a credential; not saved" >&2; return 2
  fi
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  ( umask 077; printf '%s\n' "$text" > "$f" ) || return 1
  chmod 600 "$f" 2>/dev/null
  printf '%s' "$f"
}

ledger() {
  local cmd="${1:-show}"; shift || true
  case "$cmd" in
    start)
      ledger-args "$@" || return 2
      ledger-int "${POS[0]:-}" || return 2
      local title; title=$(printf '%s' "${POS[1]:-}" | tr -d '\000-\037\177' | cut -c1-120)
      if [[ "$PSTDIN" == true ]]; then
        PF=$(ledger-save-prompt "$((10#${POS[0]}))") || return 2; HAVE_PF=true
      fi
      local SHA=""; [[ "$HAVE_PF" == true && -f "$PF" ]] && SHA=$(ledger-sha "$PF")
      ledger-update '(.running | map(select(.job == $n)) | .[0]) as $old
        | .running = ([.running[] | select(.job != $n)]
                      + [{job: $n, title: $t, context: (if $hc then $c else ($old.context // "") end),
                          prompt: (if $hp then $p else ($old.prompt // "") end),
                          sha: (if $hp then $sha else ($old.sha // "") end),
                          started_on: (if ($old.started_on // "") != "" then $old.started_on else $day end),
                          agent: (if $ha then $a else ($old.agent // "") end),
                          flags: (if $hf then $f else ($old.flags // "") end),
                          resumed: ($old.resumed // 0),
                          started_at: (if $hs then $s elif ($old.started_at // "") != "" then $old.started_at else $hm end)}] | sort_by(.job))
        | .lifetime_jobs = ([.lifetime_jobs, $n] | max)' \
        --argjson n "$((10#${POS[0]}))" --arg t "$title" --arg c "$CTX" --argjson hc "$HAVE_CTX" --arg hm "$(date +%H:%M)" --arg s "$SAT" --argjson hs "$HAVE_SAT" --arg day "$(date +%F)" --arg sha "$SHA" \
        --arg p "$PF" --argjson hp "$HAVE_PF" --arg a "$AGT" --argjson ha "$HAVE_AGT" --arg f "$FLG" --argjson hf "$HAVE_FLG" ;;
    finish)
      ledger-int "${1:-}" || return 2
      local pf; pf="$(ledger-prompt-dir)/$((10#$1)).md"
      ledger-update '.running |= map(select(.job != $n))' --argjson n "$((10#$1))" || return 1
      [[ -f "$pf" ]] && unlink "$pf" 2>/dev/null
      return 0 ;;
    reconcile)
      local alive="" have=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --alive) [[ $# -ge 2 ]] || { echo "ledger: --alive needs a list (or -)" >&2; return 2; }
            alive="$2"; have=true; shift 2 ;;
          *) echo "usage: ledger.sh reconcile --alive <n,n,...|->" >&2; return 2 ;;
        esac
      done
      [[ "$have" == true ]] || { echo "usage: ledger.sh reconcile --alive <n,n,...|->  (the alive list is required, may be empty)" >&2; return 2; }
      [[ "$alive" == "-" ]] && alive=$(cat)
      alive=$(printf '%s' "$alive" | tr ',\n\t' '   ')
      local a ids=""
      for a in $alive; do
        a="${a#[#r]}"
        [[ "$a" =~ ^[0-9]{1,9}$ ]] || { echo "ledger: bad alive job number: $a" >&2; return 2; }
        ids+="$((10#$a)),"
      done
      local job title ctx prompt started agent flags resumed sha on check
      while IFS=$'\t' read -r job title ctx prompt started agent flags resumed sha on; do
        [[ -n "$job" ]] || continue
        check="-"
        [[ "$prompt" != "-" && ! -f "$prompt" ]] && prompt="-"
        if [[ "$prompt" != "-" ]]; then
          if [[ "$sha" == "-" ]]; then check="unknown"
          elif [[ "$(ledger-sha "$prompt")" == "$sha" ]]; then check="ok"; else check="changed"; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "$title" "$ctx" "$prompt" "$started" "$agent" "$flags" "$resumed" "$check" "$on"
      done < <(ledger-read | jq -r --argjson alive "[${ids%,}]" '
        .running[] | select(.job as $j | ($alive | index($j)) == null)
        | [.job, .title, .context, .prompt, .started_at, .agent, .flags, .resumed, .sha, .started_on]
        | map(if . == "" then "-" else tostring end) | join("\t")') ;;
    set-started)
      ledger-int "${1:-}" || return 2
      ledger-hm "${2:-}" || return 2
      ledger-update 'if (.running | map(.job) | index($n)) then .running |= map(if .job == $n then .started_at = $s else . end)
                     else error("no such running job") end' --argjson n "$((10#$1))" --arg s "$2" \
        || { echo "ledger: no running job r$1" >&2; return 1; } ;;
    resumed)
      ledger-int "${1:-}" || return 2
      ledger-update 'if (.running | map(.job) | index($n)) then .running |= map(if .job == $n then .resumed += 1 else . end)
                     else error("no such running job") end' --argjson n "$((10#$1))" \
        || { echo "ledger: no running job r$1" >&2; return 1; } ;;
    park)
      ledger-args "$@" || return 2
      local k extra; k=$(ledger-kid "${POS[0]:-}") || return 2
      extra=$(jq -nc --arg c "$CTX" --arg t "$TTL" --argjson hc "$HAVE_CTX" --argjson ht "$HAVE_TTL" \
        '(if $hc then {context: $c} else {} end) + (if $ht and $t != "" then {title: $t} else {} end)')
      ledger-update '(if (.parked | map(.id) | index($k)) then .parked |= map(if .id == $k then . + $x else . end)
                      else .parked += [{id: $k, context: ""} + $x] end)
        | .ref_counters.k = ([.ref_counters.k, ($k[1:] | tonumber)] | max)' --arg k "$k" --argjson x "$extra" || return 1
      [[ "$(jq -r --arg k "$k" '.parked[] | select(.id == $k) | .context' <<<"$LEDGER_LAST")" != "" ]] \
        || echo "ledger: warning: $k has no context (pass --context <abs path>)" >&2 ;;
    unpark)
      local k; k=$(ledger-kid "${1:-}") || return 2
      ledger-update '.parked |= map(select(.id != $k))' --arg k "$k" ;;
    set-parked)
      ledger-int "${1:-}" || return 2
      echo "ledger: set-parked is deprecated and does nothing (the parked count is the length of the parked array)" >&2 ;;
    set-counter)
      [[ "${1:-}" =~ ^[nsk]$ ]] || { echo "ledger: set-counter prefix must be n, s or k: ${1:-}" >&2; return 2; }
      ledger-int "${2:-}" || return 2
      ledger-update '.ref_counters[$p] = $v' --arg p "$1" --argjson v "$((10#$2))" ;;
    render) ledger-render-text ;;
    reply)
      case "${1:-}" in
        "") ledger-reply "" ;;
        --tldr) [[ $# -ge 2 ]] || { echo "ledger: --tldr needs text" >&2; return 2; }
          ledger-reply "$(ledger-clip "$2" 300)" ;;
        *) echo "usage: ledger.sh reply [--tldr <text>]" >&2; return 2 ;;
      esac ;;
    check) ledger-check "${1:-}" ;;
    next | input | action) case "${1:-}" in
        add) shift; ledger-args "$@" || return 2
          [[ -n "$CTX" ]] || echo "ledger: warning: next add without --context (every item needs a context file)" >&2
          ledger-add "${POS[0]:-}" "$CTX" "$REF" ;;
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
    *) echo "usage: ledger.sh start <n> <title> | finish <n> | reconcile --alive <list> | resumed <n> | set-started <n> HH:MM | park <k> | unpark <k> | next add|done|set | set-counter <n|s|k> <v> | ref next|bump | render | reply [--tldr t] | check <file|-> | show [--brief]" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  ledger "$@"
fi
