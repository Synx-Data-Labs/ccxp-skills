#!/usr/bin/env bash
# Resolve a task that lives in ANOTHER repo (epic members) — read-only, via gh.
#
# The local resolver (url.sh `taskid-path`) globs this clone's dev/ dirs, so an
# epic member whose task file lives elsewhere looked "unresolved". This finds it
# by listing dev/{TODO,PARKING,JOURNAL} of each candidate repo through the GitHub
# contents API (the repo's source of truth), then reads the frontmatter status.
#
# Candidate repos, in order: $TASKID_REMOTE_REPOS (space-separated owner/repo),
# every owner/repo named by a github.com/<o>/<r>/blob/... link in the epic files
# (EPIC_LINKS_DIR or dev/EPICS), and this clone's own origin.
#
#   taskid-remote-find   <id> [owner/repo]  -> "slug<TAB>dev/<dir>/<file>"; 1 if nowhere
#   taskid-remote-status <slug> <path>      -> status ("Done" for any JOURNAL file)
#   taskid-remote-url-parse <url>           -> "slug<TAB>path"; 1 if not a GitHub blob URL
#
# Sourceable. Needs `taskid-gh` (url.sh); tests stub it via TASKID_GH. Every
# lookup is fail-quiet: gh failure/no network == "not found", never an abort.
# Listings are cached per process in a temp dir (taskid-remote-cache-clear drops it).
_TASKID_REMOTE_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_TASKID_REMOTE_SELF/url.sh"

# $$ stays the top shell's pid inside $(...) subshells, so one dir is shared per process.
function _taskid-remote-cache() {
  local d="${TMPDIR:-/tmp}/taskid-remote.$$"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

function taskid-remote-cache-clear() {
  rm -rf "${TMPDIR:-/tmp}/taskid-remote.$$"
  return 0
}

function taskid-remote-url-parse() {
  local re='^https://github\.com/([^/]+/[^/]+)/blob/[^/]+/(.+)$'
  if [[ "${1:-}" =~ $re ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    return 1
  fi
}

# taskid-remote-repos -> candidate owner/repo slugs, one per line, de-duplicated
function taskid-remote-repos() {
  local d="${EPIC_LINKS_DIR:-${EPIC_DIR:-dev/EPICS}}" s
  {
    for s in ${TASKID_REMOTE_REPOS:-}; do printf '%s\n' "$s"; done
    grep -hoE 'https://github\.com/[^/ )]+/[^/ )]+/blob/' "$d"/E*.md 2>/dev/null \
      | sed -E 's|https://github\.com/([^/]+/[^/]+)/blob/|\1|' || true
    taskid-repo-slug 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

# _taskid-remote-list <slug> <dir> -> file names in dev/<dir> of <slug> (cached; empty on failure)
function _taskid-remote-list() {
  local slug="$1" dir="$2" cache key
  cache="$(_taskid-remote-cache)"; key="$cache/${slug//\//_}.$dir"
  if [ ! -f "$key" ]; then
    taskid-gh api "repos/$slug/contents/dev/$dir" --jq '.[].name' > "$key" 2>/dev/null || : > "$key"
  fi
  cat "$key"
}

function taskid-remote-find() {
  local id="${1:-}" hint="${2:-}" slug dir hit
  [ -n "$id" ] || return 1
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    for dir in TODO PARKING JOURNAL; do
      hit="$(_taskid-remote-list "$slug" "$dir" | grep -F -- "$id" | grep -E '\.md$' | sort | head -n1 || true)"
      if [ -n "$hit" ]; then printf '%s\tdev/%s/%s\n' "$slug" "$dir" "$hit"; return 0; fi
    done
  done < <({ if [ -n "$hint" ]; then printf '%s\n' "$hint"; fi; taskid-remote-repos; } | awk 'NF && !seen[$0]++')
  return 1
}

function taskid-remote-status() {
  local slug="${1:-}" path="${2:-}" body
  case "$path" in dev/JOURNAL/*) printf 'Done\n'; return 0 ;; esac
  body="$(taskid-gh api "repos/$slug/contents/$path" -H 'Accept: application/vnd.github.raw' 2>/dev/null)" || return 1
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm && index($0, "status:") == 1 { v=substr($0, 8); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); print v; exit }
  ' <<<"$body"
}
