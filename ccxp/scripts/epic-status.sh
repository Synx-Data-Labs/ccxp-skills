#!/usr/bin/env bash
# epic-status.sh fetch
# epic-status.sh resolve <Tid>
# epic-status.sh render [--slack]
#
# ccxp Phase 1.3/1.4 (T20260911-347027): rolls the hourly `/ccxp` standup up
# from individual tasks/PRs to the 3-5 standing epics the maintainer actually
# steers by. Reads a human-owned `dev/EPICS.md` in a separate hub repo (the
# same `ROADMAP_TARGET_REPO` config `ccxp/scripts/update-roadmap.sh` already
# uses) and renders it deterministically — no LLM summarization, so the
# output can be spot-checked and diffed like any script output.
#
# READ-ONLY on the daily path (Phase 1.3/1.4) — this script never writes to
# `dev/EPICS.md`. Phase 2b (Friday retro) is the only write path, and it
# reuses `update-roadmap.sh`'s own `clone`/`commit-pr` machinery rather than
# anything in this file.
#
# Cross-repo account scoping (the reason this file doesn't just shell out to
# `_gh/gh.sh`'s CLI form): `_gh/gh.sh main()` (_gh/gh.sh:94-101) always
# derives its target slug from `git remote get-url origin` of `$PWD`
# (_gh/gh.sh:38-51) — it has no `--repo` override. `update-roadmap.sh` only
# gets away with calling it for the hub repo because it `cd`s into a real
# clone of that hub repo first (roadmap_commit_pr). This script has no clone
# step — it does single-file API reads from wherever it's invoked (a
# consumer repo's working directory) — so a bare `_gh/gh.sh api
# repos/$ROADMAP_TARGET_REPO/...` run from there would pick a gh account
# proven to access the *consumer* repo, not the hub — silently wrong on a
# multi-account box. Fix: source `_gh/gh.sh` (its own header documents this
# as supported — "lets tests source this file and call individual
# functions... without invoking main") and call
# `_gh_pick_account "$ROADMAP_TARGET_REPO"` directly for the hub-scoped
# token, then invoke `GH_TOKEN=... gh api|pr list --repo "$ROADMAP_TARGET_REPO"`
# explicitly. Every cross-repo call in this file goes through
# `_epic_gh_token` below and also passes an explicit repo-qualified
# argument — `gh pr list --search <id>` alone silently scopes to `$PWD`'s
# repo too.
#
# Fail-quiet everywhere: unlike update-roadmap.sh's fail-LOUD clone/commit-pr
# (a scheduled write the maintainer must notice failed), this script's output
# feeds an hourly standup that must never block on a missing/misconfigured
# hub — every failure mode (ROADMAP_TARGET_REPO unset, EPICS.md unreadable,
# an unresolvable task id) degrades to a one-line note or an `unknown` row,
# never a non-zero exit to the caller.
set -euo pipefail

# Resolve sibling scripts relative to this script's own directory, not a
# hardcoded install path — same pattern as update-roadmap.sh. Overridable
# via SKILLS_ROOT for tests.
SKILLS_ROOT="${SKILLS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

ROADMAP_TARGET_REPO="${ROADMAP_TARGET_REPO:-}"

# Load ROADMAP_TARGET_REPO from ~/.claude/.env (machine-global) when not
# already exported — same resolution order and ENV_FILE test seam as
# update-roadmap.sh's _update_roadmap_load_env (already-exported wins, else
# $ENV_FILE, else skipped under BATS, else ~/.claude/.env). This is a
# separate, OWN copy rather than a sourced call to that function: it is
# effectively private to update-roadmap.sh (same rationale as
# _session/task-state.sh's ts_fm_get vs task_claim.sh's _tc_fm_get — each
# sourceable script that needs the pattern keeps its own copy rather than
# reaching into another script's underscore-private internals).
#
# Both `source` calls below are `|| true`-guarded for the same reason
# documented in update-roadmap.sh: ~/.claude/.env is a shared, hand-edited,
# machine-global file carrying many unrelated vars — a failing last
# statement there must degrade this script to "unset", not abort it under
# set -e before ROADMAP_TARGET_REPO is even checked.
_epic_status_load_env() {
  [ -n "$ROADMAP_TARGET_REPO" ] && return 0
  if [ -n "${ENV_FILE:-}" ]; then
    [ -f "$ENV_FILE" ] && { # shellcheck disable=SC1090
      source "$ENV_FILE" || true; }
    return 0
  fi
  [ -n "${BATS_TEST_TMPDIR:-}" ] && return 0
  if [ -f "$HOME/.claude/.env" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.claude/.env" || true
  fi
}
_epic_status_load_env
ROADMAP_TARGET_REPO="${ROADMAP_TARGET_REPO:-}"

# taskid-path / taskid-repo-slug — public, documented-sourceable functions
# (same file _session/task-state.sh sources directly).
# shellcheck disable=SC1091
source "$SKILLS_ROOT/_taskid/url.sh"

# --- frontmatter read (pure; own copy, first fence only, per the
# ts_fm_get/_tc_fm_get convention — see the env-loader comment above) -------

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

# --- cross-repo gh-account scoping (the core fix — see header comment) -----

_epic_gh_token() {
  # stdout: a GH token scoped to $ROADMAP_TARGET_REPO, or return 1.
  [ -n "$ROADMAP_TARGET_REPO" ] || return 1
  # shellcheck disable=SC1091
  source "$SKILLS_ROOT/_gh/gh.sh"   # sourced, not exec'd — bypasses main()'s
                                     # $PWD-derived repo slug (_gh/gh.sh:94-101).
                                     # Idempotent (function redefinition), so
                                     # calling this more than once per run is
                                     # harmless.
  local user
  user="$(_gh_pick_account "$ROADMAP_TARGET_REPO")" || return 1
  _gh_token_for "$user"
}

# --- fetch -------------------------------------------------------------------

epic_fetch() {
  # stdout: path to a tmp file holding the decoded dev/EPICS.md; return 1
  # (silent — no stderr) on: ROADMAP_TARGET_REPO unset, no gh account can
  # access it, or the file 404s. Pure I/O primitive — the human-readable
  # "epics unavailable" note is epic_render's job, not this function's.
  [ -n "$ROADMAP_TARGET_REPO" ] || return 1
  local tok b64 tmp
  tok="$(_epic_gh_token)" || return 1
  b64="$(GH_TOKEN="$tok" gh api "repos/$ROADMAP_TARGET_REPO/contents/dev/EPICS.md?ref=main" \
         --jq '.content // ""' 2>/dev/null)" || return 1
  [ -n "$b64" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/epic-status-epics.XXXXXX")" || return 1
  printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  printf '%s' "$tmp"
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

_epic_hub_lookup() {
  # $1 id → stdout "dev/<DIR>/<filename>"; return 1 if not found in the hub's
  # TODO/PARKING/JOURNAL (in that precedence order — same as taskid-path's
  # local precedence and _tc_resolve_task_location's hub search shape).
  local id="$1" tok dir names name
  tok="$(_epic_gh_token)" || return 1
  for dir in dev/TODO dev/PARKING dev/JOURNAL; do
    names="$(GH_TOKEN="$tok" gh api "repos/$ROADMAP_TARGET_REPO/contents/$dir?ref=main" \
             --jq ".[] | select(.name | startswith(\"$id\")) | .name" 2>/dev/null)" || continue
    # Pure parameter expansion, not `| head -1` — see epic_parse_file's
    # SIGPIPE note (a live producer racing an early-exiting consumer).
    name="${names%%$'\n'*}"
    if [ -n "$name" ]; then
      printf '%s/%s\n' "$dir" "$name"
      return 0
    fi
  done
  return 1
}

epic_resolve() {
  # $1 id → one TSV line, 6 columns: status\tclaimed_by\tsource\trepo\tpath\tepoch.
  # NEVER returns non-zero — "unknown" is a valid, expected outcome (a
  # typo'd/deleted id), not a script error; render checks the status column,
  # not the exit code.
  local id="${1:-}"
  # Reachable with raw, unvalidated argv from `main`'s `resolve` dispatch
  # (unlike every other caller, which only ever passes ids already
  # extracted via epic_parse_file's strict T-id regex) — a shape check here
  # closes that off before $id ever reaches _epic_hub_lookup's --jq string
  # interpolation (harmless today since jq has no shell-exec primitive
  # reachable that way, but cheap to make impossible rather than merely
  # safe).
  [[ "$id" =~ ^T[0-9]{8}-[0-9]{6}$ ]] || { printf 'unknown\t\t\t\t\t\n'; return 0; }

  local file
  if file="$(taskid-path "$id" 2>/dev/null)"; then
    local repo status claimed epoch
    repo="$(taskid-repo-slug 2>/dev/null)" || repo=""
    status="$(_epic_fm_get "$file" status)" || status=""
    claimed="$(_epic_fm_get "$file" claimed_by)" || claimed=""
    epoch="$(git log -1 --format=%ct -- "$file" 2>/dev/null)" || epoch=""
    printf '%s\t%s\tlocal\t%s\t%s\t%s\n' "$status" "$claimed" "$repo" "$file" "$epoch"
    return 0
  fi

  if [ -n "$ROADMAP_TARGET_REPO" ]; then
    local hub_path
    if hub_path="$(_epic_hub_lookup "$id")"; then
      local tok b64 tmp status="" claimed="" epoch=""
      tok="$(_epic_gh_token)" || { printf 'unknown\t\t\t\t\t\n'; return 0; }
      b64="$(GH_TOKEN="$tok" gh api "repos/$ROADMAP_TARGET_REPO/contents/$hub_path?ref=main" \
             --jq '.content // ""' 2>/dev/null)" || b64=""
      if [ -n "$b64" ]; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/epic-status-hub.XXXXXX")" || { printf 'unknown\t\t\t\t\t\n'; return 0; }
        if printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null; then
          status="$(_epic_fm_get "$tmp" status)" || status=""
          claimed="$(_epic_fm_get "$tmp" claimed_by)" || claimed=""
        fi
        rm -f "$tmp"
      fi
      if [ -z "$status" ]; then
        printf 'unknown\t\t\t\t\t\n'
        return 0
      fi
      local iso
      iso="$(GH_TOKEN="$tok" gh api "repos/$ROADMAP_TARGET_REPO/commits?path=$hub_path&per_page=1" \
             --jq '.[0].commit.committer.date // ""' 2>/dev/null)" || iso=""
      [ -n "$iso" ] && epoch="$(_epic_iso_to_epoch "$iso")"
      printf '%s\t%s\thub\t%s\t%s\t%s\n' "$status" "$claimed" "$ROADMAP_TARGET_REPO" "$hub_path" "$epoch"
      return 0
    fi
  fi

  printf 'unknown\t\t\t\t\t\n'
  return 0
}

# --- bucket + rank (pure, no I/O) -------------------------------------------

_epic_status_bucket() {
  # All 7 lifecycle.md statuses get a distinct case arm (Blocked* prefix-
  # matches "Blocked by T…") — empty/anything-else is "unknown", never
  # silently folded into "Open" (the bug this task exists to fix: a
  # Done/Coding/Blocked/Open-only enumeration would mis-bucket a Design task).
  local status="$1"
  case "$status" in
    Done)      printf 'Done' ;;
    Review)    printf 'Review' ;;
    Coding)    printf 'Coding' ;;
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
    Coding)    printf '4' ;;
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
  # number of ids per render (the leading task of each epic), not every task.
  local id="${1:-}" repo="${2:-}" line=""
  if [ -z "$id" ] || [ -z "$repo" ]; then
    printf 'no PR\n'
    return 0
  fi
  if [ -n "$ROADMAP_TARGET_REPO" ] && [ "$repo" = "$ROADMAP_TARGET_REPO" ]; then
    local tok
    tok="$(_epic_gh_token)" || { printf 'no PR\n'; return 0; }
    line="$(GH_TOKEN="$tok" gh pr list --repo "$repo" --search "$id" --state all --limit 1 \
            --json number,state --jq '.[0] | "PR #\(.number) \(.state)"' 2>/dev/null)" || line=""
  else
    # LOCAL repo (the task resolved in *this* clone) — $PWD already IS that
    # repo, so the plain _gh/gh.sh CLI form (account picked from $PWD's own
    # origin) is correct here, unlike every cross-repo call above.
    line="$(bash "$SKILLS_ROOT/_gh/gh.sh" pr list --repo "$repo" --search "$id" --state all --limit 1 \
            --json number,state --jq '.[0] | "PR #\(.number) \(.state)"' 2>/dev/null)" || line=""
  fi
  if [ -n "$line" ]; then printf '%s\n' "$line"; else printf 'no PR\n'; fi
}

# --- render ------------------------------------------------------------------

epic_render() {
  local mode="text"
  [ "${1:-}" = "--slack" ] && mode="slack"

  local reason=""
  if [ -z "$ROADMAP_TARGET_REPO" ]; then
    reason="ROADMAP_TARGET_REPO is not set"
  fi

  local epics_file=""
  if [ -z "$reason" ] && ! epics_file="$(epic_fetch)"; then
    reason="could not read dev/EPICS.md from $ROADMAP_TARGET_REPO"
  fi

  if [ -n "$reason" ]; then
    [ "$mode" = "text" ] && printf 'Epics unavailable — %s.\n' "$reason"
    return 0
  fi

  local parsed
  parsed="$(epic_parse_file "$epics_file")" || true
  rm -f "$epics_file"

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
      # (unused here), source (unused here), repo, path (unused here), epoch.
      mapfile -t fields < <(awk -F'\t' '{for (i=1;i<=6;i++) print $i}' <<<"$row")
      status="${fields[0]}"; repo="${fields[3]}"; epoch="${fields[5]}"
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
      printf '%d tasks: %d Done \xc2\xb7 %d Review \xc2\xb7 %d Coding \xc2\xb7 %d Design \xc2\xb7 %d Blocked/Parked \xc2\xb7 %d Open\n' \
        "$n_tasks" "${counts[Done]:-0}" "${counts[Review]:-0}" "${counts[Coding]:-0}" \
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
      # hub-authored $title/$leading_status text (a literal "\c" in an
      # EPICS.md title would make %b silently stop producing output mid-line).
      # Building the markers as real bytes up front and printing with %s
      # means no runtime escape interpretation ever touches interpolated
      # content.
      local em=$'\xe2\x80\x94' dot=$'\xc2\xb7' warn=$'\xe2\x9a\xa0'
      local line
      line="*${eid} ${em} ${title}*: ${counts[Done]:-0}D/${counts[Review]:-0}R/${counts[Coding]:-0}C/${counts[Design]:-0}Dsg/$(( ${counts[Blocked]:-0} + ${counts[Parked]:-0} ))B${dot}P/${counts[Open]:-0}O"
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
