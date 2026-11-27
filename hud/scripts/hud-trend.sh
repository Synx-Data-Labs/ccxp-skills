#!/usr/bin/env bash
# Weekly trend one-liners for the ccxp-hud band (hud-data.sh sources this) and a CLI (T20261126-122285).
#
#   hud-trend.sh [--line|--table|--hist|--json] [--root DIR] [--support OWNER/NAME] [--gh-config-dir DIR] [--weeks N]
#
# One line per domain, Monday-aligned UTC weekly buckets (the last 5 full weeks plus the current partial week,
# marked `*`), the stock plus the flow, a block sparkline scaled 0..max per line, the delta vs the end of last week:
#
#   Queue   172 ▇▇▆▆▅▅*  -9 vs last wk  (in 14 / out 23)
#   Support   5 ▃▅▆▄▃▂*  -1 vs last wk  (opened 2 / delivered 3)
#   AP       32 ▂▃▅▆▇▅*  merged/wk      (holds 52 ▅▆▆▇▇▇ up)
#
# Sources, all recomputed from history (nothing stored unless history cannot reproduce the number):
#   Queue    git log -p of dev/TODO/queue.md on the default branch (same ref rule as the queue high watermark): the task
#            lines at each Monday and, per commit, the ids added and removed (a reorder nets to zero).
#   Support  gh issue list --state all (createdAt / closedAt) of the support repo: open at each Monday, opened, closed
#            (closed = delivered). The repo comes from --support, HUD_TREND_SUPPORT_REPO, else `issues.repo` of the HUD
#            config (project file, then user file). HUD_TREND_SUPPORT_FILE reads the JSON from a file instead of gh.
#   AP       dev/.autopilot-history.jsonl (AUTOPILOT_HISTORY_FILE): merged and cycles per week; the holds series is the
#            only stored one, a snapshot line per week appended to <state>/holds-<key>.jsonl when that week has none
#            (the count of `.holds` in dev/.autopilot-state.json cannot be recomputed). HUD_TREND_SNAPSHOT=0 skips it.
# A missing or unreadable source prints a dash for that line; the repo is only ever read. Weeks are UTC.
#
# hud-trend-json <root> [support repo] [gh config dir] prints {"rows":[{"key","label","short","full"}...],"at":N} or "null".
# It never blocks the caller: it answers from the cache and starts ONE detached refresh when the cache is older than
# HUD_TREND_TTL (default 600 s; lock dir; git 60 s and gh 20 s timeouts). No network call happens on a render.
#
# Overrides (also test hooks): HUD_TREND_OFF=1 (no work, "null"), HUD_TREND_TTL, HUD_TREND_SYNC=1 (refresh in the
# foreground), HUD_TREND_STATE_DIR (default <profile>/state/hud-trend), HUD_TREND_NOW (fake epoch).

# shellcheck source=/dev/null
[ -r "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../../_session/profile-dir.sh"
_HT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-queue-hwm.sh
. "$_HT_DIR/hud-queue-hwm.sh" # _hw-ref, sl-run-timeout (hud-lib.sh)

HT_QUEUE_PATH="dev/TODO/queue.md"
HT_GIT_TIMEOUT=60
HT_GH_TIMEOUT=20
HT_GH_LIMIT=3000

_ht-now() { printf '%s' "${HUD_TREND_NOW:-$(date +%s)}"; }
_ht-dir() { printf '%s' "${HUD_TREND_STATE_DIR:-${CCXP_PROFILE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/state/hud-trend}"; }

# $1 now, $2 weeks (default 5) -> the Mondays 00:00 UTC bounding the buckets, oldest first, space separated:
# weeks + 1 values; the last one is the current week's Monday. Pure arithmetic (the epoch started on a Thursday).
ht-bounds() {
  local now="$1" weeks="${2:-5}" day mon k out=""
  day=$((now / 86400))
  mon=$(((day - (day + 3) % 7) * 86400))
  for ((k = weeks; k >= 0; k--)); do out+="$((mon - k * 604800)) "; done
  printf '%s' "${out% }"
}

# $1 bounds, $2 now -> the bucket END bounds as a JSON array for jq: [M1..M(w), now+1] (the bucket starts are the bounds themselves)
_ht-bounds-json() { printf '%s %s' "$1" "$(($2 + 1))" | jq -R -c 'split(" ") | map(tonumber) | .[1:]'; }

# $1 root $2 now $3 bounds -> {"stock":[..],"in":[..],"out":[..]} (one value per bucket, current last), or nothing when the
# queue file has no history on the default branch. stock = task lines at the end of the bucket (now for the current one).
ht-queue-series() {
  local root="$1" now="$2" bounds="$3" ref dm=() gmaj gmin out
  ref=$(_hw-ref "$root")
  git -C "$root" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 || return 1
  read -r gmaj gmin < <(git --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/') || true
  if [[ "${gmaj:-}" =~ ^[0-9]+$ ]] && { [ "$gmaj" -gt 2 ] || { [ "$gmaj" -eq 2 ] && [ "${gmin:-0}" -ge 31 ]; }; }; then dm=(--diff-merges=first-parent); fi
  out=$(GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    sl-run-timeout "$HT_GIT_TIMEOUT" git -C "$root" log --first-parent --reverse -p -U0 --no-color --no-ext-diff --no-renames "${dm[@]}" --format='@%ct' "$ref" -- "$HT_QUEUE_PATH" 2>/dev/null \
    | awk -v b="$bounds" -v now="$now" '
        function flush(   id, a, r, k) {
          if (ts == "") return
          a = 0; r = 0
          for (id in P) if (!(id in Q)) a++
          for (id in Q) if (!(id in P)) r++
          n++; T[n] = ts; A[n] = a; R[n] = r
          c += a - r; if (c < 0) c = 0; S[n] = c
          delete P; delete Q; ts = ""
        }
        BEGIN { nb = split(b, B, " "); c = 0; n = 0; seen = 0 }
        /^@[0-9]+$/ { flush(); ts = substr($0, 2) + 0; seen = 1; next }
        /^\+- \[T[0-9]+-[0-9]+\]\(/ { match($0, /T[0-9]+-[0-9]+/); P[substr($0, RSTART, RLENGTH)] = 1; next }
        /^-- \[T[0-9]+-[0-9]+\]\(/ { match($0, /T[0-9]+-[0-9]+/); Q[substr($0, RSTART, RLENGTH)] = 1; next }
        END {
          flush()
          if (!seen) exit 3
          for (k = 1; k <= nb; k++) {
            s = B[k]; e = (k < nb) ? B[k + 1] : now + 1
            st = 0; fi = 0; fo = 0
            for (i = 1; i <= n; i++) {
              if (T[i] < e) st = S[i]
              if (T[i] >= s && T[i] < e) { fi += A[i]; fo += R[i] }
            }
            stock = stock (k > 1 ? "," : "") st; fin = fin (k > 1 ? "," : "") fi; fout = fout (k > 1 ? "," : "") fo
          }
          printf "{\"stock\":[%s],\"in\":[%s],\"out\":[%s]}\n", stock, fin, fout
        }' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# $1 now $2 bounds, stdin: `gh issue list --json createdAt,closedAt` -> {"stock":[..],"opened":[..],"delivered":[..]}; nothing on bad input.
ht-support-series() {
  local now="$1" bounds="$2" ends
  ends=$(_ht-bounds-json "$bounds" "$now")
  jq -c --argjson e "$ends" --argjson b "$(printf '%s' "$bounds" | jq -R -c 'split(" ") | map(tonumber)')" '
    def ep: if type == "string" then (try fromdateiso8601 catch null) else null end;
    if type != "array" then empty else
      [ .[] | select(type == "object") | {c: (.createdAt | ep), x: (.closedAt | ep)} | select(.c != null) ] as $i
      | [range(0; $b | length)] as $k
      | {stock: [$k[] | $e[.] as $en | [$i[] | select(.c < $en and (.x == null or .x >= $en))] | length],
         opened: [$k[] | $b[.] as $s | $e[.] as $en | [$i[] | select(.c >= $s and .c < $en)] | length],
         delivered: [$k[] | $b[.] as $s | $e[.] as $en | [$i[] | select(.x != null and .x >= $s and .x < $en)] | length]}
    end' 2>/dev/null
}

# $1 history file $2 now $3 bounds -> {"merged":[..],"cycles":[..]} per bucket (cycles: every logged cycle but `capped`
# ticks and the retired visit|advance|park lines, as autopilot-state.sh stats counts them); nothing without the file.
ht-ap-series() {
  local file="$1" now="$2" bounds="$3" ends
  [ -r "$file" ] || return 1
  ends=$(_ht-bounds-json "$bounds" "$now")
  jq -R -c --argjson e "$ends" --argjson b "$(printf '%s' "$bounds" | jq -R -c 'split(" ") | map(tonumber)')" -n '
    def ep: if type == "string" then (try fromdateiso8601 catch null) else null end;
    [inputs | fromjson? | select(type == "object")
     | select(((.outcome | strings // "") | IN("visit", "advance", "park")) | not)
     | {t: (.ts | ep), o: (.outcome | strings // ""), m: (if (.merged | type) == "number" and .merged >= 0 then .merged else 0 end)}
     | select(.t != null)] as $h
    | [range(0; $b | length)] as $k
    | {merged: [$k[] | $b[.] as $s | $e[.] as $en | [$h[] | select(.t >= $s and .t < $en) | .m] | add // 0],
       cycles: [$k[] | $b[.] as $s | $e[.] as $en | [$h[] | select(.t >= $s and .t < $en and .o != "capped")] | length]}' "$file" 2>/dev/null
}

# $1 root $2 now $3 bounds -> {"live":N|null,"series":[N|null ...]} holds: appends this week's snapshot when absent, then
# reads the snapshots back (a week without one is null; the current week shows the live count).
ht-holds-series() {
  local root="$1" now="$2" bounds="$3" live="" dir file key week sf
  sf="$root/dev/.autopilot-state.json"
  [ -r "$sf" ] || return 1
  live=$(jq -r '((.holds | objects) // {}) | length' "$sf" 2>/dev/null) || live=""
  [[ "$live" =~ ^[0-9]+$ ]] || return 1
  key=$(printf '%s' "$root" | cksum | cut -d' ' -f1); dir=$(_ht-dir); file="$dir/holds-$key.jsonl"
  week=$(printf '%s' "${bounds##* }" | jq -R -r 'tonumber | strftime("%Y-%m-%d")')
  if [ "${HUD_TREND_SNAPSHOT:-1}" != 0 ] && mkdir -p "$dir" 2>/dev/null; then
    grep -qF "\"week\":\"$week\"" "$file" 2>/dev/null || printf '{"week":"%s","holds":%s}\n' "$week" "$live" >>"$file" 2>/dev/null || true
  fi
  [ -r "$file" ] || file=/dev/null
  jq -R -c -n --argjson live "$live" --argjson b "$(printf '%s' "$bounds" | jq -R -c 'split(" ") | map(tonumber)')" '
    [inputs | fromjson? | select(type == "object" and (.week | type) == "string" and (.holds | type) == "number")] as $s
    | {live: $live, series: [range(0; $b | length) | . as $i | ($b[$i] | strftime("%Y-%m-%d")) as $w
        | if $i == ($b | length) - 1 then $live else ([$s[] | select(.week == $w) | .holds] | first // null) end]}' "$file" 2>/dev/null \
    || printf '{"live":%s,"series":[]}\n' "$live"
}

# $1 root -> the support repo from the HUD config (project file, then the user file): `issues.repo` or a bare string.
_ht-config-repo() {
  local f r
  for f in "$1/.claude/ccxp-hud.json" "${CCXP_PROFILE_DIR:-/nonexistent}/ccxp-hud.json"; do
    [ -r "$f" ] || continue
    r=$(jq -r '(.issues | if type == "string" then . elif type == "object" then (.repo // "") else "" end) | strings' "$f" 2>/dev/null) || r=""
    if [[ "$r" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then printf '%s' "$r"; return 0; fi
  done
  return 1
}

# $1 repo $2 gh config dir ("" = default) -> the issue list JSON on stdout (HUD_TREND_SUPPORT_FILE reads a file instead).
_ht-support-fetch() {
  local repo="$1" ghdir="$2"
  if [ -n "${HUD_TREND_SUPPORT_FILE:-}" ]; then cat "$HUD_TREND_SUPPORT_FILE" 2>/dev/null; return; fi
  command -v gh >/dev/null 2>&1 || return 1
  ( [ -z "$ghdir" ] || export GH_CONFIG_DIR="$ghdir"; export GH_PROMPT_DISABLED=1
    sl-run-timeout "$HT_GH_TIMEOUT" gh issue list --repo "$repo" --state all --limit "$HT_GH_LIMIT" --json createdAt,closedAt ) 2>/dev/null
}

# $1 root $2 support repo ("" = from config) $3 gh config dir -> the whole data object on stdout; a missing source is null.
ht-data() {
  local root="$1" repo="${2:-}" ghdir="${3:-}" now bounds weeks="${HT_WEEKS:-5}" q="" s="" a="" h="" raw hf
  now=$(_ht-now); bounds=$(ht-bounds "$now" "$weeks")
  q=$(ht-queue-series "$root" "$now" "$bounds" 2>/dev/null) || q=""
  [ -n "$repo" ] || repo=$(_ht-config-repo "$root") || repo=""
  # A repo name from a flag, the environment or stdin is checked like the config's: owner/name characters only.
  [[ -z "$repo" || "$repo" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || repo=""
  if [ -n "$repo" ] || [ -n "${HUD_TREND_SUPPORT_FILE:-}" ]; then
    raw=$(_ht-support-fetch "$repo" "$ghdir") || raw=""
    [ -z "$raw" ] || s=$(printf '%s' "$raw" | ht-support-series "$now" "$bounds") || s=""
  fi
  hf="${AUTOPILOT_HISTORY_FILE:-$root/dev/.autopilot-history.jsonl}"
  a=$(ht-ap-series "$hf" "$now" "$bounds" 2>/dev/null) || a=""
  h=$(ht-holds-series "$root" "$now" "$bounds" 2>/dev/null) || h=""
  jq -n -c --argjson b "$(printf '%s' "$bounds" | jq -R -c 'split(" ") | map(tonumber)')" --argjson now "$now" \
    --arg q "$q" --arg s "$s" --arg a "$a" --arg h "$h" '
    def p($x): if $x == "" then null else ($x | fromjson) end;
    {now: $now, weeks: [$b[] | strftime("%m-%d")], queue: p($q), support: p($s),
     ap: (p($a) as $ap | if $ap == null then null else $ap + {holds: p($h)} end)}'
}

# stdin: the ht-data object -> one JSON object per domain row {"key","label","short","full"} as {"rows":[...]}.
# Block sparkline scaled 0..max of its own series (a null week is a dot); `*` marks the current partial week.
ht-rows() {
  jq -c '
    def pad($w): tostring | . as $s | (($w - ($s | length)) | if . < 0 then 0 else . end) as $n | ([range(0; $n)] | map(" ") | join("")) + $s;
    def rpad($w): tostring | . as $s | (($w - ($s | length)) | if . < 0 then 0 else . end) as $n | $s + ([range(0; $n)] | map(" ") | join(""));
    def spark: ([.[] | numbers] | max // 0) as $m
      | map(if . == null then "·" else (["▁","▂","▃","▄","▅","▆","▇","█"][if $m == 0 then 0 else ((. / $m * 7) | round) end]) end) | join("") + "*";
    def sgn: if . > 0 then "+\(.)" elif . < 0 then "\(.)" else "±0" end;
    def last: .[length - 1];
    def prev: .[length - 2];
    def line($label; $n; $sp; $mid; $flow):
      (($label | rpad(7)) + " " + ($n | pad(4)) + " " + $sp + "  " + (if $flow == "" then $mid else ($mid | rpad(14)) + "  (" + $flow + ")" end));
    . as $d
    | {rows: ([
        (if $d.queue then
          ($d.queue.stock | last) as $n | ($d.queue.in | last) as $i | ($d.queue.out | last) as $o | ($d.queue.stock | spark) as $sp
          | (($d.queue.stock | last) - ($d.queue.stock | prev)) as $dl
          | {key: "queue", label: "Queue", short: "Queue \($n) \($sp) \($dl | sgn)",
             full: line("Queue"; $n; $sp; "\($dl | sgn) vs last wk"; "in \($i) / out \($o)")} else null end),
        (if $d.support then
          ($d.support.stock | last) as $n | ($d.support.opened | last) as $i | ($d.support.delivered | last) as $o | ($d.support.stock | spark) as $sp
          | (($d.support.stock | last) - ($d.support.stock | prev)) as $dl
          | {key: "support", label: "Support", short: "Support \($n) \($sp) \($dl | sgn)",
             full: line("Support"; $n; $sp; "\($dl | sgn) vs last wk"; "opened \($i) / delivered \($o)")} else null end),
        (if $d.ap then
          ($d.ap.merged | last) as $n | ($d.ap.merged | spark) as $sp
          | ($d.ap.holds // null) as $h
          | (if $h and ($h.series | length) > 0 then
               ($h.live) as $hl | ([$h.series[:-1][] | numbers] | last) as $hp
               | "holds \($hl) \($h.series | spark)" + (if $hp == null then "" elif $hl > $hp then " up" elif $hl < $hp then " down" else " flat" end)
             else "" end) as $hs
          | {key: "ap", label: "AP", short: "AP \($n) \($sp) merged/wk",
             full: line("AP"; $n; $sp; "merged/wk"; $hs)} else null end)
      ] | map(select(. != null)))}'
}

# stdin: the ht-data object -> the one-liner block, always in the order Queue, Support, AP; a domain with no source gets a dash.
ht-render-line() {
  local rows; rows=$(ht-rows)
  jq -r -n --argjson r "$rows" '
    [["queue", "Queue"], ["support", "Support"], ["ap", "AP"]][] | . as $k
    | ([$r.rows[] | select(.key == $k[0]) | .full] | first) // (($k[1] + "       ")[0:7] + "    -  (no data)")'
}

# stdin: the ht-data object -> the weekly numbers, one row per week (the current week marked *).
ht-render-table() {
  jq -r '
    def c($v): if $v == null then "-" else ($v | tostring) end;
    . as $d | ($d.weeks | length) as $n
    | (["week", "queue", "in", "out", "support", "opened", "delivered", "ap merged", "cycles", "holds"] | map(. as $x | $x) | join("\t")),
      ([range(0; $n)][] | . as $i
        | ([ $d.weeks[$i] + (if $i == $n - 1 then "*" else "" end),
             c($d.queue.stock[$i]?), c($d.queue.in[$i]?), c($d.queue.out[$i]?),
             c($d.support.stock[$i]?), c($d.support.opened[$i]?), c($d.support.delivered[$i]?),
             c($d.ap.merged[$i]?), c($d.ap.cycles[$i]?), c($d.ap.holds.series[$i]?) ] | join("\t")))' | column -t -s "$(printf '\t')"
}

# stdin: the ht-data object -> a horizontal histogram per domain (bar widths scaled per series, 30 columns at most).
ht-render-hist() {
  jq -r '
    def bar($v; $m): if $v == null then "·" else (if $m == 0 then 0 else (($v / $m * 30) | round) end) as $w
      | ([range(0; (if $v > 0 and $w == 0 then 1 else $w end))] | map("█") | join("")) end;
    def hist($title; $s; $weeks):
      ([$s[] | numbers] | max // 0) as $m
      | $title,
        ([range(0; $s | length)][] | . as $i | "  \($weeks[$i])\(if $i == ($s | length) - 1 then "*" else " " end) \(bar($s[$i]; $m)) \($s[$i] // "-")");
    . as $d
    | (if $d.queue then hist("Queue: tasks at the end of each week"; $d.queue.stock; $d.weeks), hist("Queue: added per week"; $d.queue.in; $d.weeks), hist("Queue: closed per week"; $d.queue.out; $d.weeks) else "Queue: no data" end),
      (if $d.support then hist("Support: open issues at the end of each week"; $d.support.stock; $d.weeks), hist("Support: opened per week"; $d.support.opened; $d.weeks), hist("Support: delivered (closed) per week"; $d.support.delivered; $d.weeks) else "Support: no data" end),
      (if $d.ap then hist("AP: merged per week"; $d.ap.merged; $d.weeks), hist("AP: cycles per week"; $d.ap.cycles; $d.weeks), (if $d.ap.holds then hist("AP: holds (weekly snapshot)"; $d.ap.holds.series; $d.weeks) else empty end) else "AP: no data" end)'
}

# $1 cache file $2 root $3 support repo $4 gh config dir -> rebuild the cache; never fails.
ht-refresh() {
  local file="$1" root="$2" repo="$3" ghdir="$4" tmp now out=""
  now=$(_ht-now)
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  out=$(ht-data "$root" "$repo" "$ghdir" 2>/dev/null | ht-rows 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    jq -c --argjson now "$now" '. + {at: $now}' <<<"$out" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
  elif [ -r "$file" ]; then
    jq -c --argjson now "$now" '.at = $now' "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
  else
    printf '{"rows":[],"at":%s}\n' "$now" >"$tmp" && mv -f "$tmp" "$file"
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

# $1 root $2 support repo (optional) $3 gh config dir (optional)
hud-trend-json() {
  [ "${HUD_TREND_OFF:-}" != 1 ] || { printf 'null'; return 0; }
  local root="$1" repo="${2:-}" ghdir="${3:-}" ttl="${HUD_TREND_TTL:-600}" dir file now fetched=0 cached=""
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=600
  [ -n "$root" ] && [ -d "$root" ] || { printf 'null'; return 0; }
  dir=$(_ht-dir)
  file="$dir/$(printf '%s|%s' "$root" "$repo" | cksum | cut -d' ' -f1).json"
  now=$(_ht-now)
  if [ -r "$file" ]; then
    cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
    fetched=$(jq -r '(.at // 0) | floor' <<<"${cached:-null}" 2>/dev/null) || fetched=0
    [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  fi
  if [ $((now - fetched)) -ge "$ttl" ] && mkdir -p "$dir" 2>/dev/null; then
    local lock="$file.lock"
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
    if mkdir "$lock" 2>/dev/null; then
      if [ "${HUD_TREND_SYNC:-}" = 1 ]; then
        ht-refresh "$file" "$root" "$repo" "$ghdir"
        rmdir "$lock" 2>/dev/null || true
        cached=$(jq -c '.' "$file" 2>/dev/null) || cached=""
      else
        ( ht-refresh "$file" "$root" "$repo" "$ghdir"; rmdir "$lock" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
      fi
    fi
  fi
  local out=""
  # Untrusted cache: only strings of the four known keys survive, at most three rows.
  [ -z "$cached" ] || out=$(jq -c 'select((.rows | type) == "array" and (.rows | length) > 0)
      | {rows: [.rows[:3][] | select(type == "object" and (.key | IN("queue", "support", "ap")) and (.short | type) == "string" and (.full | type) == "string")
                | {key, label: (.label | strings // .key), short: .short[:80], full: .full[:160]}]}
      | select(.rows | length > 0)' <<<"$cached" 2>/dev/null | head -n1) || out=""
  printf '%s' "${out:-null}"
}

# CLI: the data in the chosen view, computed in the foreground (the cache is the HUD's, not the CLI's).
hud-trend-main() {
  local mode=line root="" repo="${HUD_TREND_SUPPORT_REPO:-}" ghdir="" data
  while [ $# -gt 0 ]; do
    case "$1" in
      --line | --table | --hist | --json) mode="${1#--}" ;;
      --root) root="${2:-}"; shift ;;
      --support) repo="${2:-}"; shift ;;
      --gh-config-dir) ghdir="${2:-}"; shift ;;
      --weeks) HT_WEEKS="${2:-5}"; shift ;;
      -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "hud-trend.sh: unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done
  [[ "${HT_WEEKS:-5}" =~ ^[0-9]+$ ]] && [ "${HT_WEEKS:-5}" -ge 1 ] && [ "${HT_WEEKS:-5}" -le 26 ] || { echo "hud-trend.sh: --weeks wants 1..26" >&2; return 2; }
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  data=$(ht-data "$root" "$repo" "$ghdir") || data=""
  [ -n "$data" ] || { echo "hud-trend.sh: could not compute the trend" >&2; return 1; }
  case "$mode" in
    line) ht-render-line <<<"$data" ;;
    table) ht-render-table <<<"$data" ;;
    hist) ht-render-hist <<<"$data" ;;
    json) printf '%s\n' "$data" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  hud-trend-main "$@"
fi
