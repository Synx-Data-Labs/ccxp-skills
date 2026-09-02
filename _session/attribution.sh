#!/usr/bin/env bash
# _session/attribution.sh — per-location (host:clone-path) task-attribution.
#
# The daily standup (ccxp Phase 1.3) renders a "## Task attribution by location"
# section from this helper, splitting task throughput by the
# `claimed_by: <host>:<clone-path>` identity (defined in T20260615-169917,
# written by `_session/task_claim.sh`) so AUTONOMOUS ccxp vs INTERACTIVE-session
# work is measurable.
#
# KEY FINDING — `claimed_by` is CLEARED at close. `task_claim.sh` `_tc_release`
# (task_claim.sh:345) sets `claimed_by ""` when a task closes (/drive Phase 7
# `release`; the reclaim sweep too). So a COMPLETED task's JOURNAL stub carries an
# EMPTY `claimed_by`. Completed-task attribution therefore recovers the last
# non-empty `claimed_by` from the file's git history (the value just before the
# release commit cleared it); IN-FLIGHT (TODO) tasks read the current frontmatter,
# which is the live claim.
#
# CLASSIFICATION — a location is labelled ccxp / interactive / unattributed:
#   - empty location                                   -> unattributed
#   - the location's clone-PATH ∈ ATTRIBUTION_CCXP_PATHS-> ccxp
#   - any other non-empty location                     -> interactive
# ATTRIBUTION_CCXP_PATHS is a COLON-separated list of clone PATHS (clone paths
# have no ':' on Linux, so a colon list is unambiguous even though each
# `claimed_by` value is itself `<host>:<path>` — we split that on the FIRST ':').
# It defaults to the well-known cron clone path that `dev/daily-ccxp.sh` runs
# from; override/extend it (e.g. another autonomous box's clone) via the env var.
#
# Sourceable (defines functions only; the CLI runs solely under the
# direct-execution guard at the bottom). Best-effort + idempotent + read-only
# over the repo: it must NEVER abort the standup, so it uses `set -uo pipefail`
# (no `-e`) like the other `_session/` helpers (_lib.sh, status.sh).
#
# CLI:
#   attribution.sh table [<dev-dir>] [<since>] [<until>]
#       Markdown attribution table for the window [since, until) — default
#       yesterday. Prints NOTHING when there are no rows (standup "no empty
#       sections" rule).
#   attribution.sh classify <location>          -> ccxp|interactive|unattributed
#   attribution.sh collect  [<dev-dir>] [<since>] [<until>]   (raw location\tbucket rows)
#   attribution.sh last-claimed-by <task-file>  (the git-history recovery)

set -uo pipefail

# Known-autonomous clone path(s) — REQUIRED config, no adopting-team default
# baked in (each team sets its own cron clone path via ~/.claude/.env, see
# README Prerequisites). Colon-list; unset means every location classifies as
# "interactive" (a cosmetic degrade for the standup attribution table, never
# a functional failure — see attribution_classify below).
: "${ATTRIBUTION_CCXP_PATHS:=}"

# Load ATTRIBUTION_CCXP_PATHS from ~/.claude/.env (machine-global) when not
# already exported — same resolution order and ENV_FILE test seam as
# slack/scripts/slack-send.sh, vpn/scripts/vpn.sh, and _session/_lib.sh.
# Skipped in BATS (unless ENV_FILE points at a fixture) to keep tests hermetic.
_attribution_load_env() {
  [ -n "$ATTRIBUTION_CCXP_PATHS" ] && return 0
  if [ -n "${ENV_FILE:-}" ]; then
    [ -f "$ENV_FILE" ] && { # shellcheck disable=SC1090
      source "$ENV_FILE"; }
    return 0
  fi
  [ -n "${BATS_TEST_TMPDIR:-}" ] && return 0
  [ -f "$HOME/.claude/.env" ] && { # shellcheck disable=SC1090
    source "$HOME/.claude/.env"; }
}
_attribution_load_env
: "${ATTRIBUTION_CCXP_PATHS:=}"

# --- frontmatter read (mirrors task_claim.sh:_tc_fm_get; that one is _-private) -

attribution_fm_get() {
  # $1 file  $2 field → echo the field's trimmed value (first fence only), or empty.
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

# --- location normalization -------------------------------------------------

_attribution_norm_loc() {
  # Trim whitespace and strip matched surrounding quotes; a quote-only or
  # whitespace-only value (e.g. a historical `claimed_by: ""`) normalizes to
  # empty so it buckets as unattributed rather than a bogus `""` location.
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    '"'*'"') v="${v#\"}"; v="${v%\"}" ;;
    "'"*"'") v="${v#\'}"; v="${v%\'}" ;;
  esac
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# --- classification (pure — no I/O) -----------------------------------------

attribution_classify() {
  # $1 location (a `<host>:<clone-path>` value, possibly empty)
  #   -> "ccxp" | "interactive" | "unattributed"
  local loc="${1:-}" path p
  [ -z "$loc" ] && { printf 'unattributed'; return 0; }
  # The clone path is everything after the FIRST ':'; a value with no ':' is
  # treated whole (defensive — every real claim has one).
  case "$loc" in
    *:*) path="${loc#*:}" ;;
    *)   path="$loc" ;;
  esac
  local IFS=':'
  for p in $ATTRIBUTION_CCXP_PATHS; do
    [ -n "$p" ] || continue
    if [ "$path" = "$p" ]; then printf 'ccxp'; return 0; fi
  done
  printf 'interactive'
}

# --- completed-task attribution recovery (git history) ----------------------

attribution_last_claimed_by() {
  # $1 task file → the live claim if the current frontmatter `claimed_by` is
  # non-empty; otherwise (the close-time wipe) the most-recent non-empty
  # `claimed_by` from git history; else empty.
  #
  # Recovery walks every commit that touched the file's id+SLUG stem path
  # (`*<T-id>-<slug>*` pathspec) — NOT `--follow`, which silently stops when the
  # close commit both renames TODO→JOURNAL and heavily edits the file (rename
  # detection fails → pre-rename history with the live claim is missed). The
  # glob spans this file's TODO and JOURNAL paths regardless of rename detection
  # while NOT matching a DIFFERENT same-id file (a task may split into
  # design/impl docs — same id, different slug — and a bare-id pathspec would
  # return the wrong file's claim, newest-first).
  local file="$1" cur repo taskid stem pathspec sha path val
  cur="$(_attribution_norm_loc "$(attribution_fm_get "$file" claimed_by 2>/dev/null)")"
  if [ -n "$cur" ]; then printf '%s' "$cur"; return 0; fi
  repo="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" || { printf ''; return 0; }
  taskid="$(basename "$file" | grep -oE 'T[0-9]{8}-[0-9]{6}' | head -1)"
  if [ -n "$taskid" ]; then
    # id+slug stem = basename minus a leading YYYY-MM-DD- (JOURNAL) and .md.
    stem="$(basename "$file")"; stem="${stem%.md}"
    stem="${stem#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
    pathspec="*${stem}*"
  else
    pathspec="$(git -C "$repo" ls-files --full-name -- "$file" 2>/dev/null | head -1)"
    [ -z "$pathspec" ] && pathspec="$(realpath --relative-to="$repo" "$file" 2>/dev/null)"
  fi
  [ -z "$pathspec" ] && { printf ''; return 0; }
  # `--name-only` prints, newest-first, each commit's %H (always 40 hex) then the
  # matching path(s) at that commit; a single commit may list both old+new paths
  # (a rename), so we do NOT reset $sha until the next %H line — try every path.
  sha=""
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    if printf '%s' "$ln" | grep -qE '^[0-9a-f]{40}$'; then sha="$ln"; continue; fi
    [ -n "$sha" ] || continue
    path="$ln"
    val="$(git -C "$repo" show "$sha:$path" 2>/dev/null | awk '
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---"  { exit }
      infm && index($0,"claimed_by:")==1 {
        v=substr($0,12); sub(/^[ \t]+/,"",v); sub(/[ \t]+$/,"",v)
        if (v!="") { print v; exit }
      }')"
    val="$(_attribution_norm_loc "$val")"
    if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
  done < <(git -C "$repo" log --format='%H' --name-only -- "$pathspec" 2>/dev/null)
  printf ''
}

# --- window helpers ---------------------------------------------------------

_attribution_default_window() {
  # echo "<since> <until>" = yesterday today (UTC, YYYY-MM-DD).
  local until since
  until="$(date -u +%F)"
  since="$(date -u -d 'yesterday' +%F 2>/dev/null || date -u -v-1d +%F)"
  printf '%s %s' "$since" "$until"
}

# --- collection -------------------------------------------------------------

attribution_collect() {
  # $1 dev-dir  $2 since  $3 until → raw "<location>\t<bucket>" rows, where bucket
  # is "shipped" (JOURNAL task journal dated in [since,until)) or "in-flight"
  # (TODO task currently claimed or status Coding/Review). Location may be empty
  # (→ unattributed downstream).
  local dev_dir="${1:-dev}" since="${2:-}" until="${3:-}"
  local f base status claimed date_prefix loc

  if [ -d "$dev_dir/TODO" ]; then
    for f in "$dev_dir"/TODO/*.md; do
      [ -e "$f" ] || continue
      status="$(attribution_fm_get "$f" status 2>/dev/null)"
      claimed="$(attribution_fm_get "$f" claimed_by 2>/dev/null)"
      case "$status" in
        Coding*|Review*) : ;;                       # in-flight by status
        *) [ -n "$claimed" ] || continue ;;         # else only if actively claimed
      esac
      printf '%s\tin-flight\n' "$(_attribution_norm_loc "$claimed")"
    done
  fi

  if [ -d "$dev_dir/JOURNAL" ]; then
    for f in "$dev_dir"/JOURNAL/*.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      # task journals only: YYYY-MM-DD-T<id>-… (skip daily-summary/ipm/retro docs)
      case "$base" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-T[0-9]*) : ;;
        *) continue ;;
      esac
      date_prefix="${base:0:10}"
      [ -n "$since" ] && [ "$date_prefix" \< "$since" ] && continue
      if [ -n "$until" ]; then
        { [ "$date_prefix" \> "$until" ] || [ "$date_prefix" = "$until" ]; } && continue
      fi
      loc="$(attribution_last_claimed_by "$f")"
      printf '%s\tshipped\n' "$loc"
    done
  fi
}

# --- table render -----------------------------------------------------------

attribution_table() {
  # $1 dev-dir  $2 since  $3 until → a markdown attribution table, or NOTHING
  # when there are no rows. Default window = yesterday.
  local dev_dir="${1:-dev}" since="${2:-}" until="${3:-}" rows agg w
  if [ -z "$since" ] || [ -z "$until" ]; then
    w="$(_attribution_default_window)"; since="${w% *}"; until="${w#* }"
  fi
  rows="$(attribution_collect "$dev_dir" "$since" "$until")"
  [ -z "$rows" ] && return 0
  # Aggregate per location. Emit "<shipped>\t<inflight>\t<location>" — location
  # LAST so an empty location (genuine unattributed) is a trailing field, not a
  # leading one: `read` strips leading IFS-whitespace (a leading empty tab field
  # would shift the counts into the location). Sort by location (3rd field).
  agg="$(printf '%s\n' "$rows" | awk -F'\t' '
    { loc=$1; b=$2; if (b=="shipped") s[loc]++; else if (b=="in-flight") f[loc]++; seen[loc]=1 }
    END { for (l in seen) printf "%d\t%d\t%s\n", s[l]+0, f[l]+0, l }
  ' | sort -t"$(printf '\t')" -k3)"
  [ -z "$agg" ] && return 0

  printf '| Location | Class | Shipped | In-flight | Total |\n'
  printf '|----------|-------|---------|-----------|-------|\n'
  local loc shipped inflight class total disp
  while IFS=$'\t' read -r shipped inflight loc; do
    [ -n "${shipped}${inflight}" ] || continue
    class="$(attribution_classify "$loc")"
    total=$((shipped + inflight))
    disp="$loc"; [ -z "$disp" ] && disp='(unattributed)'
    printf '| %s | %s | %d | %d | %d |\n' "$disp" "$class" "$shipped" "$inflight" "$total"
  done <<<"$agg"
}

# --- CLI (only when executed directly) --------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-table}"; shift 2>/dev/null || true
  case "$cmd" in
    table)           attribution_table "$@" ;;
    classify)        attribution_classify "$@" ;;
    collect)         attribution_collect "$@" ;;
    last-claimed-by) attribution_last_claimed_by "$@" ;;
    *) printf 'usage: attribution.sh <table|classify|collect|last-claimed-by> [args]\n' >&2; exit 64 ;;
  esac
fi
