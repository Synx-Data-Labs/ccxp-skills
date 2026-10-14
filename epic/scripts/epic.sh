#!/usr/bin/env bash
# Deterministic half of /epic: member resolution, drive filtering, refresh
# report, final report ordering. Judgment (running /drive, summarizing a failure)
# stays in epic/SKILL.md. Run from the repo toplevel; EPIC_DIR overrides dev/EPICS.
#
#   epic.sh file    <E1|path>                 resolve an epic file
#   epic.sh members <E1|path>                 id<TAB>title, epic-file order
#   epic.sh plan    <E1|path>                 id<TAB>verdict<TAB>detail<TAB>status<TAB>claimed_by<TAB>deadline<TAB>title
#   epic.sh next    <E1|path> [attempted-id…] first id whose verdict is "drive", not attempted
#   epic.sh record  <results> <id> <merged|failed|escalated> <summary>
#   epic.sh report  <E1|path> <results>       final report (merged, then next-iteration by priority)
#   epic.sh status  [E1|path]                 read-only progress + member table
#   epic.sh refresh [E1|path]                 epic-links sync+lint, moved/missing report, candidates
#
# verdict: drive | skip | external ; detail = reason (done, parked, peer:<who>, blocked:<Tid>, supervised, no-file)
# Sourceable (functions prefixed epic-); idempotent (only `refresh` writes: epic member links).
# Fields that may be empty are printed as "-" in `plan` so TSV columns never collapse.
_EPIC_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EPIC_ROOT="$(cd "$_EPIC_SELF/../.." && pwd)"
# shellcheck disable=SC1091
source "$_EPIC_ROOT/todo/scripts/_lib.sh"   # todo-fm-get, todo-claim-state (sets -euo pipefail)
# shellcheck disable=SC1091
source "$_EPIC_ROOT/_taskid/url.sh"         # taskid-path
# shellcheck disable=SC1091
source "$_EPIC_ROOT/_taskid/epic-links.sh"  # epic_links_sync / epic_links_lint

_EPIC_ID='T[0-9]{8}-[0-9]{6}'
_EPIC_MEMBER="^-[[:space:]]+\\[?(${_EPIC_ID})\\]?(\\([^)]*\\))?[[:space:]]*(— (.*))?\$"

function epic-dir() { printf '%s\n' "${EPIC_DIR:-dev/EPICS}"; }

# epic-file <E1|path> -> path; 1 if none. "E1" matches E1.md or E1-*.md.
function epic-file() {
  local arg="${1:-}" d f
  if [ -f "$arg" ]; then printf '%s\n' "$arg"; return 0; fi
  if [ -z "$arg" ]; then return 1; fi
  d="$(epic-dir)"
  for f in "$d/$arg.md" "$d/$arg"-*.md; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# epic-files [E1|path] -> one epic file per line (all when no arg)
function epic-files() {
  local f
  if [ -n "${1:-}" ]; then
    if ! f="$(epic-file "$1")"; then echo "epic: no epic file for '$1'" >&2; return 1; fi
    printf '%s\n' "$f"; return 0
  fi
  for f in "$(epic-dir)"/E*.md; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done
  return 0
}

# epic-members <E1|path> -> id<TAB>title, in epic-file order (both member-line forms)
function epic-members() {
  local f line
  if ! f="$(epic-file "${1:-}")"; then echo "epic: no epic file for '${1:-}'" >&2; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $_EPIC_MEMBER ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}"
    fi
  done < "$f"
  return 0
}

# epic-verdict <id> -> verdict<TAB>detail<TAB>status<TAB>claimed_by<TAB>deadline (empty fields -> "-")
function epic-verdict() {
  local id="$1" file status claim deadline cb v="drive" d="-" blocker
  if ! file="$(taskid-path "$id")"; then
    printf 'external\tno-file\t-\t-\t-\n'; return 0
  fi
  status="$(todo-fm-get "$file" status)"
  deadline="$(todo-fm-get "$file" deadline)"
  cb="$(todo-fm-get "$file" claimed_by)"
  case "$file" in
    dev/JOURNAL/*) v="skip"; d="done" ;;
    dev/PARKING/*) v="skip"; d="parked" ;;
    *)
      claim="$(todo-claim-state "$id")"
      if [[ "$status" == Done* ]]; then v="skip"; d="done"
      elif [[ "$status" == Parked* ]]; then v="skip"; d="parked"
      elif [[ "$claim" == peer:* ]]; then v="skip"; d="$claim"
      elif [[ "$status" == *SUPERVISED* || "$status" == *BLOCKED* ]]; then v="skip"; d="supervised"
      elif [[ "$status" =~ ^Blocked\ by\ (T[0-9]{8}-[0-9]{6}) ]]; then
        blocker="${BASH_REMATCH[1]}"
        if [ -n "$(find dev/TODO -maxdepth 1 -name "${blocker}-*.md" 2>/dev/null | head -n1)" ]; then
          v="skip"; d="blocked:$blocker"
        fi
      fi ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$v" "$d" "${status:--}" "${cb:--}" "${deadline:--}"
}

# epic-plan <E1|path> -> id<TAB>verdict<TAB>detail<TAB>status<TAB>claimed_by<TAB>deadline<TAB>title
function epic-plan() {
  local id title
  epic-file "${1:-}" >/dev/null || { echo "epic: no epic file for '${1:-}'" >&2; return 1; }
  while IFS=$'\t' read -r id title; do
    if [ -z "$id" ]; then continue; fi
    printf '%s\t%s\t%s\n' "$id" "$(epic-verdict "$id")" "$title"
  done < <(epic-members "$1")
  return 0
}

# epic-next <E1|path> [attempted-id…] -> first driveable, not-yet-attempted id; 1 if none.
# Recomputed from live state each call, so a merged task that unblocks another is seen.
function epic-next() {
  local epic="$1" id v rest
  shift || true
  while IFS=$'\t' read -r id v rest; do
    if [ "$v" = "drive" ] && [[ " $* " != *" $id "* ]]; then
      printf '%s\n' "$id"; return 0
    fi
  done < <(epic-plan "$epic" 2>/dev/null)   # stdout must be the bare id; claim probes may warn on stderr
  return 1
}

function epic-record() {
  local results="${1:?results file}" id="${2:?id}" outcome="${3:?outcome}" summary="${4:-}"
  summary="${summary//$'\t'/ }"; summary="${summary//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$id" "$outcome" "$summary" >> "$results"
}

# _epic-prio <id> <deadline|-> -> deadline<TAB>queue-pos<TAB>id (none = sorts last)
function _epic-prio() {
  local id="$1" dl="$2" pos
  if [ "$dl" = "-" ] || [ -z "$dl" ]; then dl="9999-12-31"; fi
  pos="$(bash "$_EPIC_ROOT/_queue/queue.sh" pos dev/TODO/queue.md "$id" 2>/dev/null)" || pos=""
  [[ "$pos" =~ ^[0-9]+$ ]] || pos=999999
  printf '%s\t%06d\t%s\n' "$dl" "$pos" "$id"
}

function _epic-action() {
  local outcome="$1" detail="$2"
  case "$outcome:$detail" in
    failed:*)       echo "fix the cause above, then /drive <id> (or re-run /epic drive)" ;;
    escalated:*)    echo "answer the NEEDS INPUT question, then /drive <id>" ;;
    skip:peer:*)    echo "coordinate with the claimant, or wait for the claim to go stale" ;;
    skip:blocked:*) echo "drive the blocker ${detail#blocked:} first" ;;
    skip:supervised) echo "operator-only: run it supervised, not via /epic drive" ;;
    skip:parked)    echo "revive from dev/PARKING if still wanted" ;;
    *)              echo "review manually" ;;
  esac
}

# epic-report <E1|path> <results> — merged list, then outstanding work by priority.
# results = TSV from `record` (id, outcome, summary). Skips come from the CURRENT plan.
function epic-report() {
  local epic="$1" results="${2:-}" id outcome summary v d st cb dl title n=0 f
  local tmp extra=""
  if ! f="$(epic-file "$epic")"; then echo "epic: no epic file for '$epic'" >&2; return 1; fi
  tmp="$(mktemp)"
  printf '## Epic %s drive report\n\n### Merged\n' "$(basename "$f" .md)"
  if [ -n "$results" ] && [ -f "$results" ]; then
    while IFS=$'\t' read -r id outcome summary; do
      case "$outcome" in
        merged) printf -- '- %s — %s\n' "$id" "$summary"; n=$((n+1)) ;;
        failed|escalated) printf '%s\t%s\t-\t%s\n' "$id" "$outcome" "$summary" >> "$tmp" ;;
      esac
    done < "$results"
  fi
  if [ "$n" -eq 0 ]; then echo "- (none)"; fi
  while IFS=$'\t' read -r id v d st cb dl title; do
    if [ "$v" = "skip" ] && [ "$d" != "done" ] && ! grep -q "^${id}"$'\t' "$tmp"; then
      printf '%s\tskip\t%s\t%s\n' "$id" "$d" "$title" >> "$tmp"
    elif [ "$v" = "external" ]; then
      extra="${extra}- ${id} — ${title} (other repo: not driveable from here)"$'\n'
    fi
  done < <(epic-plan "$epic")
  printf '\n### For the next iteration (by priority: deadline, then queue position)\n'
  if [ ! -s "$tmp" ]; then echo "- (nothing outstanding)"; fi
  local tf dlk
  while IFS=$'\t' read -r id outcome d summary; do
    dlk="-"
    if tf="$(taskid-path "$id" 2>/dev/null)"; then dlk="$(todo-fm-get "$tf" deadline)"; fi
    printf '%s\t%s\t%s\t%s\n' "$(_epic-prio "$id" "${dlk:--}")" "$outcome" "$d" "$summary"
  done < "$tmp" | sort -t$'\t' -k1,1 -k2,2n -k3,3 | while IFS=$'\t' read -r dl _pos id outcome d summary; do
    local due=""
    if [ "$dl" != "9999-12-31" ]; then due=", due $dl"; fi
    printf -- '- %s [%s%s] — %s\n  next: %s\n' "$id" "$outcome" "$due" "${summary:-$d}" "$(_epic-action "$outcome" "$d")"
  done
  if [ -n "$extra" ]; then printf '\n### Not driveable from here\n%s' "$extra"; fi
  rm -f "$tmp"
  return 0
}

# epic-status [E1|path] — read-only: per-member table, then the standup roll-up.
function epic-status() {
  local f id v d st cb dl title
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    printf '### %s\n| Task | Status | Claimed | Deadline | Drive verdict | Title |\n|---|---|---|---|---|---|\n' "$(basename "$f" .md)"
    while IFS=$'\t' read -r id v d st cb dl title; do
      printf '| %s | %s | %s | %s | %s (%s) | %s |\n' "$id" "$st" "$cb" "$dl" "$v" "$d" "$title"
    done < <(epic-plan "$f")
    printf '\n'
  done < <(epic-files "${1:-}")
  bash "$_EPIC_ROOT/ccxp/scripts/epic-status.sh" render 2>/dev/null || true
  return 0
}

# epic-candidates <epic-file> — open TODO tasks that are not members but look related:
# linked via related:/blocks:/blocked-by: from/to a member, or sharing a title keyword.
function epic-candidates() {
  local f="$1" eid words w t id tf title why members rel linked
  eid="$(basename "$f" .md)"; eid="${eid%%-*}"
  words="$(sed -n -E 's/^#+ E[0-9]+ — //p' "$f" | head -n1 | tr -c 'A-Za-z0-9\n' ' ' | tr ' ' '\n' | awk 'length($0)>=5' | tr '[:upper:]' '[:lower:]' | sort -u)"
  members="$(epic-members "$f" | cut -f1)"
  rel=""
  for id in $members; do
    if tf="$(taskid-path "$id" 2>/dev/null)"; then
      rel="$rel $(grep -E '^(related|blocks|blocked-by):' "$tf" | grep -oE "$_EPIC_ID" | tr '\n' ' ' || true)"
    fi
  done
  for t in dev/TODO/T*.md; do
    if [ ! -f "$t" ]; then continue; fi
    id="$(basename "$t" | grep -oE "^${_EPIC_ID}" || true)"
    if [ -z "$id" ] || grep -qx "$id" <<<"$members"; then continue; fi
    title="$(sed -n -E "s/^# ${id}: *//p" "$t" | head -n1)"
    why=""
    if [[ " $rel " == *" $id "* ]]; then why="linked from a member (related/blocks)"; fi
    if [ -z "$why" ]; then
      linked="$(grep -E '^(related|blocks|blocked-by):' "$t" | grep -oE "$_EPIC_ID" || true)"
      for w in $linked; do
        if grep -qx "$w" <<<"$members"; then why="links member $w"; break; fi
      done
    fi
    if [ -z "$why" ] && grep -qiE "\\b${eid}\\b" <<<"$title"; then why="title names $eid"; fi
    if [ -z "$why" ]; then
      for w in $words; do
        if grep -qiF -- "$w" <<<"$title"; then why="title keyword '$w'"; break; fi
      done
    fi
    if [ -n "$why" ]; then printf '%s\t%s\t%s\n' "$id" "$why" "$title"; fi
  done
  return 0
}

# epic-refresh [E1|path] — sync member links (the only write), lint, report, list candidates.
# epic_links_sync covers every epic file; the report is limited to the requested ones.
function epic-refresh() {
  local f before errs rc=0 out
  local tdir
  tdir="$(mktemp -d)"
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    cp "$f" "$tdir/$(basename "$f")"
  done < <(epic-files "${1:-}")
  errs="$(mktemp)"
  epic_links_sync 2>"$errs" || true
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    before="$tdir/$(basename "$f")"
    printf '### %s\n' "$f"
    out="$(diff "$before" "$f" | grep -E '^[<>] -' || true)"
    if [ -n "$out" ]; then sed -E 's/^< /moved from: /; s/^> /          to: /' <<<"$out"; else echo "links: unchanged"; fi
    grep -F " in $f " "$errs" | sed 's/^epic-links: /plain, not driveable from here: /' || true
    if epic_links_lint 2>&1 | grep -F "$f"; then rc=1; else echo "lint: ok"; fi
    echo "candidates (not members; propose only, never auto-added):"
    out="$(epic-candidates "$f")"
    if [ -n "$out" ]; then sed 's/^/  - /' <<<"$out"; else echo "  (none)"; fi
  done < <(epic-files "${1:-}")
  rm -rf "$tdir" "$errs"
  return "$rc"
}

function epic-main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    file) epic-file "$@" ;;
    members) epic-members "$@" ;;
    plan) epic-plan "$@" ;;
    next) epic-next "$@" ;;
    record) epic-record "$@" ;;
    report) epic-report "$@" ;;
    status) epic-status "$@" ;;
    refresh) epic-refresh "$@" ;;
    *) echo "Usage: epic.sh file|members|plan|next|record|report|status|refresh …" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  epic-main "$@"
fi
