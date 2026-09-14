#!/usr/bin/env bash
# task-state.sh <task-id> [--json] — one-shot unified state query (T20260719-204917).
#
# Answers "what's the status of T<id>, is there a branch/PR for it, is it
# still blocked" in ONE call instead of three separate manual lookups (task
# file frontmatter, `git branch -r`, `gh pr list`) — the Factor 5/6 gap
# (humanlayer/12-factor-agents) surfaced repeatedly while driving
# T20260629-281129 and its blocker chain this session.
#
# Resolution reuses the SAME primitives /stage, /top, and /drive already use
# (DRY, not a parallel resolver): `_taskid/url.sh`'s `taskid-path` for the
# TODO > PARKING > JOURNAL glob, and `_taskid/in-this-repo.sh`'s
# `taskid-in-this-repo` for the cross-repo / closed-here diagnostic banner
# when the id isn't in this clone at all.
#
# The frontmatter reader below is a deliberate small COPY of
# `task_claim.sh`'s `_tc_fm_get` awk pattern, not a sourced call to it —
# `_tc_*` is underscore-private to that script (same rationale as
# `attribution.sh`'s own `attribution_fm_get`; see its header comment).
#
# Blocking-chain depth is intentionally ONE LEVEL, not full recursion: each
# id referenced by `status:`/`blocks:`/`blocked-by:`/`related:` gets one line
# of its OWN status, not a walk of ITS blockers too. `/stage`/`/top` already
# reject chasing transitive chains for the same reason (see their "does NOT
# chase indirect/transitive blocking" notes) — an unbounded walk risks a
# cycle and drowns the one-shot query in noise.
#
# Usage:
#   bash task-state.sh T20260629-281129
#   bash task-state.sh T20260629-281129 --json
#
# Must run from the repo root (same assumption as every other _session/
# _taskid script — they resolve dev/TODO etc. relative to cwd).

set -uo pipefail

_TS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TS_DIR/../_taskid/url.sh"          # taskid-path, taskid-gh (DI: TASKID_GH)
# shellcheck source=/dev/null
source "$_TS_DIR/../_taskid/in-this-repo.sh" # taskid-in-this-repo (cross-repo/closed banner)

# --- frontmatter read (pure; own copy, first fence only) ---------------------

ts_fm_get() {
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

# --- related-id extraction (pure) --------------------------------------------

ts_extract_ids() {
  # $1 self-id  $2... field values → distinct T<id>s referenced, one per line,
  # excluding self. `blocks:`/`related:`/`blocked-by:` are free-form prose in
  # this repo (not clean YAML lists — see real dev/TODO examples), and
  # `status:` itself can read `Blocked by T<id>` — so a token scan across all
  # of them is the correct extraction, not a YAML list parse.
  local self="$1"; shift
  printf '%s\n' "$@" | grep -oE 'T[0-9]{8}-[0-9]{6}' | sort -u | grep -v -x "$self" || true
}

# one line of a referenced id's own status — NOT recursive beyond this
ts_one_line_status() {
  local id="$1" file status claimed
  file="$(taskid-path "$id" 2>/dev/null)" || { printf '%s: (not found in this repo)\n' "$id"; return 0; }
  status="$(ts_fm_get "$file" status)"
  claimed="$(ts_fm_get "$file" claimed_by)"
  if [ -n "$claimed" ]; then
    printf '%s: %s (claimed_by %s)\n' "$id" "${status:-?}" "$claimed"
  else
    printf '%s: %s\n' "$id" "${status:-?}"
  fi
}

# --- branch + PR lookups ------------------------------------------------------

ts_branch_lookup() {
  # $1 task-id → newline-separated remote branch names referencing the id
  # (case-insensitive — the t<id>-<slug> branch-naming convention lowercases T).
  local id="$1"
  git branch -r 2>/dev/null | sed 's/^[* ]*//' | grep -i -- "${id#T}" || true
}

ts_pr_lookup_json() {
  # $1 task-id → gh pr list JSON array (open + recently referenced, any
  # state) — the id may appear in the branch name, title, or body.
  local id="$1"
  taskid-gh pr list --search "$id" --state all --limit 20 \
    --json number,state,title,url,updatedAt 2>/dev/null || printf '[]'
}

# --- rendering -----------------------------------------------------------------

ts_render_text() {
  local id="$1" file="$2" status="$3" claimed="$4" branches="$5" prs_json="$6" chain="$7"
  printf '%s\n' "$id"
  if [ -n "$file" ]; then
    printf '  file:       %s\n' "$file"
    printf '  status:     %s\n' "${status:-(none)}"
    printf '  claimed_by: %s\n' "${claimed:-(unclaimed)}"
  else
    printf '  file:       (not found in this repo)\n'
  fi

  if [ -n "$branches" ]; then
    printf '  branches:\n'
    while IFS= read -r b; do [ -n "$b" ] && printf '    - %s\n' "$b"; done <<<"$branches"
  else
    printf '  branches:   (none)\n'
  fi

  local pr_count=0
  pr_count="$(printf '%s' "$prs_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [ "${pr_count:-0}" -gt 0 ] 2>/dev/null; then
    printf '  PRs:\n'
    printf '%s' "$prs_json" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print("    - #{} [{}] {} ({})".format(p["number"], p["state"], p["title"], p["url"]))
' 2>/dev/null
  else
    printf '  PRs:        (none)\n'
  fi

  if [ -n "$chain" ]; then
    printf '  blocking chain (1 level):\n'
    while IFS= read -r ln; do [ -n "$ln" ] && printf '    - %s\n' "$ln"; done <<<"$chain"
  fi
  return 0
}

ts_render_json() {
  local id="$1" file="$2" status="$3" claimed="$4" branches="$5" prs_json="$6" chain="$7"
  python3 -c '
import json, sys
id_, file_, status_, claimed_, branches_, prs_json, chain_ = sys.argv[1:8]
branches = [b for b in branches_.split("\n") if b]
chain = [c for c in chain_.split("\n") if c]
try:
    prs = json.loads(prs_json)
except Exception:
    prs = []
print(json.dumps({
    "id": id_,
    "file": file_ or None,
    "status": status_ or None,
    "claimed_by": claimed_ or None,
    "branches": branches,
    "prs": prs,
    "blocking_chain": chain,
}, indent=2))
' "$id" "$file" "$status" "$claimed" "$branches" "$prs_json" "$chain"
}

# --- main ----------------------------------------------------------------------

ts_main() {
  local id="${1:-}" fmt="text"
  [ -n "$id" ] || { echo "usage: task-state.sh <task-id> [--json]" >&2; return 64; }
  shift || true
  [ "${1:-}" = "--json" ] && fmt="json"

  local file status="" claimed="" chain_ids chain=""
  file="$(taskid-path "$id" 2>/dev/null)" || file=""

  if [ -z "$file" ]; then
    # Not resolvable by direct glob — surface the same diagnostic banner
    # /stage and /drive already show (cross-repo sibling-clone hint, or a
    # distinct "closed here" note). Never fatal: still report branches/PRs.
    taskid-in-this-repo "$id" || true
  else
    status="$(ts_fm_get "$file" status)"
    claimed="$(ts_fm_get "$file" claimed_by)"
    local related blocks blockedby
    related="$(ts_fm_get "$file" related)"
    blocks="$(ts_fm_get "$file" blocks)"
    blockedby="$(ts_fm_get "$file" blocked-by)"
    chain_ids="$(ts_extract_ids "$id" "$status" "$related" "$blocks" "$blockedby")"
    if [ -n "$chain_ids" ]; then
      while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        chain="${chain}$(ts_one_line_status "$cid")"$'\n'
      done <<<"$chain_ids"
    fi
  fi

  local branches prs_json
  branches="$(ts_branch_lookup "$id")"
  prs_json="$(ts_pr_lookup_json "$id")"

  if [ "$fmt" = "json" ]; then
    ts_render_json "$id" "$file" "$status" "$claimed" "$branches" "$prs_json" "$chain"
  else
    ts_render_text "$id" "$file" "$status" "$claimed" "$branches" "$prs_json" "$chain"
  fi
  return 0
}

# Run only when executed directly (not when sourced — tests source this).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ts_main "$@"
fi
