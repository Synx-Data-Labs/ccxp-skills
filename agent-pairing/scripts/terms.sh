#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2018,SC2019
# Owner-terms store for the ccxp-agent: acronyms/shorthand -> one or more definitions.
#
#   terms.sh add <TERM> <text> [--context C] [--scope global|repo|repo:<name>] [--default] [--pin]
#                                   [--origin captured|asked]
#                                   record a definition (upsert on same term+text+scope); prints "noted: ..."
#   terms.sh lookup <TERM> [--context a,b]
#                                   resolve one term to JSON {term,status,text|candidates,reason}
#   terms.sh expand [--context a,b] [-|TEXT...]
#                                   JSON array: every known term used in the text, resolved
#                                   (text tokens are added to the context set; read-only)
#   terms.sh detect [-|TEXT...]     JSON array of definition candidates found in the text:
#                                   kind "explicit" (capture, then tell the owner) or "ask" (ask first)
#                                   known "new" | "additional" (a second meaning); read-only
#   terms.sh choose <TERM> <text> [--default] [--scope S]
#                                   the owner picked this meaning: hits+1; --default makes it the default
#   terms.sh remove <TERM> [text] [--scope S]
#                                   delete one definition, or the whole term (the undo for "noted")
#   terms.sh list [--json]          human lines (one per definition) or the normalized JSON
#   terms.sh import-glossary [FILE] [--dry-run]
#                                   one-way import of "- TERM = expansion (tag)" lines from the owner's
#                                   glossary rule (default: <profile>/rules/glossary.md); never edits FILE
#   terms.sh path                   print the terms.json path
# Repo options (lookup, expand, detect, add, choose, remove): --cwd DIR (default $PWD; the repo is its git
# toplevel), --repo NAME and --repo-glossary FILE (override the derived name / glossary path).
#
# File: ${CCXP_TERMS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/terms.json}
# {"version":1,"updated_at","terms":{"WTF":{"defs":[{"text","context"|null,"scope":"global"|"repo:<name>",
#   "default":bool,"pinned":bool,"hits":n,"added_at":"YYYY-MM-DD","last_hit":"YYYY-MM-DD",
#   "origin":"glossary|captured|asked"}]}}}
# origin: glossary = imported from the owner's glossary rule (always pinned), captured = the owner defined
# it in a message, asked = added after the owner answered a question. scope: new captures are "global"
# (personal); "repo:<name>" (the repo's name, see --cwd) keeps a term local to one repo.
# Layers, nearest first: (1) <repo>/.claude/rules/glossary.md of the current repo, read-only, lines
# "- TERM = expansion (context)"; (2) terms.json entries scoped to this repo; (3) global terms.json
# entries (incl. the import of the owner's glossary rule). The first layer that knows the term decides;
# other repos' scopes are invisible. Within a layer: one definition -> it; several -> a context tag
# matching the repo/topic -> the default flag -> the untagged (general) one when alone -> a clear
# most-used leader -> ambiguous (ask the owner).
# Terms need 2-12 chars from [A-Za-z0-9&+/-] with at least 2 uppercase letters; text is one line, at
# most 120 chars; at most 200 terms and 8 definitions per term. Lookup is case-sensitive, with a
# case-insensitive fallback for terms of 3+ chars (so "rca" finds RCA but "cc" never finds CC).
# Writes are atomic (temp file + mv) and keep the previous version as terms.json.bak; an unreadable
# file is moved aside (terms.json.corrupt-<time>), never overwritten. Not locked: last write wins.
# Definitions are shorthand only: NEVER store secrets. Exit: 0 ok, 1 not found, 2 usage/invalid, 3 limit.

terms-file() {
  printf '%s' "${CCXP_TERMS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/terms.json}"
}

TERMS_EMPTY='{"version":1,"updated_at":"","terms":{}}'

# Shared jq definitions: normalization of the file and the resolution rules.
read -r -d '' TERMS_LIB <<'EOF'
def lc: ascii_downcase;
def normalize:
  (if type == "object" then . else {} end) as $r
  | {version: 1,
     updated_at: ($r.updated_at | strings // ""),
     terms: (($r.terms | if type == "object" then . else {} end)
       | with_entries(select(.value | type == "object")
           | .value = {defs: [(.value.defs // [])[]
               | select(type == "object" and (.text | strings | length > 0))
               | {text, context: (.context | strings // null), default: (.default == true),
                  scope: (.scope | strings | select(. == "global" or test("^repo:[A-Za-z0-9._-]{1,60}$")) // "global"),
                  pinned: (.pinned == true), hits: (.hits | numbers // 0), added_at: (.added_at | strings // ""),
                  last_hit: (.last_hit | strings // ""),
                  origin: (.origin | strings | select(. == "glossary" or . == "asked") // "captured")}]})
       | with_entries(select(.value.defs | length > 0)))};
def ctxhit($ctx): (.context | lc) as $c | ($ctx | any(. == $c));
def resolve($ctx):
  .defs as $d
  | if ($d | length) == 1 then {status: "resolved", reason: "single", text: $d[0].text}
    else
      ($d | map(select(.context != null and ctxhit($ctx)))) as $cm
      | ($cm | length) as $ncm
      | (if $ncm > 0 then $cm else $d end) as $pool
      | if $ncm == 1 then {status: "resolved", reason: "context", text: $cm[0].text}
        else
          ($pool | map(select(.default))) as $df
          | if ($df | length) > 0 then {status: "resolved", reason: "default", text: $df[0].text}
            else
              (if $ncm > 0 then $pool
               else (($pool | map(select(.context == null))) as $u | if ($u | length) > 0 then $u else $pool end)
               end) as $p2
              | if ($p2 | length) == 1 and $ncm == 0 then {status: "resolved", reason: "general", text: $p2[0].text}
                else
                  ($p2 | sort_by(-.hits)) as $s
                  | ($s[1].hits // 0) as $second
                  | if $s[0].hits >= 2 and ($s[0].hits - $second) >= 2 and $s[0].hits >= 2 * $second
                    then {status: "resolved", reason: "most-used", text: $s[0].text}
                    else {status: "ambiguous", candidates: ($p2 | map({text, context, hits}))}
                    end
                end
            end
        end
    end;
def pickkey($keys; $t):
  ([$keys[] | select(. == $t)] + [$keys[] | select(($t | length) >= 3 and lc == ($t | lc))])[0];
# Scope tiers, nearest first: the current repo's glossary file ($rg: term -> defs, read-only), then
# definitions scoped to this repo ("repo:<name>"), then global ones. Other repos' scopes are invisible.
def resolved($t; $ctx; $repo; $rg):
  pickkey($rg | keys; $t) as $gk
  | pickkey(.terms | keys; $t) as $fk
  | (if $fk == null then [] else .terms[$fk].defs end) as $all
  | ($all | map(select(.scope == "repo:" + $repo))) as $rs
  | ($all | map(select(.scope == "global"))) as $gl
  | (if $gk != null then {tier: "repo-glossary", key: $gk, defs: $rg[$gk]}
     elif ($rs | length) > 0 then {tier: "repo", key: $fk, defs: $rs}
     elif ($gl | length) > 0 then {tier: "global", key: $fk, defs: $gl}
     else null end) as $m
  | if $m == null then {term: $t, status: "unknown"}
    else ({defs: $m.defs} | resolve($ctx)) + {term: $m.key, matched: $t, tier: $m.tier, definitions: ($m.defs | length)} end;
EOF

# Detection of definitions in a message: explicit patterns only, initials must agree for "explicit".
read -r -d '' TERMS_DETECT <<'EOF'
def stop: ["of","the","and","for","to","a","an","in","on","at","by","or","with"];
def isstop: ascii_downcase as $w | (stop | any(. == $w));
def cw: gsub("^[^A-Za-z0-9]+"; "") | gsub("[^A-Za-z0-9*]+$"; "");
def words: [splits("\\s+") | cw | select(length > 0)];
def ini: .[0:1] | ascii_upcase;
def fini: map(ini) | join("");
def sini: map(select(isstop | not)) | map(ini) | join("");
def exact($a): (fini == $a) or (sini == $a);
def subseq($a; $b):
  if ($a | length) == 0 then true elif ($b | length) == 0 then false
  elif $a[0:1] == $b[0:1] then subseq($a[1:]; $b[1:]) else subseq($a; $b[1:]) end;
def acrok: test("^[A-Za-z0-9][A-Za-z0-9&+/-]{1,11}$") and (([match("[A-Z]"; "g")] | length) >= 2);
def norm: ascii_upcase | gsub("[^A-Z0-9]"; "");
def deny: ["OK","AM","PM","KB","MB","GB","TB","KG","CM","MM","KM","ML","MS","PX","USD","EUR","GBP","CNY","NOTE","TODO","FIXME","TBD","FYI","ASAP","NB","PS","RE"];
def clean:
  gsub("```[\\s\\S]*?```"; " ") | gsub("`[^`]*`"; " ")
  | split("\n") | map(select(test("^\\s*>") | not)) | join("\n")
  | gsub("[\"“”«»‘’]"; "") | gsub("(?<![A-Za-z])'|'(?![A-Za-z])"; "");
def sufmatch($ws; $acr):
  ($acr | length) as $m | ([$m + 3, ($ws | length)] | min) as $hi
  | first(range($m; $hi + 1) as $k | select($k > 0) | ($ws[-$k:]) as $c
          | select(($c[0] | isstop | not) and ($c[-1] | isstop | not) and ($c | exact($acr))) | $c) // null;
def premat($ws; $acr):
  ($acr | length) as $m | ([$m + 3, ($ws | length)] | min) as $hi
  | first(range($m; $hi + 1) as $k | select($k > 0) | ($ws[:$k]) as $c
          | select(($c[0] | isstop | not) and ($c[-1] | isstop | not) and ($c | exact($acr))) | $c) // null;
def cand($acr; $text; $kind; $pat): {term: $acr, text: $text, kind: $kind, pattern: $pat};

(length) as $len
| clean as $t
# 1. root cause analysis (RCA)
| ([$t | match("\\(\\s*([A-Za-z0-9][A-Za-z0-9&+/-]{1,11})\\s*\\)"; "g")] | map(
    . as $m | $m.captures[0].string as $acr | select($acr | acrok)
    | ($acr | norm) as $n
    | ($t[0:$m.offset] | [splits("[\n;:!?,(\\[]")] | last | words) as $ws
    | sufmatch($ws; $n) as $hit
    | (first(range($n | length; ([($n | length) + 3, ($ws | length)] | min) + 1) as $k | select($k > 0)
             | ($ws[-$k:]) as $c | select(subseq($n; ($c | fini))) | $c) // null) as $part
    | if $hit != null then cand($acr; ($hit | join(" ")); "explicit"; "expansion (ACR)")
      elif $part != null then cand($acr; ($part | join(" ")); "ask"; "expansion (ACR)")
      else empty end)) as $a
# 2. RCA (root cause analysis)
| ([$t | match("(?<![A-Za-z0-9])([A-Z][A-Za-z0-9&+/-]{1,11})\\s*\\(\\s*([^()\n]{3,80}?)\\s*\\)"; "g")] | map(
    . as $m | $m.captures[0].string as $acr | select($acr | acrok)
    | ($m.captures[1].string | words) as $ws | select(($ws | length) >= 2)
    | ($acr | norm) as $n
    | premat($ws; $n) as $hit
    | if $hit != null then cand($acr; ($hit | join(" ")); "explicit"; "ACR (expansion)")
      elif subseq($n; ($ws[:([($n | length) + 3, ($ws | length)] | min)] | fini))
      then cand($acr; ($ws[:6] | join(" ")); "ask"; "ACR (expansion)")
      else empty end)) as $b
# 3. RCA = / means / stands for ... root cause analysis
| ([$t | match("(?<![A-Za-z0-9])([A-Za-z0-9][A-Za-z0-9&+/-]{1,11})(?:\\s*(?:=|->|→)\\s*|\\s+(?:means|stands for|is short for|is shorthand for|is an acronym for|is the acronym for|is an abbreviation (?:of|for))\\s+|\\s*(?:指的是|是指|的全称是|全称是|意思是|代表|表示)\\s*)([^.!?;,\n。！？；，(（]{2,80})"; "g")] | map(
    . as $m | $m.captures[0].string as $acr | select($acr | acrok)
    | ($m.captures[1].string | words) as $ws | select(($ws | length) >= 1 and (($ws | join(" ")) | test("[A-Za-z]|[^\\x00-\\x7F]")))
    | ($acr | norm) as $n
    | premat($ws; $n) as $hit
    | if $hit != null then cand($acr; ($hit | join(" ")); "explicit"; "ACR = expansion")
      elif ($ws | length) <= 6 then cand($acr; ($ws | join(" ")); "ask"; "ACR = expansion")
      else empty end)) as $c
# 4. root cause analysis aka RCA
| ([$t | match("(?i:\\b(?:aka|a\\.k\\.a\\.?|abbreviated(?: as)?|call(?:ed)? (?:it|this|that))\\s+)([A-Za-z0-9][A-Za-z0-9&+/-]{1,11})(?![A-Za-z0-9])"; "g")] | map(
    . as $m | $m.captures[0].string as $acr | select($acr | acrok)
    | ($acr | norm) as $n
    | ($t[0:$m.offset] | [splits("[\n;:!?,(\\[]")] | last | words) as $ws
    | sufmatch($ws; $n) as $hit
    | if $hit != null then cand($acr; ($hit | join(" ")); "explicit"; "expansion aka ACR") else empty end)) as $d
| ($a + $b + $c + $d)
| map(select(.text | length >= 2 and length <= 120))
| map(if .kind == "explicit" and $len > 1500 then .kind = "ask" else . end)
| map(select(.kind == "explicit" or ((.term | ascii_upcase) as $u | (deny | any(. == $u)) | not)))
| unique_by([.term, (.text | ascii_downcase)])
| map(. as $x
      | ((($terms.terms[$x.term].defs // []) | map(select(.scope == "global" or .scope == "repo:" + $repo)))
         + ($rg[$x.term] // [])) as $vis
      | . + {known: (if ($vis | length) == 0 then "new"
                     elif ($vis | any((.text | ascii_downcase) == ($x.text | ascii_downcase))) then "same"
                     else "additional" end)})
| map(select(.known != "same"))
| sort_by(if .kind == "explicit" then 0 else 1 end) | .[:3]
EOF

# Current file, normalized; the empty store when missing or unreadable.
terms-read() {
  local f; f=$(terms-file)
  jq -c "$TERMS_LIB normalize" "$f" 2>/dev/null || printf '%s' "$TERMS_EMPTY"
}

# $1 jq filter over the normalized store; remaining args are jq args. Prints the new store (no write).
terms-transform() {
  local filter="$1"; shift
  terms-read | jq -c "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg today "$(date -u +%F)" \
    "$TERMS_LIB $filter | .version = 1 | .updated_at = \$now"
}

# Same, then write atomically, keeping the previous file as terms.json.bak.
terms-update() {
  local f dir tmp err
  f=$(terms-file); dir=$(dirname "$f")
  mkdir -p "$dir" 2>/dev/null || { echo "terms: cannot create $dir" >&2; return 1; }
  if [[ -e "$f" ]] && ! jq -e . "$f" >/dev/null 2>&1; then
    mv "$f" "$f.corrupt-$(date -u +%Y%m%d-%H%M%S)" || return 1
    echo "terms: unreadable $f moved aside as $f.corrupt-*; starting fresh" >&2
  fi
  tmp=$(mktemp "$f.XXXXXX") || return 1
  if err=$(terms-transform "$@" 2>&1 >"$tmp"); then
    chmod 600 "$tmp" 2>/dev/null
    TERMS_LAST=$(<"$tmp")
    [[ -e "$f" ]] && cp -p "$f" "$f.bak" 2>/dev/null
    mv "$tmp" "$f"
  else
    unlink "$tmp" 2>/dev/null
    echo "terms: ${err#jq: error*: }" >&2
    [[ "$err" == *"limit"* ]] && return 3
    return 1
  fi
}

# One line, no control chars, trimmed.
terms-clean() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   ' | tr -d '\000-\037\177' | tr -s ' ' | sed 's/^ //; s/ $//'
}

terms-check-term() {
  local t="${1:-}"
  if [[ ! "$t" =~ ^[A-Za-z0-9][A-Za-z0-9\&+/-]{1,11}$ ]] || [[ "$(printf '%s' "$t" | tr -cd 'A-Z' | wc -c | tr -d ' ')" -lt 2 ]]; then
    echo "terms: not a term (2-12 chars of A-Z a-z 0-9 & + / -, at least 2 uppercase): $t" >&2
    return 2
  fi
}

terms-check-text() {
  local x="${1:-}"
  [[ -n "$x" ]] || { echo "terms: empty definition" >&2; return 2; }
  [[ ${#x} -le 120 ]] || { echo "terms: definition longer than 120 chars" >&2; return 2; }
}

# "a, B/c" -> ["a","b/c","c"]
terms-ctx-json() {
  jq -cn --arg c "${1:-}" '$c | ascii_downcase | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))
    | map(., (split("/") | last)) | unique'
}

# Repo options shared by the commands that resolve terms; set by the arg loops, used by terms-repo-resolve.
TERMS_CWD="" TERMS_REPO="" TERMS_RG=""

# Fill TERMS_REPO (the repo's name: the main checkout's directory name even from a worktree, else the
# toplevel's) and TERMS_RG (<toplevel>/.claude/rules/glossary.md) from --cwd (default $PWD), unless given.
terms-repo-resolve() {
  local dir top common
  dir="${TERMS_CWD:-$PWD}"
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [[ -z "$TERMS_REPO" && -n "$top" ]]; then
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
    if [[ "$common" == */.git ]]; then TERMS_REPO=$(basename "${common%/.git}"); else TERMS_REPO=$(basename "$top"); fi
  fi
  if [[ -z "$TERMS_RG" && -n "$top" ]]; then TERMS_RG="$top/.claude/rules/glossary.md"; fi
  TERMS_REPO=$(printf '%s' "$TERMS_REPO" | tr -c 'A-Za-z0-9._\n-' '_')
}

# --scope value -> "global" | "repo:<name>" (needs terms-repo-resolve first); empty stays empty.
terms-scope-value() {
  case "${1:-}" in
    "") printf '' ;;
    global) printf 'global' ;;
    repo) [[ -n "$TERMS_REPO" ]] || { echo "terms: --scope repo: not inside a git repo (use repo:<name>)" >&2; return 2; }
          printf 'repo:%s' "$TERMS_REPO" ;;
    repo:*) [[ "$1" =~ ^repo:[A-Za-z0-9._-]{1,60}$ ]] || { echo "terms: bad scope: $1" >&2; return 2; }
          printf '%s' "$1" ;;
    *) echo "terms: scope must be global, repo or repo:<name>: $1" >&2; return 2 ;;
  esac
}

# "- TERM = expansion (tag)" lines of a glossary file -> [{term,text,context}] (everything else ignored).
terms-parse-glossary() {
  jq -Rn -c '[inputs
    | capture("^- (?<term>[A-Za-z0-9][A-Za-z0-9&+/-]{1,11}) = (?<rest>.+)$")?
    | . as $m
    | ($m.rest | gsub("^\\s+|\\s+$"; "")) as $r
    | (($r | capture("^(?<text>.*[^ ])\\s+\\((?<tag>[A-Za-z0-9._/-]{1,40})\\)$")?) // {text: $r, tag: null}) as $p
    | select(($m.term | [match("[A-Z]"; "g")] | length) >= 2 and ($p.text | length) >= 1 and ($p.text | length) <= 120)
    | {term: $m.term, text: $p.text, context: ($p.tag | if . == null then null else ascii_downcase end)}]' "$1"
}

# The current repo's glossary file as {TERM: [defs]} (read-only; {} when absent).
terms-rg-json() {
  if [[ -n "$TERMS_RG" && -r "$TERMS_RG" ]]; then
    terms-parse-glossary "$TERMS_RG" | jq -c 'reduce .[] as $x ({}; .[$x.term] += [{text: $x.text, context: $x.context,
      default: false, hits: 0, scope: "repo-glossary"}])'
  else
    printf '{}'
  fi
}

# Text from the remaining args, or stdin for "-" / no args.
terms-text-arg() {
  if [[ $# -eq 0 || "${1:-}" == "-" ]]; then cat; else printf '%s' "$*"; fi
}

terms-add() {
  local term="${1:-}" text ctx="" def=false pin=false org="captured" scope=""
  [[ $# -gt 0 ]] && shift
  text=$(terms-clean "${1:-}"); [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) ctx=$(printf '%s' "${2:-}" | tr 'A-Z' 'a-z'); shift 2 || break ;;
      --scope) scope="${2:-}"; shift 2 || break ;;
      --default) def=true; shift ;;
      --pin) pin=true; shift ;;
      --origin) org="${2:-}"; shift 2 || break ;;
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      *) echo "terms: add: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  terms-repo-resolve
  scope=$(terms-scope-value "${scope:-global}") || return 2
  terms-check-term "$term" || return 2
  terms-check-text "$text" || return 2
  [[ "$org" == captured || "$org" == asked ]] || { echo "terms: --origin must be captured or asked" >&2; return 2; }
  [[ -z "$ctx" || "$ctx" =~ ^[a-z0-9._/-]{1,40}$ ]] || { echo "terms: context must be one token of [a-z0-9._/-], 40 chars max" >&2; return 2; }
  terms-update '
    def same: (.text | lc) == ($x | lc) and .scope == $sc;
    (.terms[$k] // {defs: []}) as $e
    | (if ($e.defs | any(same))
       then .terms[$k].defs |= map(if same
              then (if $c != "" then .context = $c else . end) | (if $d then .default = true else . end)
                   | (if $p then .pinned = true else . end) else . end)
       else .terms[$k].defs = ($e.defs + [{text: $x, context: (if $c == "" then null else $c end), scope: $sc,
              default: false, pinned: $p, hits: 1, added_at: $today, last_hit: $today, origin: $o}])
       end)
    | (if $d then .terms[$k].defs |= map(if .scope == $sc then .default = same else . end) else . end)
    | if (.terms[$k].defs | length) > 8 then error("limit: more than 8 definitions for " + $k)
      elif (.terms | length) > 200 then error("limit: more than 200 terms") else . end' \
    --arg k "$term" --arg x "$text" --arg c "$ctx" --arg sc "$scope" --argjson d "$def" --argjson p "$pin" --arg o "$org" || return $?
  jq -r --arg k "$term" --arg x "$text" --arg sc "$scope" '
    [.terms[$k].defs[] | select(.scope == $sc)] as $d
    | ($d | map(select((.text | ascii_downcase) == ($x | ascii_downcase)))[0]) as $me
    | ([$d[] | select((.text | ascii_downcase) != ($x | ascii_downcase)) | .text]) as $others
    | "noted: \($k) = \($me.text)" + (if $me.context then " [\($me.context)]" else "" end)
      + (if $sc != "global" then " {\($sc)}" else "" end)
      + (if ($others | length) > 0 then " (also: " + ($others | join("; ")) + ")" else "" end)' <<<"$TERMS_LAST"
}

terms-lookup() {
  local term="${1:-}" ctx=""
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) ctx="${2:-}"; shift 2 || break ;;
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      --repo-glossary) TERMS_RG="${2:-}"; shift 2 || break ;;
      *) echo "terms: lookup: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$term" ]] || { echo "usage: terms.sh lookup <TERM> [--context a,b]" >&2; return 2; }
  terms-repo-resolve
  terms-read | jq -c --arg t "$term" --arg repo "$TERMS_REPO" --argjson rg "$(terms-rg-json)" \
    --argjson ctx "$(terms-ctx-json "$ctx,$TERMS_REPO")" "$TERMS_LIB resolved(\$t; \$ctx; \$repo; \$rg)"
}

terms-expand() {
  local ctx="" text
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context) ctx="${2:-}"; shift 2 || break ;;
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      --repo-glossary) TERMS_RG="${2:-}"; shift 2 || break ;;
      *) break ;;
    esac
  done
  terms-repo-resolve
  text=$(terms-text-arg "$@")
  printf '%s' "$text" | jq -Rs -c --argjson terms "$(terms-read)" --arg repo "$TERMS_REPO" --argjson rg "$(terms-rg-json)" \
    --argjson ctx0 "$(terms-ctx-json "$ctx,$TERMS_REPO")" "$TERMS_LIB"'
    . as $raw
    | (gsub("```[\\s\\S]*?```"; " ") | gsub("`[^`]*`"; " ")) as $t
    | ([$t | scan("[A-Za-z0-9]+(?:[&+/-][A-Za-z0-9]+)*")]) as $tok
    | ($tok + [$tok[] | select(test("[&+/-]")) | splits("[&+/-]")]
       + [$tok[] | select(test("^.*[A-Z0-9]s$")) | .[:-1]]) as $all
    | ($ctx0 + ([$t | ascii_downcase | scan("[a-z0-9][a-z0-9._/-]{2,39}")] | unique | .[:300])) as $ctx
    | $terms
    | . as $store
    | [$all[] | . as $w | $store | resolved($w; $ctx; $repo; $rg) | select(.status != "unknown")]
    | unique_by(.term) | .[:12]'
}

terms-detect() {
  local text
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      --repo-glossary) TERMS_RG="${2:-}"; shift 2 || break ;;
      *) break ;;
    esac
  done
  terms-repo-resolve
  text=$(terms-text-arg "$@")
  printf '%s' "$text" | jq -Rs -c --argjson terms "$(terms-read)" --arg repo "$TERMS_REPO" \
    --argjson rg "$(terms-rg-json)" "$TERMS_DETECT"
}

terms-choose() {
  local term="${1:-}" text def=false scope=""
  [[ $# -gt 0 ]] && shift
  text=$(terms-clean "${1:-}"); [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default) def=true; shift ;;
      --scope) scope="${2:-}"; shift 2 || break ;;
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      *) echo "terms: choose: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  terms-repo-resolve
  scope=$(terms-scope-value "$scope") || return 2
  terms-read | jq -e --arg k "$term" --arg x "$text" --arg sc "$scope" \
    '.terms[$k].defs // [] | any((.text | ascii_downcase) == ($x | ascii_downcase) and ($sc == "" or .scope == $sc))' >/dev/null \
    || { echo "terms: no such definition: $term = $text" >&2; return 1; }
  terms-update '
    def hit: (.text | lc) == ($x | lc) and ($sc == "" or .scope == $sc);
    .terms[$k].defs |= map(if hit then .hits += 1 | .last_hit = $today else . end)
    | if $d then (.terms[$k].defs | map(select(hit)) | .[0].scope) as $s
        | .terms[$k].defs |= map(if .scope == $s then .default = hit else . end)
      else . end' \
    --arg k "$term" --arg x "$text" --arg sc "$scope" --argjson d "$def" || return $?
  echo "chose: $term = $text"
}

terms-remove() {
  local term="${1:-}" text="" scope=""
  [[ $# -gt 0 ]] && shift
  if [[ $# -gt 0 && "$1" != --* ]]; then text=$(terms-clean "$1"); shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 || break ;;
      --cwd) TERMS_CWD="${2:-}"; shift 2 || break ;;
      --repo) TERMS_REPO="${2:-}"; shift 2 || break ;;
      *) echo "terms: remove: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  terms-repo-resolve
  scope=$(terms-scope-value "$scope") || return 2
  terms-read | jq -e --arg k "$term" --arg x "$text" --arg sc "$scope" \
    '.terms[$k].defs // [] | any(($x == "" or (.text | ascii_downcase) == ($x | ascii_downcase)) and ($sc == "" or .scope == $sc))' >/dev/null \
    || { echo "terms: nothing to remove: $term${text:+ = $text}" >&2; return 1; }
  terms-update '
    .terms[$k].defs |= map(select((($x == "" or (.text | lc) == ($x | lc)) and ($sc == "" or .scope == $sc)) | not))
    | if (.terms[$k].defs | length) == 0 then del(.terms[$k]) else . end' \
    --arg k "$term" --arg x "$text" --arg sc "$scope" || return $?
  [[ -z "$scope" ]] || scope=" {$scope}"
  echo "removed: $term${text:+ = $text}$scope"
}

terms-list() {
  if [[ "${1:-}" == "--json" ]]; then terms-read; return; fi
  terms-read | jq -r '.terms | to_entries | sort_by(.key)[] | .key as $k | .value.defs[]
    | "\($k) = \(.text)" + ([(if .context then "ctx: " + .context else empty end),
        (if .scope != "global" then .scope else empty end),
        (if .default then "default" else empty end), (if .hits > 0 then "hits " + (.hits | tostring) else empty end)]
        | if length > 0 then " (" + join("; ") + ")" else "" end)'
}

terms-import-glossary() {
  local file="" dry=false parsed before after
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n) dry=true; shift ;;
      *) file="$1"; shift ;;
    esac
  done
  file="${file:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rules/glossary.md}"
  [[ -r "$file" ]] || { echo "terms: cannot read $file" >&2; return 1; }
  parsed=$(terms-parse-glossary "$file")
  before=$(terms-read | jq '[.terms[].defs | length] | add // 0')
  local filter='
    reduce $e[] as $x (.;
      (.terms[$x.term] // {defs: []}) as $cur
      | if ($cur.defs | any((.text | lc) == ($x.text | lc) and .scope == "global")) then .
        else .terms[$x.term].defs = ($cur.defs + [{text: $x.text, context: $x.context, scope: "global",
               default: ($x.context == null and ($cur.defs | any(.default and .scope == "global") | not)), pinned: true,
               hits: 0, added_at: $today, last_hit: "", origin: "glossary"}]) end)
    | if (.terms | length) > 200 or ([.terms[].defs | length] | max // 0) > 8 then error("limit: too many terms or definitions") else . end'
  if [[ "$dry" == true ]]; then
    after=$(terms-transform "$filter" --argjson e "$parsed" | jq '[.terms[].defs | length] | add // 0') || return 1
    echo "would import $((after - before)) of $(jq length <<<"$parsed") glossary lines (dry run, nothing written)"
    return 0
  fi
  terms-update "$filter" --argjson e "$parsed" || return $?
  after=$(jq '[.terms[].defs | length] | add // 0' <<<"$TERMS_LAST")
  echo "imported $((after - before)) of $(jq length <<<"$parsed") glossary lines (existing definitions skipped; $file untouched)"
}

terms() {
  local cmd="${1:-}"; [[ $# -gt 0 ]] && shift
  case "$cmd" in
    add) terms-add "$@" ;;
    lookup) terms-lookup "$@" ;;
    expand) terms-expand "$@" ;;
    detect) terms-detect "$@" ;;
    choose) terms-choose "$@" ;;
    remove) terms-remove "$@" ;;
    list) terms-list "$@" ;;
    import-glossary) terms-import-glossary "$@" ;;
    path) terms-file; echo ;;
    *) echo "usage: terms.sh add <TERM> <text> [--context C] [--scope S] [--default] [--pin] | lookup <TERM> [--context a,b] | expand [-|TEXT] | detect [-|TEXT] | choose <TERM> <text> [--default] | remove <TERM> [text] | list [--json] | import-glossary [FILE] [--dry-run] | path" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  command -v jq >/dev/null 2>&1 || { echo "terms: jq is required" >&2; exit 2; }
  terms "$@"
fi
