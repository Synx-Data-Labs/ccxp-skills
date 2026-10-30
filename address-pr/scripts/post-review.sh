#!/usr/bin/env bash
# post-review.sh <pr-number> <head-sha> <report-file> [--dry-run] — /address-pr
# §2.d step 3: post the independent reviewer's report as a PR comment, pinned to
# the commit it covered. The comment is
#
#   **Claude Code review:** (sha: <head-sha>)
#
#   <contents of report-file>
#
# and is sent through stdin (`--body-file -`), so `$`, backticks and code
# snippets in the report are never expanded by a shell.
#
# Refuses, posting nothing:
#   - an empty (or whitespace-only) or unreadable report            -> exit 2
#   - a head-sha that is not the PR's CURRENT head (a push landed
#     after the review started: the review is stale, redo it)       -> exit 3
#   - gh cannot read the head or cannot post                        -> exit 4
# --dry-run runs every check, prints the comment that would be posted, writes nothing.
# stdout on success: `posted <head-sha>` (or the dry-run comment). Exit 2 also for usage.
# Judgment stays with the caller: the report's content, and what to do about its findings.
#
# Env (tests): GH_SH overrides the gh wrapper (default _gh/gh.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"

usage() { echo "usage: post-review.sh <pr-number> <head-sha> <report-file> [--dry-run]" >&2; exit 2; }
dry=0 args=()
for a in "$@"; do
  case "$a" in --dry-run) dry=1 ;; -*) usage ;; *) args+=("$a") ;; esac
done
[ "${#args[@]}" -eq 3 ] || usage
pr="${args[0]}" sha="${args[1]}" file="${args[2]}"
[[ "$pr" =~ ^[0-9]+$ ]] || usage
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "post-review.sh: head-sha must be a full 40-hex commit id: $sha" >&2; exit 2; }

[ -f "$file" ] && [ -r "$file" ] || { echo "post-review.sh: cannot read report file: $file" >&2; exit 2; }
grep -q '[^[:space:]]' "$file" || { echo "post-review.sh: report file is empty; nothing posted" >&2; exit 2; }

head="$(bash "$GH_SH" pr view "$pr" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null)" || head=""
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "post-review.sh: could not read the head commit of PR #$pr; nothing posted" >&2; exit 4; }
if [ "$head" != "$sha" ]; then
  echo "post-review.sh: stale review: PR #$pr head is now ${head:0:12}, the review covered ${sha:0:12}; nothing posted (re-run the review)" >&2
  exit 3
fi

body() { printf '**Claude Code review:** (sha: %s)\n\n' "$sha"; cat "$file"; }

if [ "$dry" = 1 ]; then body; exit 0; fi
body | bash "$GH_SH" pr comment "$pr" --body-file - >/dev/null 2>&1 \
  || { echo "post-review.sh: gh pr comment failed for PR #$pr" >&2; exit 4; }
echo "posted $sha"
