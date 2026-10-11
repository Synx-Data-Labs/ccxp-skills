#!/usr/bin/env bash
# epic-status.sh fetch
# epic-status.sh resolve <Tid>
# epic-status.sh render [--slack]
#
# ccxp Phase 1.3/1.4 (T20260911-347027): rolls the hourly `/ccxp` standup up
# from individual tasks/PRs to the 3-5 standing epics the maintainer actually
# steers by. Reads a human-owned `dev/EPICS.md` **local to this repo's
# toplevel** and renders it deterministically — no LLM summarization, so the
# output can be spot-checked and diffed like any script output.
#
# Made local-only by T20261005-639913 (dropped the global `ROADMAP_TARGET_REPO`
# hub config — every repo now owns its own `dev/ROADMAP.md` / `dev/EPICS.md`).
# This file used to read `dev/EPICS.md` out of a separate hub repo over the
# GitHub Contents API, which needed its own cross-repo gh-account-picking
# (`_gh_pick_account`/`_epic_gh_token`) because `_gh/gh.sh`'s plain CLI form
# always derives its target repo from `$PWD`'s own `git remote get-url
# origin` and has no `--repo` override. With `dev/EPICS.md` local, every read
# in this file is now a plain local-repo operation — no hub, no cross-repo
# token, no `gh api repos/.../contents/...` call anywhere.
#
# READ-ONLY on the daily path (Phase 1.3/1.4) — this script never writes to
# `dev/EPICS.md`. `dev/EPICS.md` is human-owned; Phase 2b (Friday retro) may
# propose edits to it, but as a plain local file edit in the retro's own
# commit, not through anything in this file.
#
# Fail-quiet everywhere: this script's output feeds an hourly standup that
# must never block on a missing/misconfigured `EPICS.md` — every failure mode
# (file missing, unreadable, an unresolvable task id) degrades to a one-line
# note or an `unknown` row, never a non-zero exit to the caller.
set -euo pipefail

# Resolve sibling scripts relative to this script's own directory, not a
# hardcoded install path — same pattern as elsewhere in this suite.
# Overridable via SKILLS_ROOT for tests.
SKILLS_ROOT="${SKILLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# taskid-path / taskid-repo-slug — public, documented-sourceable functions
# (same file _session/task-state.sh sources directly).
# shellcheck disable=SC1091
source "$SKILLS_ROOT/_taskid/url.sh"

# --- frontmatter read (pure; own copy, first fence only, per the
# ts_fm_get/_tc_fm_get convention — each sourceable script that needs this
# keeps its own copy rather than reaching into another script's
# underscore-private internals) ---------------------------------------------

_epic_fm_get() {
  local file="$1" field="$2"
  [ -r "$file" ] || return 1
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm {
      if (index($0, f":") == 1) {
        v = substr($0, length(f) + 2)
        sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

# --- date compat (pure; own copy of _tc_iso_to_epoch) -----------------------

_epic_iso_to_epoch() {
  # $1 ISO-8601 UTC → epoch seconds, or empty. GNU date then BSD date.
  local iso="$1" e
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  printf ''
}

# --- fetch -------------------------------------------------------------------

epic_fetch() {
  # stdout: path to the local dev/EPICS.md; return 1 (silent — no stderr) if
  # it doesn't exist or isn't readable. Pure I/O primitive — the
  # human-readable "epics unavailable" note is epic_render's job, not this
  # function's.
  local f="dev/EPICS.md"
  [ -r "$f" ] || return 1
  printf '%s\n' "$f"
}

# --- EPICS.md parser (portable line-oriented bash; no gawk-only features) ---

epic_parse_file() {
  # stdout: a flat TSV, one record per line, 3 columns
  # (KIND\tEPIC_ID\tVALUE), KIND in {EPIC, GOAL, DONE, DEADLINE, TASK}.
  local file="$1" cur="" line title val
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "### E"*)
        cur="$(printf '%s' "$line" | sed -E 's/^### (E[0-9]+) .*/\1/')"
        title="$(printf '%s' "$line" | sed -E 's/^### E[0-9]+ — //')"
        printf 'EPIC\t%s\t%s\n' "$cur" "$title" ;;
      "Goal:"*)      [ -n "$cur" ] && { val="${line#Goal:}";      printf 'GOAL\t%s\t%s\n'     "$cur" "${val#"${val%%[![:space:]]*}"}"; } ;;
      "Done when:"*) [ -n "$cur" ] && { val="${line#Done when:}"; printf 'DONE\t%s\t%s\n'     "$cur" "${val#"${val%%[![:space:]]*}"}"; } ;;
      "Deadline:"*)  [ -n "$cur" ] && { val="${line#Deadline:}";  printf 'DEADLINE\t%s\t%s\n' "$cur" "${val#"${val%%[![:space:]]*}"}"; } ;;
      "- T"*)
        if [ -n "$cur" ]; then
          # NOT `... | grep -oE ... | head -1`: a live producer piped into a
          # consumer that can exit before reading everything (`head -1`, an
          # `awk`/`grep` that `exit`s on its first match) races that
          # producer for a SIGPIPE — the producer's `write()` can land after
          # the consumer's read end is already closed. Under this script's
          # `set -e`+`pipefail`, that SIGPIPE (bash reports it as the
          # pipeline exiting 141) aborts the WHOLE script, and it is a real,
          # timing-dependent flake (reproduced empirically under load, not
          # hypothetical) — never just a style preference. Fix: take the
          # producer's FULL output first (a here-string has no live writer
          # to race — bash fully materializes it before the single reader
          # ever runs), then peel off "first match"/"first line" with pure
          # parameter expansion, no further piping. Applied everywhere in
          # this file that used to pipe into head/awk-exit/grep -q.
          val="$(grep -oE 'T[0-9]{8}-[0-9]{6}' <<<"$line")"
          val="${val%%$'\n'*}"
          [ -n "$val" ] && printf 'TASK\t%s\t%s\n' "$cur" "$val"
        fi ;;
    esac
  done < "$file"
  return 0
}

_epic_field() {
  # $1 parsed-tsv  $2 kind  $3 epic-id → the VALUE column of the first match.
  # Here-string, not `printf ... | awk`: see epic_parse_file's SIGPIPE note —
  # this awk `exit`s on its first match, which is the exact hazard.
  local parsed="$1" kind="$2" eid="$3"
  awk -F'\t' -v k="$kind" -v e="$eid" \
    '$1==k && $2==e { sub(/^[^\t]*\t[^\t]*\t/,""); print; exit }' <<<"$parsed"
}

_epic_tasks_for() {
  # $1 parsed-tsv  $2 epic-id → one task id per line, in file order.
  local parsed="$1" eid="$2"
  awk -F'\t' -v e="$eid" '$1=="TASK" && $2==e {print $3}' <<<"$parsed"
}

# --- resolve -------------------------------------------------------------

epic_resolve() {
  # $1 id → one TSV line, 5 columns: status\tclaimed_by\trepo\tpath\tepoch.
  # NEVER returns non-zero — "unknown" is a valid, expected outcome (a
  # typo'd/deleted id), not a script error; render checks the status column,
  # not the exit code. Local-only (T20261005-639913): no hub fallback.
  local id="${1:-}"
  # Reachable with raw, unvalidated argv from `main`'s `resolve` dispatch
  # (unlike every other caller, which only ever passes ids already
  # extracted via epic_parse_file's strict T-id regex) — a shape check here
  # closes that off before $id reaches taskid-path.
  [[ "$id" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || { printf 'unknown\t\t\t\t\n'; return 0; }

  local file
  if file="$(taskid-path "$id" 2>/dev/null)"; then
    local repo status claimed epoch
    repo="$(taskid-repo-slug 2>/dev/null)" || repo=""
    status="$(_epic_fm_get "$file" status)" || status=""
    claimed="$(_epic_fm_get "$file" claimed_by)" || claimed=""
    epoch="$(git log -1 --format=%ct -- "$file" 2>/dev/null)" || epoch=""
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$claimed" "$repo" "$file" "$epoch"
    return 0
  fi

  printf 'unknown\t\t\t\t\n'
  return 0
}

# --- bucket + rank (pure, no I/O) -------------------------------------------

_epic_status_bucket() {
  # All 7 lifecycle.md statuses get a distinct case arm (Blocked* prefix-
  # matches "Blocked by T…") — empty/anything-else is "unknown", never
  # silently folded into "Open" (the bug this task exists to fix: a
  # Done/In Progress/Blocked/Open-only enumeration would mis-bucket a Design
  # task).
  local status="$1"
  case "$status" in
    Done)      printf 'Done' ;;
    Review)    printf 'Review' ;;
    "In Progress") printf 'In Progress' ;;
    Design)    printf 'Design' ;;
    Blocked*)  printf 'Blocked' ;;
    Parked)    printf 'Parked' ;;
    Open)      printf 'Open' ;;
    *)         printf 'unknown' ;;
  esac
}

_epic_status_rank() {
  # Used only to pick the epic's single "Leading" task (highest rank;
  # first-listed in EPICS.md wins ties — see epic_render).
  local status="$1"
  case "$status" in
    Done)      printf '6' ;;
    Review)    printf '5' ;;
    "In Progress") printf '4' ;;
    Design)    printf '3' ;;
    Blocked*)  printf '2' ;;
    Parked)    printf '2' ;;
    Open)      printf '1' ;;
    *)         printf '0' ;;
  esac
}

# --- PR lookup (only for the one Leading task per epic) ---------------------

epic_pr_state() {
  # $1 id  $2 repo → "PR #N STATE" or "no PR". Only called for a bounded
  # number of ids per render (the leading task of each epic), not every
  # task. Always local now (T20261005-639913) — $repo is this clone's own
  # repo, so the plain `_gh/gh.sh` CLI form (account picked from $PWD's own
  # origin) is correct; no cross-repo token-picking needed anywhere in this
  # file any more.
  local id="${1:-}" repo="${2:-}" line=""
  if [ -z "$id" ]; then
    printf 'no PR\n'
    return 0
  fi
  if [ -n "$repo" ]; then
    line="$(bash "$SKILLS_ROOT/_gh/gh.sh" pr list --repo "$repo" --search "$id" --state all --limit 1 \
            --json number,state --jq '.[0] | "PR #\(.number) \(.state)"' 2>/dev/null)" || line=""
  else
    line="$(bash "$SKILLS_ROOT/_gh/gh.sh" pr list --search "$id" --state all --limit 1 \
            --json number,state --jq '.[0] | "PR #\(.number) \(.state)"' 2>/dev/null)" || line=""
  fi
  if [ -n "$line" ]; then printf '%s\n' "$line"; else printf 'no PR\n'; fi
}

# --- render ------------------------------------------------------------------

epic_render() {
  local mode="text"
  [ "${1:-}" = "--slack" ] && mode="slack"

  local reason="" epics_file=""
  if ! epics_file="$(epic_fetch)"; then
    reason="dev/EPICS.md not found or unreadable"
  fi

  if [ -n "$reason" ]; then
    [ "$mode" = "text" ] && printf 'Epics unavailable — %s.\n' "$reason"
    return 0
  fi

  local parsed
  parsed="$(epic_parse_file "$epics_file")" || true
  # dev/EPICS.md is a real repo file now (not a downloaded tmp copy) — never
  # rm it.

  # Here-string, not `printf ... | grep -q` — see epic_parse_file's SIGPIPE
  # note (grep -q exits on its first match, the exact hazard).
  if ! grep -q $'EPIC\t' <<<"$parsed"; then
    [ "$mode" = "text" ] && printf 'No epics defined in dev/EPICS.md.\n'
    return 0
  fi

  local now first_block=1
  now=$(date +%s)

  local epic_ids
  epic_ids="$(awk -F'\t' '$1=="EPIC"{print $2}' <<<"$parsed")"

  while IFS= read -r eid; do
    [ -n "$eid" ] || continue
    local title goal deadline
    title="$(_epic_field "$parsed" EPIC "$eid")"
    goal="$(_epic_field "$parsed" GOAL "$eid")"
    deadline="$(_epic_field "$parsed" DEADLINE "$eid")"

    local -A counts=()
    local leading_id="" leading_repo="" leading_status="" leading_rank=-1
    local max_epoch="" unresolved="" n_tasks=0

    local tids
    tids="$(_epic_tasks_for "$parsed" "$eid")"
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      n_tasks=$((n_tasks + 1))
      local row fields status repo epoch
      row="$(epic_resolve "$tid")"
      # NOT `IFS=$'\t' read -r ... <<<"$row"`: tab is "IFS whitespace" to
      # bash's `read` regardless of what IFS is set to, so consecutive tabs
      # (any empty column — claimed_by is routinely empty) collapse and
      # silently shift every field after it. awk's -F'\t' treats tab as a
      # literal single-char separator with no such collapsing, so split
      # through it instead (verified: `printf 'x\t\ty' | IFS=$'\t' read -r a
      # b c` gives b="y" c="", not b="" c="y"). Columns: status, claimed_by
      # (unused here), repo, path (unused here), epoch.
      mapfile -t fields < <(awk -F'\t' '{for (i=1;i<=5;i++) print $i}' <<<"$row")
      status="${fields[0]}"; repo="${fields[2]}"; epoch="${fields[4]}"
      if [ -z "$status" ] || [ "$status" = "unknown" ]; then
        unresolved="${unresolved}${tid}"$'\n'
        continue
      fi
      local bucket rank
      bucket="$(_epic_status_bucket "$status")"
      counts[$bucket]=$(( ${counts[$bucket]:-0} + 1 ))
      rank="$(_epic_status_rank "$status")"
      if [ "$rank" -gt "$leading_rank" ]; then
        leading_rank="$rank"; leading_id="$tid"; leading_repo="$repo"; leading_status="$status"
      fi
      if [ -n "$epoch" ] && { [ -z "$max_epoch" ] || [ "$epoch" -gt "$max_epoch" ]; }; then
        max_epoch="$epoch"
      fi
    done <<<"$tids"

    local stale=0
    if [ -z "$max_epoch" ] || [ $(( now - max_epoch )) -ge $(( 7 * 86400 )) ]; then
      stale=1
    fi

    local pr_line="no PR"
    [ -n "$leading_id" ] && pr_line="$(epic_pr_state "$leading_id" "$leading_repo")"

    if [ "$mode" = "text" ]; then
      [ "$first_block" -eq 1 ] || printf '\n'
      first_block=0
      printf '### %s — %s\n' "$eid" "$title"
      printf 'Goal: %s\n' "$goal"
      printf '%d tasks: %d Done \xc2\xb7 %d Review \xc2\xb7 %d In Progress \xc2\xb7 %d Design \xc2\xb7 %d Blocked/Parked \xc2\xb7 %d Open\n' \
        "$n_tasks" "${counts[Done]:-0}" "${counts[Review]:-0}" "${counts[In Progress]:-0}" \
        "${counts[Design]:-0}" "$(( ${counts[Blocked]:-0} + ${counts[Parked]:-0} ))" "${counts[Open]:-0}"
      [ -n "$leading_id" ] && printf 'Leading: %s %s (%s)\n' "$leading_id" "$leading_status" "$pr_line"
      if [ -n "$deadline" ]; then
        local dl_epoch k
        dl_epoch="$(_epic_iso_to_epoch "${deadline}T00:00:00Z")"
        if [ -n "$dl_epoch" ]; then
          k=$(( (dl_epoch - now) / 86400 ))
          printf 'Deadline: %s (%d days)\n' "$deadline" "$k"
        fi
      fi
      [ "$stale" -eq 1 ] && printf '\xe2\x9a\xa0 stale: no task under this epic changed in \xe2\x89\xa57 days\n'
      if [ -n "$unresolved" ]; then
        while IFS= read -r uid; do
          [ -n "$uid" ] && printf '\xe2\x9a\xa0 %s unresolved\n' "$uid"
        done <<<"$unresolved"
      fi
    else
      # Real UTF-8 bytes via ANSI-C quoting, not literal \xHH escapes fed
      # through `printf '%b'` — %b re-interprets EVERY backslash escape in
      # its argument, including any that happen to originate from
      # repo-authored $title/$leading_status text (a literal "\c" in an
      # EPICS.md title would make %b silently stop producing output mid-line).
      # Building the markers as real bytes up front and printing with %s
      # means no runtime escape interpretation ever touches interpolated
      # content.
      local em=$'\xe2\x80\x94' dot=$'\xc2\xb7' warn=$'\xe2\x9a\xa0'
      local line
      line="*${eid} ${em} ${title}*: ${counts[Done]:-0}D/${counts[Review]:-0}R/${counts[In Progress]:-0}I/${counts[Design]:-0}Dsg/$(( ${counts[Blocked]:-0} + ${counts[Parked]:-0} ))B${dot}P/${counts[Open]:-0}O"
      if [ -n "$leading_id" ]; then
        line="${line} ${em} leading ${leading_id} (${leading_status}"
        [ "$pr_line" != "no PR" ] && line="${line}, ${pr_line}"
        line="${line})"
      fi
      [ "$stale" -eq 1 ] && line="${line} ${dot} ${warn} stale"
      local n_unresolved=0
      [ -n "$unresolved" ] && n_unresolved=$(grep -c . <<<"$unresolved")
      [ "$n_unresolved" -gt 0 ] && line="${line} ${dot} ${warn} ${n_unresolved} unresolved"
      printf '%s\n' "$line"
    fi
  done <<<"$epic_ids"
  return 0
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    fetch)   epic_fetch "$@" ;;
    resolve) epic_resolve "$@" ;;
    render)  epic_render "$@" ;;
    *) echo "Usage: epic-status.sh fetch | resolve <Tid> | render [--slack]" >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced) — lets tests source this file
# and call individual functions without invoking main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
