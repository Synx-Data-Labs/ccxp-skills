#!/usr/bin/env bash
# Job ledger writer for the HUD "jobs" section (schema v3).
#
#   ledger.sh start <n> <title> [--context <abs-path>]   job r<n> started (lifetime_jobs = highest n ever)
#       start also takes [--started-at HH:MM] [--prompt-file <abs-path> | --prompt-stdin] [--agent <type[/model]>] [--flags a,b]
#       (flags: autopilot, needs-confirmation, detached); --prompt-stdin saves stdin as <ledger dir>/ccxp-prompts/<n>.md (mode 600)
#   ledger.sh finish <n>                                 job r<n> no longer running (drops its saved prompt copy)
#   ledger.sh stats [--json]      jobs started in the rolling last 24 h vs the lifetime average per day (read-only; see ledger-stats)
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
#   ledger.sh reply [--tldr "<text>"]   the reply tail, plain text, to paste verbatim: Running (r<n> [HH:MM] title, context file:// url),
#                                 Next: (n<k>, context file:// url), Parked: (k<n>, context file:// url), then "Ledger: <abs path of ccxp-ledger.md>"
#   ledger.sh check <replyfile|->   compare the r<n>/n<k>/k<n> refs that open a line of a draft reply with the ledger;
#                                 prints each MISSING (in ledger, not in reply) / EXTRA (in reply, not in ledger) ref, and each
#                                 NO-CONTEXT ref (a running, next or parked item with an empty context); exit 1 on any
#   context is required for every running, next and parked item: reply shows "context: MISSING", next add / park warn on stderr
#   ledger.sh input|action add|done   DEPRECATED aliases of next add|done
#   ledger.sh ref next <n|s|k>    allocate and print the next ref (for s and k)
#   ledger.sh ref bump <ref>      raise that prefix's counter to at least this number (n22)
#   ledger.sh show [--brief]      print the ledger JSON, or one summary line (never fails)
#   ledger.sh authz list [--json]            one TSV line per key: key value note quote date (unlisted keys read as no)
#   ledger.sh authz show [<key>]             <key>: yes|no (default no); no key: the effective list as JSON
#   ledger.sh authz set <key> yes|no [--quote "<owner words>"] [--note "<text>"]   owner's typed words only; yes requires --quote
#     (ccxp-authz.json next to the ledger, mode 600, atomic; once it exists reply/render add an "Authorization:" section)
#
# File: ${CCXP_LEDGER_FILE:-<profile>/ccxp-ledger.json}
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
# parked items, each with ONE plain file:// URL (url-encoded absolute context path; cmd-clickable in vscode/terminal).
# Migration (first write onto an older file): the old file is copied to
# <file>.bak-<UTC timestamp>-<pid>, parked_ids become parked items with empty context, inputs/actions
# merge into next (legacy refs kept), the parked count and i/a counters are dropped. A legacy
# parked count larger than the ids it came with is reported on stderr (no placeholders invented).
# Next text (`next add`, `next set --text`) and `reply --tldr` are control-char-stripped and REJECTED (exit 2, nothing
# written) over 400 chars, never cut; titles (120), --agent (80) and paths are still clipped.
# Writes are atomic (temp file + mv); a missing or corrupt file starts fresh.
# Start log: `start` of a NEW job also appends "<epoch>\t<n>" to <ledger dir>/ccxp-ledger-starts.log (same base
# name, `-starts.log`; mode 600, append-only, no titles). The first time the log is created while the ledger
# already counts jobs, a one-time seed line `#seed\t<first-job estimate epoch>\t<log began epoch>` goes first, so the
# lifetime average is meaningful from day one (the estimate is the oldest `<ledger>.bak-<UTC stamp>` migration
# backup, else the moment the log began). `stats` reads it; nothing else writes it.
# Not locked: concurrent writers are last-write-wins. Titles and paths only, NEVER secrets.


# Active profile dir (CCXP_PROFILE_DIR), see _session/profile-dir.sh.
# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
ledger-file() {
  printf '%s' "${CCXP_LEDGER_FILE:-${CCXP_PROFILE_DIR:-}/ccxp-ledger.json}"
}

ledger-md-file() {
  local f; f=$(ledger-file)
  printf '%s.md' "${f%.json}"
}

ledger-starts-file() {
  local f; f=$(ledger-file)
  printf '%s-starts.log' "${f%.json}"
}

# $1 fallback epoch -> best estimate of when the first job started: the oldest `<ledger>.bak-<UTC stamp>-<pid>`
# migration backup next to the ledger, else the fallback.
ledger-first-estimate() {
  local f b st first=""
  f=$(ledger-file)
  while IFS= read -r b; do
    st="${b##*.bak-}"; st="${st%%-*}"
    [[ "$st" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    st=$(printf '%s' "$st" | jq -R 'try (strptime("%Y%m%dT%H%M%SZ") | mktime) catch empty' 2>/dev/null) || continue
    [[ "$st" =~ ^[0-9]+$ ]] || continue
    [[ -z "$first" || "$st" -lt "$first" ]] && first="$st"
  done < <(compgen -G "$f.bak-*" 2>/dev/null)
  printf '%s' "${first:-$1}"
}

# $1 job number -> append its start to the start log unless the job is already running or already logged.
# Best-effort: a failure here never fails `start`.
ledger-log-start() {
  local n="$1" lf cur now first
  lf=$(ledger-starts-file); now="${LEDGER_NOW:-$(date +%s)}"
  cur=$(ledger-read)
  printf '%s' "$cur" | jq -e --argjson n "$n" '[.running[] | select(.job == $n)] | length == 0' >/dev/null 2>&1 || return 0
  [[ -f "$lf" ]] && grep -q -E "^[0-9]+"$'\t'"$n\$" "$lf" 2>/dev/null && return 0
  mkdir -p "$(dirname "$lf")" 2>/dev/null || return 0
  if [[ ! -f "$lf" ]]; then
    : > "$lf" 2>/dev/null && chmod 600 "$lf" 2>/dev/null || return 0
    if printf '%s' "$cur" | jq -e '.lifetime_jobs > 0' >/dev/null 2>&1; then
      first=$(ledger-first-estimate "$now")
      printf '#seed\t%s\t%s\n' "$first" "$now" >> "$lf" 2>/dev/null || true
    fi
  fi
  printf '%s\t%s\n' "$now" "$n" >> "$lf" 2>/dev/null || true
  return 0
}

# stats [--json]: jobs STARTED in the rolling last 24 h (now-86400 < ts <= now) against the lifetime average per day.
#   - the unit is the job START (the log has no finish times);
#   - lifetime jobs = the ledger's lifetime_jobs (highest number ever), or the logged starts when larger;
#   - lifetime days = max(1, (now - first job) / 86400); first job = the seed estimate, else the oldest logged start;
#   - trend compares jobs_24h with the average rounded to 1 decimal: up|down|flat (as autopilot stats);
#   - `approx` (the 24h count may be too low) when the log does not reach back over the whole window: no log yet,
#     or it began less than 24 h ago on top of a seed; `avg_approx` when the first-job time is an estimate (a seed
#     or no log). Nothing is printed for a ledger that has never counted a job. Never fails.
ledger-stats() {
  local json=0 lf now life out
  case "${1:-}" in --json) json=1 ;; '') ;; *) echo "usage: ledger.sh stats [--json]" >&2; return 2 ;; esac
  lf=$(ledger-starts-file); now="${LEDGER_NOW:-$(date +%s)}"
  life=$(ledger-read | jq '.lifetime_jobs' 2>/dev/null) || life=0
  [[ -f "$lf" ]] || lf=/dev/null
  out=$(jq -n -R -c --argjson now "$now" --argjson life "${life:-0}" --argjson est "$(ledger-first-estimate "$now")" '
    def r2: (. * 100 | round) / 100;
    [inputs | split("\t")] as $rows
    | ([$rows[] | select(.[0] == "#seed" and (.[1] | test("^[0-9]+$")) and (.[2] | test("^[0-9]+$"))) | {first: (.[1] | tonumber), began: (.[2] | tonumber)}] | .[0]) as $seed
    | [$rows[] | select((.[0] | test("^[0-9]+$")) and (.[0] | tonumber) <= $now) | (.[0] | tonumber)] as $t
    | ($now - 86400) as $cut
    | ([$life, ($t | length)] | max) as $lt
    | ([($seed.first // null), ($t | min)] | map(select(. != null)) | min // $est) as $first
    | ((($now - $first) / 86400) | if . < 1 then 1 else . end) as $days
    | ($lt / $days | r2) as $avg
    | ($t | map(select(. > $cut)) | length) as $n24
    | ((($t | length) == 0) or ($seed != null and $seed.began > $cut)) as $approx
    | select($lt > 0)
    | {approx: $approx, avg_approx: ($seed != null or ($t | length) == 0), jobs_24h: $n24, lifetime_jobs: $lt, lifetime_days: ($days | r2), avg_jobs_day: $avg,
       trend: (($avg * 10 | round) / 10 | if $n24 > . then "up" elif $n24 < . then "down" else "flat" end)}' "$lf" 2>/dev/null) || out=""
  [[ -n "$out" ]] || return 0
  if [[ $json == 1 ]]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | jq -r '"24h: \(if .approx then "~" else "" end)\(.jobs_24h) jobs started · lifetime \(.lifetime_jobs) jobs over \(.lifetime_days) days · average \(if .avg_approx then "~" else "" end)\(.avg_jobs_day)/day"'
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
  if printf '%s' "$1" | jq -r --arg md "$md" --argjson az "$(authz-effective-if-file)" '
      def enc: split("/") | map(@uri) | join("/");
      def item($head): "- " + $head + "\n  context: "
        + (if .context != "" then "file://" + (.context | enc) else "(none)" end);
      def sect($name; $items): "## " + $name + " (" + ($items | length | tostring) + ")\n"
        + (if ($items | length) == 0 then "- none" else ($items | join("\n")) end) + "\n";
      "# CCXP ledger\n\nUpdated: " + (.updated_at // "") + "\n\nLedger: file://" + ($md | enc) + "\n\n"
      + sect("Running"; [.running[] | item("r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)")]) + "\n"
      + sect("Next"; [.next[] | item("\(.ref) \(.text)")]) + "\n"
      + sect("Parked"; [.parked[] | item(.id + (if .title then " " + .title else "" end))])
      + (if ($az | length) == 0 then "" else "\n" + sect("Authorization"; [$az[] | "- " + .key + ": " + .value]) end)' > "$tmp" 2>/dev/null; then
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

# Sentence text (Next items, tldr): reject over 400 chars instead of cutting mid-sentence. $1 text, $2 label
ledger-text() { ledger-bounded "${1:-}" 400 "${2:-text}"; }

# --context value: empty or an absolute path
ledger-ctx() {
  local c; c=$(ledger-clip "${1:-}" 500)
  [[ -z "$c" || "$c" == /* ]] || { echo "ledger: --context must be an absolute path: $c" >&2; return 2; }
  printf '%s' "$c"
}

# Split args into POS (positional), CTX/HAVE_CTX (--context) and TTL/HAVE_TTL (--title).
ledger-args() {
  POS=(); CTX=""; TTL=""; TXT=""; REF=""; HAVE_CTX=false; HAVE_TTL=false; HAVE_TXT=false
  QUOTE=""; NOTE=""; SCOPE=""; SRC=""; HAVE_SCOPE=false; ALL=false; JSON=false
  PF=""; AGT=""; FLG=""; HAVE_PF=false; HAVE_AGT=false; HAVE_FLG=false; PSTDIN=false; SAT=""; HAVE_SAT=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) [[ $# -ge 2 ]] || { echo "ledger: --context needs a path" >&2; return 2; }
        CTX=$(ledger-ctx "$2") || return 2; HAVE_CTX=true; shift 2 ;;
      --text) [[ $# -ge 2 ]] || { echo "ledger: --text needs a value" >&2; return 2; }
        TXT=$(ledger-text "$2" "next text") || return 2; HAVE_TXT=true; shift 2 ;;
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
      --quote) [[ $# -ge 2 ]] || { echo "ledger: --quote needs a value" >&2; return 2; }
        QUOTE=$(ledger-bounded "$2" 600 --quote) || return 2; shift 2 ;;
      --note) [[ $# -ge 2 ]] || { echo "ledger: --note needs a value" >&2; return 2; }
        NOTE=$(ledger-bounded "$2" 200 --note) || return 2; shift 2 ;;
      --scope) [[ $# -ge 2 ]] || { echo "ledger: --scope needs a value" >&2; return 2; }
        [[ "$2" =~ ^(global|repo:[A-Za-z0-9._-]{1,80})$ ]] || { echo "ledger: --scope must be global or repo:<name>: $2" >&2; return 2; }
        SCOPE="$2"; HAVE_SCOPE=true; shift 2 ;;
      --source) [[ $# -ge 2 ]] || { echo "ledger: --source needs a value" >&2; return 2; }
        SRC=$(ledger-bounded "$2" 120 --source) || return 2; shift 2 ;;
      --all) ALL=true; shift ;;
      --json) JSON=true; shift ;;
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
  local text; text=$(ledger-text "${1:-}" "next text") || return 2
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
  local md dec; md=$(ledger-md-file)
  [[ "$md" == /* ]] || md="$(pwd)/$md"
  dec=$(decisions-summary)
  decisions-render-file
  ledger-read | jq -r --arg md "$md" --arg dec "$dec" --argjson az "$(authz-effective-if-file)" '
    def enc: split("/") | map(@uri) | join("/");
    def ctx: if .context != "" then "\n  file://" + (.context | enc) else "" end;
    def sect($name; $rows): if ($rows | length) == 0 then empty else $name + "\n" + ($rows | join("\n")) + "\n" end;
    sect("Next:"; [.next[] | "**\(.ref)** \(.text)" + ctx]),
    sect("Running:"; [.running[] | "r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)" + ctx]),
    sect("Parked:"; [.parked[] | "**\(.id)**" + (if .title then " " + .title else "" end) + ctx]),
    (if ($az | length) == 0 then empty else sect("Authorization:"; [$az[] | "  " + .key + ": " + .value]) end),
    (if $dec != "" then $dec + "\n" else empty end),
    "Ledger: " + $md'
}

# Reply tail in the user-mandated order (Running, Next, Parked, Ledger line), plain text, no markdown.
# $1 optional TL;DR text (printed first), $2 "no" to leave out the Decisions lines.
ledger-reply() {
  local md dec=""; md=$(ledger-md-file)
  [[ "$md" == /* ]] || md="$(pwd)/$md"
  [[ "${2:-}" == "no" ]] || dec=$(decisions-summary)
  ledger-read | jq -r --arg md "$md" --arg tldr "${1:-}" --arg dec "$dec" --argjson az "$(authz-effective-if-file)" '
    def enc: split("/") | map(@uri) | join("/");
    def ctx: if .context != "" then "\n  file://" + (.context | enc) else "\n  context: MISSING" end;
    def sect($name; $rows): if ($rows | length) == 0 then empty else $name + "\n" + ($rows | join("\n")) + "\n" end;
    (if $tldr != "" then "TL;DR: " + $tldr + "\n" else empty end),
    sect("Running:"; [.running[] | "r\(.job) [\(if .started_at != "" then .started_at else "--:--" end)] \(.title)" + ctx]),
    sect("Next:"; [.next[] | "\(.ref) \(.text)" + ctx]),
    sect("Parked:"; [.parked[] | .id + (if .title then " " + .title else "" end) + ctx]),
    (if ($az | length) == 0 then empty else sect("Authorization:"; [$az[] | "  " + .key + ": " + .value]) end),
    (if $dec != "" then $dec + "\n" else empty end),
    "Ledger: " + $md'
}

# $1 file or "-" (stdin). Refs count only when they open a line (after list/bold markers), so prose is ignored.
ledger-check() {
  local src="${1:-}" draft want got missing extra rc=0
  [[ -n "$src" ]] || { echo "usage: ledger.sh check <replyfile|->" >&2; return 2; }
  if [[ "$src" == "-" ]]; then draft=$(cat); else [[ -r "$src" ]] || { echo "ledger: cannot read $src" >&2; return 2; }; draft=$(<"$src"); fi
  want=$(ledger-read | jq -r '[(.running[] | "r\(.job)"), (.next[] | .ref), (.parked[] | .id)] | .[]' | sort -u)
  got=$(printf '%s\n' "$draft" | sed -nE 's/^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*[*_]*([rnk][0-9]{1,9})([^0-9A-Za-z].*)?$/\2/p' \
    | sed -E 's/^([rnk])0+([0-9])/\1\2/' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
  extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed '/^$/d')
  [[ -z "$missing" ]] || { while read -r r; do echo "MISSING $r (in ledger, not in reply)"; done <<<"$missing"; rc=1; }
  local nocx; nocx=$(ledger-read | jq -r '[(.running[] | select(.context == "") | "r\(.job)"), (.next[] | select(.context == "") | .ref),
    (.parked[] | select(.context == "") | .id)] | .[]')
  [[ -z "$nocx" ]] || { while read -r r; do echo "NO-CONTEXT $r (context file is required)"; done <<<"$nocx"; rc=1; }
  [[ -z "$extra" ]] || { while read -r r; do echo "EXTRA $r (in reply, not in ledger)"; done <<<"$extra"; rc=1; }
  local bad; bad=$(decisions-malformed)
  [[ -z "$bad" ]] || { printf '%s\n' "$bad"; rc=1; }
  return $rc
}

ledger-hm() { [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ledger: time must be HH:MM (24h): ${1:-}" >&2; return 2; }; }

ledger-sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | cut -d' ' -f1; }

ledger-prompt-dir() { printf '%s/ccxp-prompts' "$(dirname "$(ledger-file)")"; }

# True when $1 looks like it holds a credential (prompt saving and the decisions log share this check).
ledger-secret-like() {
  printf '%s' "${1:-}" | grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY'
}

# Save stdin as the job prompt for job $1; prints the path. Refuses text that looks like a credential.
ledger-save-prompt() {
  local d f text; d=$(ledger-prompt-dir); f="$d/$1.md"
  text=$(head -c 200000)
  [[ -n "$text" ]] || { echo "ledger: empty prompt on stdin" >&2; return 2; }
  if ledger-secret-like "$text"; then
    echo "ledger: prompt looks like it holds a credential; not saved" >&2; return 2
  fi
  mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
  ( umask 077; printf '%s\n' "$text" > "$f" ) || return 1
  chmod 600 "$f" 2>/dev/null
  printf '%s' "$f"
}

# ---- Decisions log: ccxp-decisions.json (+ rendered .md, + archive) next to the ledger ----

decisions-file() {
  printf '%s' "${CCXP_DECISIONS_FILE:-$(dirname "$(ledger-file)")/ccxp-decisions.json}"
}

decisions-md-file() { local f; f=$(decisions-file); printf '%s.md' "${f%.json}"; }

decisions-archive-file() { local f; f=$(decisions-file); printf '%s-archive.json' "${f%.json}"; }

DECISIONS_EMPTY='{"schema":1,"counter":0,"decisions":[]}'

# $1 text, $2 max chars, $3 label: strip control chars; reject (not cut) over-long or credential-like text.
ledger-bounded() {
  local t n; t=$(printf '%s' "${1:-}" | tr -d '\000-\037\177')
  n=$(printf '%s' "$t" | jq -Rrs 'length')
  [[ "$n" -le "$2" ]] || { echo "ledger: $3 is $n chars, max $2" >&2; return 2; }
  ledger-secret-like "$t" && { echo "ledger: $3 looks like it holds a credential; not saved" >&2; return 2; }
  printf '%s' "$t"
}

# Current decisions, normalized; defaults when missing. Entries without a d<n> ref and text are dropped
# (`check` reports them); the counter is never below the highest ref present.
decisions-read() {
  local f out; f=$(decisions-file)
  out=$(jq -c 'if type == "object" then . else {} end
    | [(.decisions // [])[] | select(type == "object" and (.ref | strings | test("^d[0-9]{1,9}$")) and (.text | strings | length > 0))
       | {ref, text, quote: (.quote | strings // ""), scope: (.scope | strings // "global"), context: (.context | strings // ""),
          source: (.source | strings // ""), added_at: (.added_at | strings // ""),
          status: (if (.status | strings // "active") | IN("active", "superseded", "retired") then .status // "active" else "active" end),
          superseded_by: (.superseded_by | strings // ""), reason: (.reason | strings // ""), closed_at: (.closed_at | strings // "")}] as $d
    | {schema: 1, updated_at: (.updated_at | strings // ""),
       counter: ([(.counter | numbers // 0)] + [$d[].ref[1:] | tonumber] | max), decisions: $d}' "$f" 2>/dev/null) || out=""
  printf '%s' "${out:-$DECISIONS_EMPTY}"
}

# Write $1 (JSON) to file $2 atomically, mode 600.
decisions-write() {
  local tmp; tmp=$(mktemp "$2.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" && chmod 600 "$tmp" 2>/dev/null && mv "$tmp" "$2" && return 0
  unlink "$tmp" 2>/dev/null; return 1
}

# Past 200 entries, retired/superseded ones closed over 90 days ago move to the archive file. $1 JSON; prints JSON.
decisions-archive() {
  local cur="$1" cutoff moved af arch
  [[ "$(jq '.decisions | length' <<<"$cur")" -gt 200 ]] || { printf '%s' "$cur"; return 0; }
  cutoff=$(date -u -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-90d +%Y-%m-%dT%H:%M:%SZ)
  moved=$(jq -c --arg c "$cutoff" '[.decisions[] | select(.status != "active" and .closed_at != "" and .closed_at < $c)]' <<<"$cur")
  [[ "$moved" != "[]" ]] || { printf '%s' "$cur"; return 0; }
  af=$(decisions-archive-file)
  if [[ -e "$af" ]] && ! jq -e 'type == "object" and ((.schema | numbers // 1) <= 1) and ((.decisions // []) | type) == "array" and all((.decisions // [])[]; type == "object")' "$af" >/dev/null 2>&1; then
    echo "ledger: $af is not a valid archive; skipping archiving (fix or move it aside)" >&2
    printf '%s' "$cur"; return 0
  fi
  arch=$(jq -c --argjson m "$moved" 'if type == "object" then . else {} end | {schema: 1, decisions: ((.decisions // []) + $m)}' "$af" 2>/dev/null) \
    || arch=$(jq -nc --argjson m "$moved" '{schema: 1, decisions: $m}')
  decisions-write "$arch" "$af" || { printf '%s' "$cur"; return 0; }
  jq -c --argjson m "$moved" '.decisions |= map(select(.ref as $r | ($m | map(.ref) | index($r)) == null))' <<<"$cur"
}

# $1 jq filter over the normalized decisions; remaining args are jq args. Sets DECISIONS_LAST.
# The read-modify-write runs under a mkdir lock (<file>.lock; waits up to ~10s, a lock older than 60s is stale).
decisions-update() { ledger-with-lock "$(decisions-file).lock" decisions-update-locked "$@"; }

# $1 lock dir, then a command: run it under a mkdir lock (waits up to ~10s, a lock older than 60s is stale).
ledger-with-lock() {
  local lock="$1" rc i; shift
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  for ((i = 0; i < 100; i++)); do
    mkdir "$lock" 2>/dev/null && break
    [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]] && rmdir "$lock" 2>/dev/null
    sleep 0.1
  done
  [[ -d "$lock" && $i -lt 100 ]] || { echo "ledger: could not lock $lock" >&2; return 1; }
  "$@"; rc=$?
  rmdir "$lock" 2>/dev/null
  return $rc
}

decisions-update-locked() {
  local filter="$1"; shift
  local f cur new
  f=$(decisions-file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  if [[ -s "$f" ]]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
      || { echo "ledger: $f is not valid JSON; not overwriting it (fix or move it aside)" >&2; return 1; }
    jq -e '(.schema | numbers // 1) > 1' "$f" >/dev/null 2>&1 \
      && { echo "ledger: $f has a newer schema than this script (1); not writing" >&2; return 1; }
  fi
  local bad; bad=$(decisions-malformed)
  [[ -z "$bad" ]] || { printf '%s\n' "$bad" >&2; echo "ledger: $f has malformed entries; not writing (fix the file, then retry)" >&2; return 1; }
  cur=$(decisions-read)
  new=$(printf '%s' "$cur" | jq -c "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$filter | .schema = 1 | .updated_at = \$now" 2>/dev/null) || return 1
  new=$(decisions-archive "$new")
  decisions-write "$new" "$f" || return 1
  DECISIONS_LAST="$new"
  decisions-render-file
}

# Rewrite ccxp-decisions.md from the current file (no file, nothing to render). Best-effort.
decisions-render-file() {
  local f md tmp; f=$(decisions-file); [[ -f "$f" ]] || return 0
  md=$(decisions-md-file)
  tmp=$(mktemp "$md.XXXXXX") || return 0
  if decisions-read | jq -r --arg md "$md" '
      def enc: split("/") | map(@uri) | join("/");
      def day: .added_at[0:10];
      def item: "- " + .ref + " [" + day + "] " + .text
        + (if .quote != "" then "\n  quote: \"" + .quote + "\"" else "" end)
        + (if .context != "" then "\n  context: file://" + (.context | enc) else "" end);
      def num: .ref[1:] | tonumber;
      [.decisions[] | select(.status == "active")] as $act
      | [.decisions[] | select(.status != "active")] as $old
      | "# CCXP decisions\n\nUpdated: " + .updated_at + "\n\nDecisions: file://" + ($md | enc) + "\n\n"
        + "## Active (" + ($act | length | tostring) + ")\n"
        + (if ($act | length) == 0 then "- none\n" else
            ([$act[].scope] | unique | map(
              . as $s | "\n### " + $s + "\n" + ([$act[] | select(.scope == $s)] | sort_by(-num) | map(item) | join("\n")) + "\n") | join(""))
          end)
        + "\n## Superseded / retired (" + ($old | length | tostring) + ")\n"
        + (if ($old | length) == 0 then "- none\n" else
            ([$old | sort_by(-num)[] | "- " + .ref + " [" + day + "] " + .text + " - "
              + (if .status == "superseded" then "superseded by " + .superseded_by else "retired" + (if .reason != "" then ": " + .reason else "" end) end)
              + " (" + .closed_at[0:10] + ")"] | join("\n")) + "\n" end)' > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null
    mv "$tmp" "$md" 2>/dev/null || unlink "$tmp" 2>/dev/null
  else
    unlink "$tmp" 2>/dev/null
  fi
  return 0
}

# "Decisions: N active (latest: d4 text)" + the .md path; empty when there is no active decision.
decisions-summary() {
  local f md; f=$(decisions-file); [[ -f "$f" ]] || return 0
  md=$(decisions-md-file); [[ "$md" == /* ]] || md="$(pwd)/$md"
  decisions-read | jq -r --arg md "$md" '
    [.decisions[] | select(.status == "active")] as $a
    | if ($a | length) == 0 then empty else
        "Decisions: \($a | length) active (latest: \($a | max_by(.ref[1:] | tonumber) | .ref + " " + (.text | if length > 100 then .[0:100] + "..." else . end)))\n  " + $md
      end'
}

# d3 / D3 / 3 -> d3
decisions-id() {
  local n="${1:-}"; n="${n#[dD]}"
  ledger-int "$n" || return 2
  printf 'd%s' "$((10#$n))"
}

# Lines that make `check` fail: entries the reader would drop, duplicate refs, bad status.
decisions-malformed() {
  local f; f=$(decisions-file); [[ -s "$f" ]] || return 0
  jq -r 'if type != "object" then "MALFORMED decisions file (not a JSON object)"
    elif ((.decisions // []) | type) != "array" then "MALFORMED decisions is not an array" else
      ((.decisions // []) | to_entries[]
        | select((.value | type != "object") or ((.value.ref | strings | test("^d[0-9]{1,9}$")) | not)
                 or ((.value.text | strings | length) == 0)
                 or ((.value.status // "active") | IN("active", "superseded", "retired") | not))
        | "MALFORMED decision entry #\(.key) (needs a d<n> ref, text and a valid status)"),
      ([(.decisions // [])[] | select(type == "object") | .ref] | group_by(.) | map(select(length > 1) | "MALFORMED duplicate decision ref \(.[0])")[])
    end' "$f" 2>/dev/null || echo "MALFORMED decisions file (not valid JSON)"
}

# Plain-text view of one entry (JSON on stdin).
decisions-entry-text() {
  jq -r '"\(.ref) [\(.added_at[0:10])] \(.scope): \(.text)"
    + (if .status != "active" then "\n  status: \(.status)" + (if .superseded_by != "" then " by \(.superseded_by)" else "" end)
        + (if .reason != "" then " (\(.reason))" else "" end) + (if .closed_at != "" then " on \(.closed_at[0:10])" else "" end) else "" end)
    + (if .quote != "" then "\n  quote: \"\(.quote)\"" else "" end)
    + (if .context != "" then "\n  context: \(.context)" else "" end)
    + (if .source != "" then "\n  source: \(.source)" else "" end)'
}

# $1 ref; prints status ("" when unknown)
decisions-status() { decisions-read | jq -r --arg r "$1" '[.decisions[] | select(.ref == $r) | .status][0] // ""'; }

# The --context path (CTX) must not look like a credential.
decisions-ctx-ok() {
  ledger-secret-like "$CTX" && { echo "ledger: --context looks like it holds a credential; not saved" >&2; return 1; }
  return 0
}

# Error for a ref that is not in the live file: archived entries are read-only history.
decisions-missing() {
  if jq -e --arg r "$1" '.decisions[]? | select(.ref == $r)' "$(decisions-archive-file)" >/dev/null 2>&1; then
    echo "ledger: $1 is archived (closed history); nothing to change" >&2
  else
    echo "ledger: no decision $1" >&2
  fi
}

# decision add|supersede|retire|list|show ...
ledger-decision() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      ledger-args "$@" || return 2
      local text; text=$(ledger-bounded "${POS[0]:-}" 400 "decision text") || return 2
      [[ -n "$text" ]] || { echo "ledger: empty decision text" >&2; return 2; }
      decisions-ctx-ok || return 2
      decisions-update '.counter += 1 | .decisions += [{ref: ("d" + (.counter | tostring)), text: $t, quote: $q, scope: $s,
          context: $c, source: $src, added_at: $now, status: "active", superseded_by: "", reason: "", closed_at: ""}]' \
        --arg t "$text" --arg q "$QUOTE" --arg s "${SCOPE:-global}" --arg c "$CTX" --arg src "$SRC" || return 1
      jq -r '.decisions[-1].ref' <<<"$DECISIONS_LAST" ;;
    supersede)
      ledger-args "$@" || return 2
      local r st text; r=$(decisions-id "${POS[0]:-}") || return 2
      text=$(ledger-bounded "${POS[1]:-}" 400 "decision text") || return 2
      [[ -n "$text" ]] || { echo "ledger: empty decision text" >&2; return 2; }
      decisions-ctx-ok || return 2
      st=$(decisions-status "$r")
      [[ -n "$st" ]] || { decisions-missing "$r"; return 1; }
      [[ "$st" == active ]] || { echo "ledger: $r is already $st" >&2; return 1; }
      decisions-update '(.decisions | map(select(.ref == $r)) | .[0]) as $old | (.counter += 1) | ("d" + (.counter | tostring)) as $new
        | .decisions |= map(if .ref == $r then .status = "superseded" | .superseded_by = $new | .closed_at = $now else . end)
        | .decisions += [{ref: $new, text: $t, quote: $q, scope: (if $hs then $s else $old.scope end),
            context: $c, source: $src, added_at: $now, status: "active", superseded_by: "", reason: "", closed_at: ""}]' \
        --arg r "$r" --arg t "$text" --arg q "$QUOTE" --arg s "$SCOPE" --argjson hs "$HAVE_SCOPE" --arg c "$CTX" --arg src "$SRC" || return 1
      jq -r '.decisions[-1].ref' <<<"$DECISIONS_LAST" ;;
    retire)
      ledger-args "$@" || return 2
      local r st reason; r=$(decisions-id "${POS[0]:-}") || return 2
      reason=$(ledger-bounded "${POS[1]:-}" 200 "reason") || return 2
      st=$(decisions-status "$r")
      [[ -n "$st" ]] || { decisions-missing "$r"; return 1; }
      [[ "$st" == active ]] || { echo "ledger: $r is already $st" >&2; return 1; }
      decisions-update '.decisions |= map(if .ref == $r then .status = "retired" | .reason = $why | .closed_at = $now else . end)' \
        --arg r "$r" --arg why "$reason" || return 1
      printf '%s\n' "$r" ;;
    list)
      ledger-args "$@" || return 2
      local rows
      rows=$(decisions-read | jq -c --argjson all "$ALL" --arg s "$SCOPE" --argjson hs "$HAVE_SCOPE" \
        '[.decisions[] | select($all or .status == "active") | select(($hs | not) or .scope == $s)] | sort_by(-(.ref[1:] | tonumber))')
      if [[ "$JSON" == true ]]; then printf '%s\n' "$rows"; return 0; fi
      [[ "$rows" != "[]" ]] || { echo "no decisions"; return 0; }
      jq -c '.[]' <<<"$rows" | while IFS= read -r row; do decisions-entry-text <<<"$row"; done ;;
    show)
      local r st f; r=$(decisions-id "${1:-}") || return 2
      st=$(decisions-status "$r")
      if [[ -n "$st" ]]; then
        decisions-read | jq -c --arg r "$r" '.decisions[] | select(.ref == $r)' | decisions-entry-text
      elif f=$(decisions-archive-file) && jq -e --arg r "$r" '.decisions[]? | select(.ref == $r)' "$f" >/dev/null 2>&1; then
        echo "(archived)"
        jq -c --arg r "$r" '.decisions[] | select(.ref == $r)' "$f" | decisions-entry-text
      else
        echo "ledger: no decision $r" >&2; return 1
      fi ;;
    *) echo "usage: ledger.sh decision add <text> [--quote q] [--scope global|repo:<name>] [--context <abs path>] [--source s] | supersede <ref> <text> [same options] | retire <ref> [reason] | list [--all] [--scope s] [--json] | show <ref>" >&2; return 2 ;;
  esac
}

# ---- Authorization list: ccxp-authz.json next to the ledger. Unknown or unlisted keys are NO (ask). ----

authz-file() {
  printf '%s' "${CCXP_AUTHZ_FILE:-$(dirname "$(ledger-file)")/ccxp-authz.json}"
}

# Known capability keys, in display order: key<TAB>note. Everything ships as no.
AUTHZ_KNOWN="customer_visible_posts	posts customers can see (issue/PR comments, announcements, release notes)
tagging	git tags and releases
pushing_artifacts	registries, promote and publish
github_issues_update_close	update or close GitHub issues
gitlab_issues_update_close	update or close GitLab issues
delete_data	delete data with no recoverable copy
secret_handling	create, rotate, read or move secrets
spend_money	anything that costs money
third_party_messages	email or DM to a third party
admin_or_bypass	admin actions, branch-protection bypass
install_software_outside_repo	install software outside the repo
owner_accounts_credentials	use the owner's accounts or credentials
unlisted_other	anything not listed above"

authz-entries() {
  local f; f=$(authz-file)
  jq -c 'if type == "object" and (.entries | type) == "object" then .entries else {} end
    | with_entries(select(.value | type == "object") | .value |= {value: (if .value == "yes" then "yes" else "no" end),
        note: (.note | strings // ""), quote: (.quote | strings // ""), date: (.date | strings // "")})' "$f" 2>/dev/null || printf '{}'
}

# Effective list as a JSON array [{key,value,note,quote,date}]: known keys first (default no), then extras.
authz-effective() {
  local known e; known=$(printf '%s\n' "$AUTHZ_KNOWN" | jq -Rn '[inputs | split("\t") | {key: .[0], note: .[1]}]')
  e=$(authz-entries); [[ -n "$e" ]] || e='{}'
  jq -nc --argjson k "$known" --argjson e "$e" '
    ([$k[] | .key]) as $names
    | [$k[] | . as $d | ($e[$d.key] // {}) | {key: $d.key, value: (.value // "no"), note: (if (.note // "") != "" then .note else $d.note end),
        quote: (.quote // ""), date: (.date // "")}]
      + [$e | to_entries[] | select(.key as $n | $names | index($n) | not) | {key, value: .value.value, note: .value.note, quote: .value.quote, date: .value.date}]'
}

# Same, but [] when no authz file exists yet (keeps replies unchanged for users who never set one).
authz-effective-if-file() {
  [[ -f "$(authz-file)" ]] && authz-effective || printf '[]'
}

authz-update() {
  local f tmp; f=$(authz-file)
  if [[ -s "$f" ]]; then
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
      || { echo "ledger: $f is not valid JSON; not overwriting it (fix or move it aside)" >&2; return 1; }
    jq -e '(.schema | numbers // 1) > 1' "$f" >/dev/null 2>&1 \
      && { echo "ledger: $f has a newer schema than this script (1); not writing" >&2; return 1; }
  fi
  tmp=$(jq -nc --argjson e "$(authz-entries)" --arg k "$1" --arg v "$2" --arg q "$3" --arg n "$4" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: 1, updated_at: $now, entries: ($e + {($k): {value: $v, note: $n, quote: $q, date: $now}})}') || return 1
  decisions-write "$tmp" "$f"
}

ledger-authz() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)
      authz-effective | jq -r --argjson j "$([[ "${1:-}" == --json ]] && echo true || echo false)" \
        'if $j then tostring else .[] | [.key, .value, .note, .quote, .date[0:10]] | join("\t") end' ;;
    show)
      if [[ -z "${1:-}" ]]; then authz-effective; return; fi
      authz-effective | jq -r --arg k "$1" '([.[] | select(.key == $k) | .value][0]) // "no"' ;;
    set)
      ledger-args "$@" || return 2
      local k="${POS[0]:-}" v="${POS[1]:-}"
      [[ "$k" =~ ^[a-z][a-z0-9_]{1,63}$ ]] || { echo "ledger: authz key must be lower_snake_case: $k" >&2; return 2; }
      [[ "$v" == yes || "$v" == no ]] || { echo "ledger: authz value must be yes or no: $v" >&2; return 2; }
      [[ ! "$k" =~ ^[a-z][0-9]+(_.*)?$ ]] || { echo "ledger: authz key must not look like a ref: $k" >&2; return 2; }
      [[ "$v" == no || -n "${QUOTE//[[:space:]]/}" ]] || { echo "ledger: authz yes needs --quote \"<owner's words>\"" >&2; return 2; }
      ledger-with-lock "$(authz-file).lock" authz-update "$k" "$v" "$QUOTE" "$NOTE" || return 1
      ledger-render "$(ledger-read)"
      printf '%s: %s\n' "$k" "$v" ;;
    *) echo "usage: ledger.sh authz list [--json] | show [<key>] | set <key> yes|no [--quote <owner words>] [--note <text>]" >&2; return 2 ;;
  esac
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
      ledger-log-start "$((10#${POS[0]}))"
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
    stats) ledger-stats "$@" ;;
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
      if [[ "${1:-}" == d ]]; then
        ledger-int "${2:-}" || return 2
        [[ ${#2} -le 8 ]] || { echo "ledger: decision counter must be at most 8 digits" >&2; return 2; }
        decisions-update '.counter = ([.counter, $v] | max)' --argjson v "$((10#$2))"; return
      fi
      [[ "${1:-}" =~ ^[nsk]$ ]] || { echo "ledger: set-counter prefix must be n, s, k or d: ${1:-}" >&2; return 2; }
      ledger-int "${2:-}" || return 2
      ledger-update '.ref_counters[$p] = $v' --arg p "$1" --argjson v "$((10#$2))" ;;
    render) ledger-render-text ;;
    reply)
      local tldr="" nodec=yes
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --tldr) [[ $# -ge 2 ]] || { echo "ledger: --tldr needs text" >&2; return 2; }
            tldr=$(ledger-text "$2" "tldr") || return 2; shift 2 ;;
          --no-decisions) nodec=no; shift ;;
          *) echo "usage: ledger.sh reply [--tldr <text>] [--no-decisions]" >&2; return 2 ;;
        esac
      done
      ledger-reply "$tldr" "$([[ "$nodec" == no ]] && echo no || echo yes)" ;;
    decision) ledger-decision "$@" ;;
    authz) ledger-authz "$@" ;;
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
          if [[ "${2:-}" == d ]]; then
            decisions-update '.counter += 1' || return 1
            jq -r '"d" + (.counter | tostring)' <<<"$DECISIONS_LAST"; return
          fi
          [[ "${2:-}" =~ ^[nsk]$ ]] || { echo "ledger: ref next prefix must be n, s, k or d: ${2:-}" >&2; return 2; }
          ledger-update '.ref_counters[$p] += 1' --arg p "$2" || return 1
          jq -r --arg p "$2" '$p + (.ref_counters[$p] | tostring)' <<<"$LEDGER_LAST" ;;
        bump)
          local r p n; r=$(printf '%s' "${2:-}" | tr 'NSKD' 'nskd'); p="${r:0:1}"
          if [[ "$p" == d ]]; then
            n=$(decisions-id "$r") || return 2
            [[ ${#n} -le 9 ]] || { echo "ledger: decision counter must be at most 8 digits" >&2; return 2; }
            decisions-update '.counter = ([.counter, $n] | max)' --argjson n "${n#d}"; return
          fi
          ledger-prefix "$p" || return 2
          n=$(ledger-refnum "$r") || return 2
          ledger-update '.ref_counters[$p] = ([.ref_counters[$p], $n] | max)' --arg p "$p" --argjson n "$n" ;;
        *) echo "usage: ledger.sh ref next <n|s|k|d> | ref bump <ref>" >&2; return 2 ;;
      esac ;;
    show)
      if [[ "${1:-}" == "--brief" ]]; then
        ledger-read | jq -r '"running=\(.running | length) parked=\(.parked | length) next=\(.next | length)"' \
          | { read -r line; [[ -f "$(decisions-file)" ]] && line+=" decisions=$(decisions-read | jq '[.decisions[] | select(.status == "active")] | length')"; printf '%s\n' "$line"; }
      elif jq -e 'type == "object"' "$(ledger-file)" >/dev/null 2>&1; then
        local dsum=null
        [[ -f "$(decisions-file)" ]] && dsum=$(decisions-read | jq -c '[.decisions[] | select(.status == "active")] as $a
          | {active: ($a | length), latest: ($a | max_by(.ref[1:] | tonumber) | if . then {ref, text} else null end)}')
        ledger-read | jq -c --argjson d "$dsum" '. + {next_job: (.lifetime_jobs + 1)} + (if $d then {decisions: $d} else {} end)'
      else
        printf '{}\n'
      fi ;;
    *) echo "usage: ledger.sh start <n> <title> | finish <n> | stats [--json] | reconcile --alive <list> | resumed <n> | set-started <n> HH:MM | park <k> | unpark <k> | next add|done|set | set-counter <n|s|k|d> <v> | ref next|bump | decision add|supersede|retire|list|show | authz list|show|set | render | reply [--tldr t] | check <file|-> | show [--brief]" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  ledger "$@"
fi
