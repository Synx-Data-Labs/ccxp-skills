#!/usr/bin/env bash
# parse-issue-url.sh — parse a GitHub-style issue reference (T20261012-109735).
#
# Usage: parse-issue-url.sh [--canonical] <issue-url | owner/repo#N>
#   default      prints "owner repo number"
#   --canonical  prints https://<host>/owner/repo/issues/N (host from the URL,
#                or $GH_HOST for the shorthand, default github.com)
# Exit: 0 ok, 1 unparseable, 2 a pull-request URL (not an issue).
# No org/repo literals: any host (GHES included) and any owner/repo is accepted.

set -euo pipefail

function support-parse-issue-url() {
  local canonical=0
  if [[ "${1:-}" == "--canonical" ]]; then canonical=1; shift; fi
  local ref="${1:-}" host owner repo num
  if [[ -z "$ref" ]]; then
    echo "usage: parse-issue-url.sh [--canonical] <issue-url | owner/repo#N>" >&2
    return 1
  fi
  if [[ "$ref" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/[0-9]+ ]]; then
    echo "error: that is a pull request URL, not an issue: $ref" >&2
    return 2
  fi
  if [[ "$ref" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/issues/([0-9]+)(/|\?|#|$) ]]; then
    host="${BASH_REMATCH[1]}"; owner="${BASH_REMATCH[2]}"
    repo="${BASH_REMATCH[3]}"; num="${BASH_REMATCH[4]}"
  elif [[ "$ref" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    host="${GH_HOST:-github.com}"; owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
  else
    echo "error: not an issue URL or owner/repo#N: $ref" >&2
    return 1
  fi
  if [[ "$canonical" -eq 1 ]]; then
    printf 'https://%s/%s/%s/issues/%s\n' "$host" "$owner" "$repo" "$num"
  else
    printf '%s %s %s\n' "$owner" "$repo" "$num"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  support-parse-issue-url "$@"
fi
