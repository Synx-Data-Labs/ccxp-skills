#!/usr/bin/env bash
# task_url.sh — resolve a backing task id to a full, clickable GitHub URL
# for /customer-support's triage tracking comment (T20261021-289402).
# `<repo>#T<id>` is not a GitHub autolink, so the comment must carry a real URL.
#
# Usage (sourced or run):
#   task_url.sh <ref> [<default-owner>]
#     ref = <repo>#T<id> | <owner>/<repo>#T<id>   (owner defaults to <default-owner>)
#   prints one US (0x1f)-separated line:  <kind> <url> <title> <pr-url>
#     kind = main | journal | pr    (pr-url empty unless kind=pr)
#
# The URL is a permalink pinned to a commit SHA (default-branch HEAD at triage
# time; the PR head SHA for a task only on an open PR), so it keeps resolving
# after the task moves dev/TODO -> dev/JOURNAL (a blob/main URL would 404).
# Every lookup goes through `cs-gh api` (CS_GH seam; real gh carries its own
# auth, so private repos behave identically). No token is read or printed.
# Fails loudly (non-zero, message on stderr) instead of ever producing a
# broken link.
set -euo pipefail

# shellcheck source=./labels.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"

# cs-task-url-raw-title <owner/repo> <path> <sha> <id> — H1 title, best effort.
cs-task-url-raw-title() {
  local repo="$1" path="$2" sha="$3" id="$4" raw
  raw=$(cs-gh api -H "Accept: application/vnd.github.raw" "repos/${repo}/contents/${path}?ref=${sha}" 2>/dev/null) || return 0
  printf '%s\n' "$raw" | sed -n "s/^# ${id}: *//p" | head -1 | tr -d '\r'
}

# cs-task-url-find <owner/repo> <sha> <dir> <jq-name-regex> — prints path or nothing.
cs-task-url-find() {
  local repo="$1" sha="$2" dir="$3" re="$4" json
  json=$(cs-gh api "repos/${repo}/contents/${dir}?ref=${sha}" 2>/dev/null) || return 0
  printf '%s' "$json" | jq -r --arg re "$re" '[.[]? | select(.name | test($re)) | .path] | first // empty'
}

cs-task-url() {
  local ref="${1:?task ref required}" default_owner="${2:-}"
  local re='^(([A-Za-z0-9_.-]+)/)?([A-Za-z0-9_.-]+)#(T[0-9]{8}-[0-9]{6})$'
  if ! [[ "$ref" =~ $re ]]; then
    echo "error: task ref '${ref}' must look like <repo>#T<YYYYMMDD-NNNNNN> or <owner>/<repo>#T<id>" >&2
    return 2
  fi
  local owner="${BASH_REMATCH[2]:-$default_owner}" name="${BASH_REMATCH[3]}" id="${BASH_REMATCH[4]}"
  if [[ -z "$owner" ]]; then
    echo "error: task ref '${ref}' has no owner and no default owner was given" >&2
    return 2
  fi
  local repo="${owner}/${name}" meta branch sha path title

  # Probe the repo first: a 404/403 here is "not readable", never "task missing"
  # (a private repo without access looks like a missing one).
  if ! meta=$(cs-gh api "repos/${repo}" 2>/dev/null); then
    echo "error: cannot read ${repo} (not found or no access; check gh auth) — not posting a tracking link for ${id}" >&2
    return 1
  fi
  branch=$(printf '%s' "$meta" | jq -r '.default_branch // empty')
  if [[ -z "$branch" ]] || ! sha=$(cs-gh api "repos/${repo}/commits/${branch}" 2>/dev/null | jq -r '.sha // empty') || [[ -z "$sha" ]]; then
    echo "error: cannot resolve the default-branch commit of ${repo} — not posting a tracking link for ${id}" >&2
    return 1
  fi

  path=$(cs-task-url-find "$repo" "$sha" "dev/TODO" "^${id}-.*\\.md\$")
  if [[ -n "$path" ]]; then
    title=$(cs-task-url-raw-title "$repo" "$path" "$sha" "$id")
    printf 'main\037https://github.com/%s/blob/%s/%s\037%s\037\n' "$repo" "$sha" "$path" "$title"
    return 0
  fi
  path=$(cs-task-url-find "$repo" "$sha" "dev/JOURNAL" "^[0-9]{4}-[0-9]{2}-[0-9]{2}-${id}-.*\\.md\$")
  if [[ -n "$path" ]]; then
    title=$(cs-task-url-raw-title "$repo" "$path" "$sha" "$id")
    printf 'journal\037https://github.com/%s/blob/%s/%s\037%s\037\n' "$repo" "$sha" "$path" "$title"
    return 0
  fi

  # Not on the default branch: look for an open PR that adds it (its filing PR).
  local prs n head_sha head_repo pr_url files fpath
  prs=$(cs-gh api "repos/${repo}/pulls?state=open&per_page=100" 2>/dev/null) || prs="[]"
  while IFS=$'\t' read -r n head_sha head_repo pr_url; do
    [[ -n "$n" ]] || continue
    files=$(cs-gh api "repos/${repo}/pulls/${n}/files?per_page=100" 2>/dev/null) || continue
    fpath=$(printf '%s' "$files" | jq -r --arg re "^dev/TODO/${id}-.*\\.md\$" '[.[]? | select(.filename | test($re)) | .filename] | first // empty')
    if [[ -n "$fpath" ]]; then
      title=$(cs-task-url-raw-title "$head_repo" "$fpath" "$head_sha" "$id")
      printf 'pr\037https://github.com/%s/blob/%s/%s\037%s\037%s\n' "$head_repo" "$head_sha" "$fpath" "$title" "$pr_url"
      return 0
    fi
  done < <(printf '%s' "$prs" | jq -r --arg id "$id" '.[]? | select(.head.repo != null and (((.title // "") + " " + (.body // "") + " " + (.head.ref // "")) | ascii_downcase | contains($id | ascii_downcase))) | [.number, .head.sha, (.head.repo.full_name // ""), .html_url] | @tsv')

  echo "error: task ${id} not found in ${repo} (not in dev/TODO or dev/JOURNAL on ${branch}, and no open PR adds it) — not posting a broken link; file/merge the task first" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-task-url "$@"
fi
