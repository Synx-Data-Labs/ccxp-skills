#!/usr/bin/env bash
# slack-text.sh <pr-number> <pr-url> [--unverified <N>] — /address-pr §3.1: print the
# "ready to merge" Slack message text, one line, for the caller to hand to `/slack`.
# Sends nothing; it only renders the two fixed templates:
#   PR #<n> is ready to merge — CI green, Claude Code review addressed, test plan verified. <url>
#   PR #<n> is ready to merge — CI green, Claude Code review addressed. N test plan items need manual verification. <url>
# --unverified 0 (or no flag) is the verified template. Whether the PR is actually ready
# is the hard gate's call, not this script's.
# Exit: 0 | 2 usage (non-numeric PR/N, a url that is not a single-token http(s) URL).
#
# Pure: no gh, no network, no env.

set -uo pipefail

usage() { echo "usage: slack-text.sh <pr-number> <pr-url> [--unverified <N>]" >&2; exit 2; }
n=0 args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unverified) [ "$#" -ge 2 ] || usage; n="$2"; shift ;;
    -*) usage ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ "${#args[@]}" -eq 2 ] || usage
pr="${args[0]}" url="${args[1]}"
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$n" =~ ^[0-9]+$ ]] || usage
[[ "$url" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] || usage

if [ "$n" -eq 0 ]; then
  printf 'PR #%s is ready to merge — CI green, Claude Code review addressed, test plan verified. %s\n' "$pr" "$url"
else
  printf 'PR #%s is ready to merge — CI green, Claude Code review addressed. %s test plan items need manual verification. %s\n' "$pr" "$n" "$url"
fi
