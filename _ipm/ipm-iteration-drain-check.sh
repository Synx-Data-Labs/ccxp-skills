#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

# IPM hard gate: drain all non-Done tasks off the *previous* iteration (T20260622-147834).
#
# At the end of every Monday IPM, every GH Project item still assigned to the
# previous iteration that is NOT `Done` must be migrated out (its task-file
# `scheduled:` advanced to the current or a future Monday). The carry logic
# covers in-flight (`Coding`/`Review`) and `claimed_by` tasks, but `Open`/`Design`
# tasks with an empty claim are caught by neither path and silently strand on the
# closed iteration. This gate fails the IPM until they are drained.
#
# "Previous iteration" is resolved by the board's iteration START DATES (a date
# window), never a client-side counter — a counter desyncs the moment a Monday
# IPM is skipped or backfilled. The current iteration is the one whose startDate
# is the latest <= today; the previous is the next-earlier distinct startDate.
#
# Source of truth is the task files' `scheduled:`; the board (synced by
# your-org/ccxp-skills/actions/sync-tasks@v5) is the queryable cross-check.
#
# Deps: gh (with `project` scope) + jq. For tests, inject the board JSON via
# IPM_DRAIN_BOARD_JSON to avoid any network/gh dependency.
#
# A `Parked` task is deliberately set aside (moved to dev/PARKING/), not stranded
# work, so the default terminal set is "Done|Parked" — only genuinely-active
# statuses (Open/Design/Coding/Review/Blocked) count as offenders. (On today's
# board, Parked items also carry a null iteration, so this is belt-and-braces.)
#
# Scope (T20260628-592642): the GH Project can span MULTIPLE repos (e.g.
# build-pipeline-repo and hub-repo), but the IPM clone running this gate
# can only drain its OWN repo's task files (advancing scheduled: is a local
# edit). So offenders are partitioned by --home-repo: SAME-repo offenders are
# BLOCKING (the IPM can act on them); CROSS-repo offenders are a non-blocking
# WARNING (blocking on them would deadlock the unattended IPM commit, since no
# cron in the other repo drains them). This is the "Option C" interim —
# forward-compatible with repo-scoping the gate (A) or adding a cross-repo
# ephemeral-clone drain to ccxp (B).
#
# Lint-freeze (T20260628-951477): a SAME-repo offender whose task file fails the
# changed-mode frontmatter lint (pre-existing non-allowlisted fields — the
# T20260626-353630 schema-fork class) cannot have its scheduled: advanced without
# tripping an unrelated 'Lint task frontmatter' red. Blocking on such a file would
# re-introduce the deadlock Option C avoids for cross-repo items, so each same-repo
# offender is probed (_ipm_drain_is_lint_frozen): FROZEN ones are downgraded to a
# non-blocking WARNING (with the reason printed); CLEAN ones stay BLOCKING. Probe
# fail-safe is BLOCKING (no silent exemption). The real fix is resolving
# T20260626-353630; this is the build-pipeline-side safety valve while it pends.
#
# Moved here from build-pipeline-repo's scripts/audit/ (T20260719-111051): the
# script previously hardcoded --home-repo/--owner defaults to
# your-org/build-pipeline-repo, making it a de-facto hard dependency of
# any repo's ccxp run on that one repo's identity. Now home_repo/owner default
# to the repo_path's git remote `origin` (same repo-agnostic idiom as
# _taskid/url.sh's taskid-repo-slug) — any repo running ccxp gets a correct
# default with zero configuration, and --home-repo/--owner remain explicit
# overrides for the rare cross-clone case.
#
# Exit: 0 if the previous iteration has no CLEAN (drainable) SAME-repo offenders
#         (cross-repo + lint-frozen offenders, if any, are listed as warnings but
#          don't fail);
#       1 if it carries CLEAN SAME-repo offenders (which are listed);
#       2 on a usage error (including: no --home-repo given and none could be
#         auto-detected from --repo-path's git remote).

_ipm_drain_usage() {
  cat <<'EOF'
Usage: ipm-iteration-drain-check [options]

  --prev-start YYYY-MM-DD   Force the previous iteration's start date (skip
                            date-window resolution). Useful for tests / explicit
                            IPM input.
  --today YYYY-MM-DD        Override "today" for date-window resolution
                            (default: the current date).
  --terminal "A|B"          Statuses that count as drained/terminal (regex
                            alternation; default "Done|Parked"). Parked tasks
                            are deliberately set aside (dev/PARKING/), so they
                            are NOT stranded work to force-migrate.
  --project N               GH Project number (default: 1).
  --owner ORG               GH Project owner (default: auto-detected from
                            --repo-path's git remote `origin` — the "OWNER" in
                            "OWNER/NAME". Override if the Project lives in a
                            different org than the repo).
  --home-repo OWNER/NAME    The repo whose IPM is running this gate (default:
                            auto-detected from --repo-path's git remote
                            `origin`). Offenders in this repo are BLOCKING
                            (exit 1 — the IPM run can drain them by advancing
                            their task-file scheduled:) UNLESS lint-frozen (see
                            below). Offenders in any OTHER repo are a
                            non-blocking WARNING — the IPM clone cannot edit a
                            different repo's task files, so blocking on them
                            would deadlock the unattended commit (T20260628-592642).
  --repo-path DIR           Repo clone to resolve same-repo task files in for the
                            lint-frozen probe, AND the source of the --home-repo /
                            --owner auto-detect (via `git -C DIR remote get-url
                            origin`) (default: . — the IPM's own clone).
  -h, --help                Show this help.

A SAME-repo offender whose task file fails the changed-mode frontmatter lint
(non-allowlisted fields it can't be edited to advance scheduled: past — the
T20260626-353630 class) is LINT-FROZEN and downgraded to a non-blocking WARNING,
the same-repo analogue of the cross-repo valve (T20260628-951477). Probe via
lint_tasks.py (resolved by LINT_TASKS_PY, else the sibling
repo-conventions/scripts/lint_tasks.py next to this script); fail-safe is
BLOCKING.

Reads the board via `gh project item-list`, or from IPM_DRAIN_BOARD_JSON when set.
Set IPM_DRAIN_FROZEN_IDS (whitespace-separated task IDs) to force the frozen set
for tests (short-circuits the real lint).
EOF
}

# Print the previous iteration's start date for a board JSON + today, or empty
# if there is no previous iteration (only one distinct start <= today).
_ipm_drain_prev_start() {
  local board="$1" today="$2"
  jq -r --arg today "$today" \
    '[ .items[].iteration.startDate // empty ]
     | map(select(. <= $today)) | unique | .[-2] // empty' \
    <<<"$board"
}

# Path to the frontmatter linter used for the lint-frozen probe. Resolved via
# LINT_TASKS_PY, else the sibling repo-conventions/ script relative to this
# script's own directory — not a hardcoded ~/.claude/skills/... path, which
# only exists under the retired symlink-install layout (T20260914-871616).
_ipm_drain_lint_tasks_py() {
  printf '%s\n' "${LINT_TASKS_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../repo-conventions/scripts" && pwd)/lint_tasks.py}"
}

# Derive "owner/repo" from the `origin` remote of the given repo path (default
# cwd) — the --home-repo/--owner auto-detect source. Same repo-agnostic idiom
# as _taskid/url.sh's taskid-repo-slug: works against any GitHub remote, no
# hardcoded org/repo anywhere in this script.
_ipm_drain_repo_slug() {
  local path="${1:-.}" url
  url="$(git -C "$path" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"             # strip trailing .git
  url="${url#*github.com[:/]}"  # strip scheme/host/user up through github.com[:/]
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

# Is the offender with board title $1 LINT-FROZEN — i.e. its task file fails the
# changed-mode frontmatter lint, so its `scheduled:` cannot be advanced without
# tripping an unrelated `Lint task frontmatter` red (the T20260626-353630 class)?
#   return 0 = frozen (warn, non-blocking) ; return 1 = clean/unclassifiable (BLOCKING).
# Fail-safe is BLOCKING: anything we cannot positively classify as frozen keeps
# the gate's teeth (no silent exemption).
# Test injection: IPM_DRAIN_FROZEN_IDS (whitespace-separated task IDs) short-
# circuits the real lint so BATS stays hermetic (no task files, no python).
_ipm_drain_is_lint_frozen() {
  local title="$1" repo_path="${2:-.}" tid file lint out base verdict_line
  # Board titles are "T<id> — <H1>"; no id ⇒ cannot probe ⇒ blocking.
  [[ "$title" =~ (T[0-9]{8}-[0-9]{6}) ]] || return 1
  tid="${BASH_REMATCH[1]}"
  # Test injection: explicit frozen set, no lint invocation.
  if [ -n "${IPM_DRAIN_FROZEN_IDS:-}" ]; then
    case " ${IPM_DRAIN_FROZEN_IDS} " in
      *" ${tid} "*) return 0 ;;
      *)            return 1 ;;
    esac
  fi
  # Real probe: locate the task file, run the lint, read its OWN verdict line
  # (isolates the file's schema verdict from the board-wide blocked-by pass,
  # which attributes violations to other files).
  local -a _matches
  _matches=( "${repo_path}"/dev/TODO/"${tid}"-*.md )   # glob (not ls) — SC2012-safe
  file="${_matches[0]}"
  [ -f "$file" ] || return 1                 # no match (glob stays literal) ⇒ blocking
  lint="$(_ipm_drain_lint_tasks_py)"
  [ -f "$lint" ] || return 1                 # no linter ⇒ blocking
  out="$(python3 "$lint" --changed "$file" "$repo_path" 2>/dev/null)" || true
  base="$(basename "$file")"
  verdict_line="$(printf '%s\n' "$out" | grep -F "$base" | head -1)"
  [[ "$verdict_line" == *"❌"* ]]            # ❌ on its own line ⇒ frozen
}

ipm-iteration-drain-check() {
  local project="1" owner="" prev_start="" today="" terminal="Done|Parked"
  local home_repo="" repo_path="."

  while [ $# -gt 0 ]; do
    case "$1" in
      --prev-start) prev_start="${2:-}"; shift 2 ;;
      --today)      today="${2:-}";      shift 2 ;;
      --terminal)   terminal="${2:-}";   shift 2 ;;
      --project)    project="${2:-}";    shift 2 ;;
      --owner)      owner="${2:-}";      shift 2 ;;
      --home-repo)  home_repo="${2:-}";  shift 2 ;;
      --repo-path)  repo_path="${2:-}";  shift 2 ;;
      -h|--help)    _ipm_drain_usage; return 0 ;;
      *) echo "ipm-iteration-drain-check: unknown arg '$1'" >&2
         _ipm_drain_usage >&2; return 2 ;;
    esac
  done
  today="${today:-$(date +%F)}"

  # --home-repo / --owner default to the repo_path clone's own git remote — no
  # hardcoded org/repo (T20260719-111051). An explicit --home-repo/--owner
  # always wins; auto-detect only fills in what wasn't passed.
  if [ -z "$home_repo" ] || [ -z "$owner" ]; then
    local _slug
    _slug="$(_ipm_drain_repo_slug "$repo_path" 2>/dev/null)" || _slug=""
    [ -n "$home_repo" ] || home_repo="$_slug"
    [ -n "$owner" ] || owner="${_slug%%/*}"
  fi
  if [ -z "$home_repo" ]; then
    echo "ipm-iteration-drain-check: --home-repo not given and could not auto-detect it from '${repo_path}' git remote 'origin' — pass --home-repo OWNER/NAME explicitly" >&2
    return 2
  fi
  if [ -z "$owner" ]; then
    echo "ipm-iteration-drain-check: --owner not given and could not auto-detect it from '${repo_path}' git remote 'origin' — pass --owner ORG explicitly" >&2
    return 2
  fi

  local board
  if [ -n "${IPM_DRAIN_BOARD_JSON:-}" ]; then
    board="$IPM_DRAIN_BOARD_JSON"
  else
    board="$(gh project item-list "$project" --owner "$owner" --format json --limit 1000)"
  fi

  if [ -z "$prev_start" ]; then
    prev_start="$(_ipm_drain_prev_start "$board" "$today")"
    if [ -z "$prev_start" ]; then
      echo "ℹ ipm-iteration-drain-check: no previous iteration <= ${today} — nothing to drain."
      return 0
    fi
  fi

  # Non-terminal items still pinned to the previous iteration, partitioned by repo:
  # same-repo (this IPM can edit → candidate to drain) vs cross-repo (cannot → WARNING).
  # A null/absent repository is treated as cross-repo (not drainable here → warn,
  # never deadlock) — bias toward not stalling the unattended commit.
  # shellcheck disable=SC2016  # $ps/$term/$home are jq --arg vars, not shell vars — must NOT expand here
  local _cross_jq='
    .items[]
    | select((.iteration.startDate // "") == $ps)
    | select(((.status // "") | test("^(" + $term + ")$")) | not)
    | select((.content.repository // "") != $home)
    | "  \(.content.repository // "?")#\(.content.number // "?")  [\(.status // "(none)")]  \(.content.title // "(untitled)")"'
  # Same-repo offenders as TSV so each can be probed for lint-freeze.
  # shellcheck disable=SC2016
  local _same_jq='
    .items[]
    | select((.iteration.startDate // "") == $ps)
    | select(((.status // "") | test("^(" + $term + ")$")) | not)
    | select((.content.repository // "") == $home)
    | [ (.content.repository // "?"), (.content.number // "?" | tostring),
        (.status // "(none)"), (.content.title // "(untitled)") ] | @tsv'

  local cross same_tsv
  cross="$(jq -r --arg ps "$prev_start" --arg term "$terminal" --arg home "$home_repo" "$_cross_jq" <<<"$board")"
  same_tsv="$(jq -r --arg ps "$prev_start" --arg term "$terminal" --arg home "$home_repo" "$_same_jq" <<<"$board")"

  # Partition same-repo offenders: lint-frozen (cannot advance scheduled: without
  # an unrelated frontmatter-lint red — the same-repo analogue of the cross-repo
  # valve, T20260628-592642) → non-blocking WARNING; clean → BLOCKING.
  local frozen="" blocking="" repo num status title line
  if [ -n "$same_tsv" ]; then
    while IFS=$'\t' read -r repo num status title; do
      [ -n "${repo}${num}${status}${title}" ] || continue
      line="  ${repo}#${num}  [${status}]  ${title}"
      if _ipm_drain_is_lint_frozen "$title" "$repo_path"; then
        frozen+="${line}"$'\n'
      else
        blocking+="${line}"$'\n'
      fi
    done <<<"$same_tsv"
  fi
  frozen="${frozen%$'\n'}"
  blocking="${blocking%$'\n'}"

  # Cross-repo offenders are always surfaced as a non-blocking warning (the IPM
  # clone cannot edit another repo's task files — see T20260628-592642).
  if [ -n "$cross" ]; then
    echo "⚠ Previous iteration (${prev_start}) has non-Done CROSS-REPO items"
    echo "   (not drainable from the ${home_repo} clone — WARNING, non-blocking):"
    echo "$cross"
  fi

  # Lint-frozen same-repo offenders: non-blocking warning (T20260628-951477). The
  # real fix is resolving the schema fork T20260626-353630; until then the gate
  # must not deadlock on files it cannot edit.
  if [ -n "$frozen" ]; then
    echo "⚠ Previous iteration (${prev_start}) has non-Done ${home_repo} items that are LINT-FROZEN"
    echo "   (cannot advance scheduled: without an unrelated 'Lint task frontmatter' red —"
    echo "    resolve T20260626-353630 for the real fix; WARNING, non-blocking):"
    echo "$frozen"
  fi

  if [ -n "$blocking" ]; then
    echo "❌ Previous iteration (${prev_start}) has non-Done ${home_repo} items that must be drained"
    echo "   (advance each task file's scheduled: to this or a future Monday):"
    echo "$blocking"
    return 1
  fi

  if [ -n "$cross" ] || [ -n "$frozen" ]; then
    echo "✅ Previous iteration (${prev_start}): all ${home_repo} items Done, migrated out, or lint-frozen (warned above, non-blocking)."
  else
    echo "✅ Previous iteration (${prev_start}): all items Done or migrated out."
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ipm-iteration-drain-check "$@"
fi
