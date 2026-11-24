#!/usr/bin/env bash
# persona-review.sh <list|overlap|size|bucket|commands> [options] -- the deterministic
# half of /retro's persona review (T20261124-147908, epic E2). It reads the decisions log
# and the ccxp-agent persona asset; it never writes either, and never runs
# `decision add/retire/supersede`. `commands` only PRINTS candidate lines for the owner.
#
#   list       active decisions: ref, added date, age in days, scope, text (TSV)
#   overlap    per decision, persona lines that cite its ref or share >= MIN_SHARED
#              meaningful words (TSV: ref, line, section, shared words)
#   size       persona bytes/lines, the bats cap, headroom, bytes per section
#   bucket     one hint per decision (TSV: ref, bucket, reason). A HINT: the retro
#              agent and the owner decide
#   commands   the `decision retire` lines for decisions bucketed retire, as text
#   tasks      one row per proposed conversion (bucket persona|skill-task|script-or-hook|
#              profile-config): ref, bucket, stage, repo, file|exists:<task file>, text.
#              The dedupe check looks for an open task naming the ref; the retro agent files
#              the `file` rows with /new-task (one task per row, refs and target in the body)
#   retire-enforced [--apply]   decisions with `enforced-by` (ledger.sh decision enforce) whose
#              target is a file on origin/main or a merged PR AND that a task names: dry-run
#              by default; --apply runs `ledger.sh decision retire <ref> "folded into ..."`.
#              The only retirement this script performs (owner rule, d155 follow-up).
#
# Options: --persona FILE (default <plugin>/agent-pairing/assets/ccxp-agent.md)
#          --cap-file FILE (default <plugin>/tests/agent_pairing.bats; first `-lt N`)
#          --repo DIR (default <plugin>; origin/main and dev/ tasks are read there)
#          --apply (retire-enforced only)  --scope S (list/bucket filter)  --today YYYY-MM-DD  --min-shared N (default 3)
# Env:     LEDGER (default <plugin>/hud/scripts/ledger.sh); CCXP_DECISIONS_FILE picks the log;
#          PR_GH (default `bash <plugin>/_gh/gh.sh`) runs gh for the merged-PR check.
# Buckets: persona | skill-task | script-or-hook | profile-config | keep-in-log | already-covered | retire | contradiction
# Exit:    0 ok, 2 usage, 3 missing input or ledger/jq failure.
set -euo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_STOP=" about after again always before being could decision every first never other should still their there these those under until which while would write wrong using where when will with from have this that than then them they into also must only some such what your "

function pr-die() { echo "persona-review.sh: $1" >&2; exit "${2:-2}"; }

function pr-decisions() { # active decisions as a JSON array
  local ledger="${LEDGER:-$PR_ROOT/hud/scripts/ledger.sh}"
  [[ -f "$ledger" ]] || pr-die "ledger not found: $ledger" 3
  bash "$ledger" decision list --json 2>/dev/null | jq -c 'if type == "array" then . else [] end' \
    || pr-die "cannot read the decisions log" 3
}

function pr-review-json() {
  local ledger="${LEDGER:-$PR_ROOT/hud/scripts/ledger.sh}"
  bash "$ledger" decision review --json 2>/dev/null | jq -c 'if type == "object" then . else {} end' || echo '{}'
}

function pr-words() { # meaningful lowercase words (>= 5 letters, no stopwords), one per line, unique
  tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' \
    | awk -v stop="$PR_STOP" 'length($0) >= 5 && index(stop, " " $0 " ") == 0 && !seen[$0]++'
}

function pr-sections() { # TSV line<TAB>section for every persona line
  awk '/^## /{s=$0; sub(/^## /, "", s)} {print NR "\t" s}' "$1"
}

function pr-overlap() { # $1 persona, $2 min shared; reads decisions JSON on stdin
  local persona="$1" min="$2" ref text words sec n
  sec=$(pr-sections "$persona")
  while IFS=$'\x1f' read -r ref text; do
    words=$(printf '%s' "$text" | pr-words)
    n=0
    while IFS= read -r l; do
      n=$((n + 1))
      local lw hits=() w
      lw=$(printf '%s' "$l" | pr-words)
      while IFS= read -r w; do
        [[ -n "$w" ]] && grep -qxF "$w" <<<"$lw" && hits+=("$w")
      done <<<"$words"
      if grep -qE "\\b${ref}\\b" <<<"$l"; then
        printf '%s\t%s\t%s\tcites %s\n' "$ref" "$n" "$(awk -F'\t' -v n="$n" '$1 == n {print $2}' <<<"$sec")" "$ref"
      elif [[ ${#hits[@]} -ge $min ]]; then
        printf '%s\t%s\t%s\t%s\n' "$ref" "$n" "$(awk -F'\t' -v n="$n" '$1 == n {print $2}' <<<"$sec")" "${hits[*]}"
      fi
    done <"$persona"
  done < <(jq -r '.[] | [.ref, .text] | join("\u001f")')
}

function pr-cap() { # $1 cap file
  local f="$1" cap=""
  [[ -f "$f" ]] && cap=$(grep -oE -- '-lt [0-9]{4,6}' "$f" | head -1 | awk '{print $2}')
  printf '%s' "${cap:-}"
}

function pr-size() { # $1 persona, $2 cap file
  local persona="$1" cap bytes lines
  bytes=$(wc -c <"$persona" | tr -d ' ')
  lines=$(wc -l <"$persona" | tr -d ' ')
  cap=$(pr-cap "$2")
  echo "persona_bytes=$bytes"
  echo "persona_lines=$lines"
  echo "cap_bytes=${cap:-unknown}"
  if [[ -n "$cap" ]]; then
    echo "headroom_bytes=$((cap - 1 - bytes))"
    echo "note=an addition must trim at least (addition_bytes - headroom_bytes) bytes elsewhere"
  fi
  echo "section_bytes:"
  LC_ALL=C awk 'BEGIN{n="(preamble)"} /^## /{printf "%6d\t%s\n", b, n; n=$0; sub(/^## /, "", n); b=0} {b += length($0) + 1} END{printf "%6d\t%s\n", b, n}' "$persona" | sort -rn
}

function pr-age() { # $1 YYYY-MM-DD..., $2 today -> whole days (empty when unparsable)
  local a b
  a=$(bash -c '. "$1"; d_epoch "$2"' _ "$PR_ROOT/_date/date.sh" "${1:0:10}" 2>/dev/null) || return 0
  b=$(bash -c '. "$1"; d_epoch "$2"' _ "$PR_ROOT/_date/date.sh" "$2" 2>/dev/null) || return 0
  printf '%s' "$(((b - a) / 86400))"
}

function pr-list() { # $1 scope ("" = all), $2 today
  local scope="$1" today="$2" ref added sc text age
  pr-decisions | jq -r --arg s "$scope" '.[] | select($s == "" or .scope == $s) | [.ref, .added_at, .scope, .text] | join("\u001f")' \
    | while IFS=$'\x1f' read -r ref added sc text; do
        age=$(pr-age "$added" "$today")
        printf '%s\t%s\t%s\t%s\t%s\n' "$ref" "${added:0:10}" "${age:-?}" "$sc" "$text"
      done
}

function pr-stage() { # $1 bucket -> target stage of the distill chain (decision > persona > skill > script)
  case "$1" in
    persona) echo persona ;; skill-task) echo skill ;; script-or-hook) echo script ;;
    profile-config) echo profile-config ;; retire|contradiction) echo owner-review ;; *) echo - ;;
  esac
}

function pr-target-repo() { # $1 bucket, $2 scope -> repo the change lands in
  case "$1" in
    persona|skill-task|script-or-hook) [[ "$2" == repo:* ]] && echo "${2#repo:}" || echo ccxp-skills ;;
    profile-config) echo local-profile ;; *) echo - ;;
  esac
}

function pr-bucket() { # $1 persona, $2 scope, $3 min shared
  local persona="$1" scope="$2" min="$3" decs rev ovl ref sc text b why
  decs=$(pr-decisions) || return 3
  decs=$(jq -c --arg s "$scope" '[.[] | select($s == "" or .scope == $s)]' <<<"$decs")
  rev=$(pr-review-json)
  ovl=$(jq -c '.' <<<"$decs" | pr-overlap "$persona" "$min" || true)
  while IFS=$'\x1f' read -r ref sc text; do
    b="" why=""
    local low; low=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
    if jq -e --arg r "$ref" '[(.contradictions // [])[] | tostring | select(test("\\b" + $r + "\\b"))] | length > 0' <<<"$rev" >/dev/null 2>&1; then
      b=contradiction why="listed in decision review contradictions"
    elif jq -e --arg r "$ref" '[(.stale // [])[] | select(.ref == $r)] | length > 0' <<<"$rev" >/dev/null 2>&1; then
      b=retire why="decision review marks it stale: $(jq -r --arg r "$ref" '[.stale[] | select(.ref == $r) | .reasons[]] | join("; ")' <<<"$rev")"
    elif grep -qE "^${ref}	" <<<"$ovl"; then
      b=already-covered why="persona line $(grep -E "^${ref}	" <<<"$ovl" | head -1 | awk -F'\t' '{print $2 " (" $3 ")"}')"
    elif [[ "$low" =~ (^|[^a-z])(gate|lint|linter|hooks?|whitelist|allowlist|rebase|pre-commit|validator)([^a-z]|$) ]]; then
      b=script-or-hook why="mechanically enforceable (mentions ${BASH_REMATCH[2]})"
    elif [[ "$low" =~ (^|[^a-z])(autopilot|/drive|/retro|/ccxp|skills?|scripts?|hud|ledger\.sh|workflows?|parallel)([^a-z]|$) ]]; then
      b=skill-task why="mentions ${BASH_REMATCH[2]}"
    elif [[ "$low" =~ (^|[^a-z])(authz|channels?|profiles?|config|taste|agenda)([^a-z]|$) ]]; then
      b=profile-config why="mentions ${BASH_REMATCH[2]}"
    elif [[ "$sc" == repo:* ]]; then
      b=keep-in-log why="repo-scoped ($sc)"
    elif [[ "$low" =~ (^|[^a-z])(always|never|must|forbidden|only)([^a-z]|$) ]]; then
      b=persona why="global rule wording (${BASH_REMATCH[2]}) with no persona overlap"
    else
      b=keep-in-log why="no persona, skill or config signal"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$ref" "$b" "$why" "$(pr-stage "$b")" "$(pr-target-repo "$b" "$sc")"
  done < <(jq -r '.[] | [.ref, .scope, .text] | join("\u001f")' <<<"$decs")
}

function pr-commands() { # $1 persona, $2 scope, $3 min shared
  local ref b why n=0 rows
  rows=$(pr-bucket "$1" "$2" "$3") || exit 3
  while IFS=$'\t' read -r ref b why _; do
    [[ "$b" == retire ]] || continue
    n=$((n + 1))
    printf '# propose to the owner, do not run unprompted (L = hud/scripts/ledger.sh)\nbash "$L" decision retire %s %q\n' "$ref" "$why"
  done <<<"$rows"
  [[ $n -gt 0 ]] || echo "# no decision is bucketed retire"
}

function pr-task-files() { # $1 repo, $2 ref, $3 "open" (TODO+PARKING) or "all" (+JOURNAL): task files naming the ref
  local d dirs=("$1/dev/TODO" "$1/dev/PARKING")
  [[ "$3" == all ]] && dirs+=("$1/dev/JOURNAL")
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] && grep -lE "(^|[^A-Za-z0-9])$2([^A-Za-z0-9]|$)" "$d"/*.md 2>/dev/null || true
  done
}

function pr-task-id() { basename "$1" | grep -oE 'T[0-9]{8}-[0-9]{6}' | head -1; }

function pr-tasks() { # $1 persona, $2 scope, $3 min shared, $4 repo
  local ref b why stage repo text f
  while IFS=$'\t' read -r ref b why stage repo; do
    case "$b" in persona|skill-task|script-or-hook|profile-config) ;; *) continue ;; esac
    text=$(pr-decisions | jq -r --arg r "$ref" '.[] | select(.ref == $r) | .text')
    f=$(pr-task-files "$4" "$ref" open | head -1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ref" "$b" "$stage" "$repo" "$([[ -n "$f" ]] && echo "exists:$(pr-task-id "$f")" || echo file)" "$text"
  done < <(pr-bucket "$1" "$2" "$3")
}

function pr-resolved() { # $1 repo, $2 enforced-by; prints a verdict word on stdout: ok|unmerged|missing|task
  local repo="$1" t="$2" gh state
  if [[ "$t" =~ ^T[0-9]{8}-[0-9]{6}$ ]]; then echo task
  elif [[ "$t" =~ ^#?[0-9]+$ || "$t" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
    gh="${PR_GH:-bash $PR_ROOT/_gh/gh.sh}"
    state=$(cd "$repo" && $gh pr view "${t#\#}" --json state -q .state 2>/dev/null) || { echo missing; return 0; }
    [[ "$state" == MERGED ]] && echo ok || echo unmerged
  elif [[ "$t" == /* || "$t" == *..* ]]; then echo missing
  elif git -C "$repo" cat-file -e "origin/main:${t#./}" 2>/dev/null; then echo ok
  else echo missing; fi
}

function pr-retire-enforced() { # $1 repo, $2 apply (true|false)
  local repo="$1" apply="$2" ledger="${LEDGER:-$PR_ROOT/hud/scripts/ledger.sh}" ref tgt v f tid reason n=0
  [[ -f "$ledger" ]] || pr-die "ledger not found: $ledger" 3
  while IFS=$'\x1f' read -r ref tgt; do
    n=$((n + 1))
    v=$(pr-resolved "$repo" "$tgt")
    case "$v" in
      ok) ;;
      task) printf '%s\tpending\t%s is a task id; point enforced-by at a merged PR or a file on origin/main\n' "$ref" "$tgt"; continue ;;
      unmerged) printf '%s\tpending\t%s is not merged yet\n' "$ref" "$tgt"; continue ;;
      *) printf '%s\tpending\t%s is not on origin/main\n' "$ref" "$tgt"; continue ;;
    esac
    f=$(pr-task-files "$repo" "$ref" all | head -1)
    if [[ -z "$f" ]]; then printf '%s\tpending\tno task names %s; file the distill task first\n' "$ref" "$ref"; continue; fi
    tid=$(pr-task-id "$f")
    reason="folded into $tgt (task ${tid:-$(basename "$f")})"
    reason="${reason:0:200}"
    if [[ "$apply" == true ]]; then
      bash "$ledger" decision retire "$ref" "$reason" >/dev/null || { printf '%s\tfailed\tretire call failed\n' "$ref"; continue; }
      printf '%s\tretired\t%s\n' "$ref" "$reason"
    else
      printf '%s\twould-retire\t%s\n' "$ref" "$reason"
    fi
  done < <(pr-decisions | jq -r '.[] | select((.enforced_by // "") != "") | [.ref, .enforced_by] | join("\u001f")')
  [[ $n -gt 0 ]] || echo "# no active decision has enforced-by"
}

function persona-review() {
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift
  local persona="$PR_ROOT/agent-pairing/assets/ccxp-agent.md" capf="$PR_ROOT/tests/agent_pairing.bats" scope="" today min=3 repo="$PR_ROOT" apply=false
  today=$(date -u +%F)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=true; shift ;;
      --persona|--cap-file|--scope|--today|--min-shared|--repo)
        [[ $# -ge 2 ]] || pr-die "$1 needs a value"
        case "$1" in
          --persona) persona="$2" ;; --cap-file) capf="$2" ;; --scope) scope="$2" ;;
          --today) today="$2" ;; --min-shared) min="$2" ;; --repo) repo="$2" ;;
        esac
        shift 2 ;;
      *) pr-die "unknown option: $1" ;;
    esac
  done
  [[ "$min" =~ ^[0-9]+$ ]] || pr-die "--min-shared must be a number"
  command -v jq >/dev/null 2>&1 || pr-die "jq is required" 3
  case "$sub" in
    list)     pr-list "$scope" "$today" ;;
    retire-enforced)
      [[ -d "$repo" ]] || pr-die "repo not a directory: $repo" 3
      pr-retire-enforced "$repo" "$apply" ;;
    tasks)
      [[ -r "$persona" ]] || pr-die "persona not readable: $persona" 3
      pr-tasks "$persona" "$scope" "$min" "$repo" ;;
    overlap|bucket|commands|size)
      [[ -r "$persona" ]] || pr-die "persona not readable: $persona" 3
      case "$sub" in
        overlap)  pr-decisions | pr-overlap "$persona" "$min" ;;
        size)     pr-size "$persona" "$capf" ;;
        bucket)   pr-bucket "$persona" "$scope" "$min" ;;
        commands) pr-commands "$persona" "$scope" "$min" ;;
      esac ;;
    *) pr-die "usage: persona-review.sh list|overlap|size|bucket|commands|tasks|retire-enforced [--apply] [--repo D] [--persona F] [--cap-file F] [--scope S] [--today D] [--min-shared N]" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  persona-review "$@"
fi
