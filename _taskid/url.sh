#!/usr/bin/env bash
# Resolve a task ID to a clickable GitHub URL — map-free (T20260610-023106).
#
# The blob link is resolved by globbing dev/{TODO,PARKING,JOURNAL}/ in the cwd
# repo: a task file moves TODO -> JOURNAL on close (and TODO <-> PARKING), so a
# link built from a fixed path rots, but the glob finds the file's *current*
# location every time, with zero network. The issue number is resolved via
# `gh issue list --search` — the sync-tasks bot's issue body carries the
# task-file permalink, so the search matches even issues whose titles lack the
# ID. The `--issue` link is permanently stable and is the rot-proof choice when
# a link must never 404. (Both lookups previously read the committed
# .github/task-issue-map.json sidecar, retired in T20260610-023106.)
#
# Runs in the cwd of the repo that owns the task files (e.g. the
# build-pipeline-repo clone). Repo slug is derived from `origin`, so the
# helper is repo-agnostic.
#
# Usage (CLI):
#   bash url.sh T20260427-298901            # blob URL to current file
#   bash url.sh T20260427-298901 --issue    # stable issue URL
#   bash url.sh --slack T20260427-298901    # Slack mrkdwn <url|TID>
#   bash url.sh --mdlink T20260427-298901   # markdown [TID](issue-url)
#
# Sourceable form:
#   source url.sh
#   url=$(taskid-url T20260427-298901)
#   link=$(taskid-slacklink T20260427-298901)          # for slack_send_message (mrkdwn)
#   link=$(taskid-mdlink T20260427-298901)             # for digest docs (ipm-weekly.md, etc.)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
fi

# Default branch for blob links. All repos here use main.
TASKID_URL_BRANCH="${TASKID_URL_BRANCH:-main}"

# gh command override — tests inject a stub here; defaults to the account-aware
# _gh wrapper when installed (handles multi-account auth), else raw gh.
TASKID_GH="${TASKID_GH:-}"

function taskid-gh() {
  if [ -n "$TASKID_GH" ]; then
    "$TASKID_GH" "$@"
  elif [ -x "$HOME/.claude/skills/_gh/gh.sh" ]; then
    bash "$HOME/.claude/skills/_gh/gh.sh" "$@"
  else
    gh "$@"
  fi
}

# Derive "owner/repo" from the origin remote of the cwd repo.
function taskid-repo-slug() {
  local url
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"          # strip trailing .git
  url="${url#*github.com[:/]}"  # strip scheme/host/user up through github.com[:/]
  [ -n "$url" ] || return 1
  printf '%s\n' "$url"
}

# taskid-path <TASKID> — the task's current file path under dev/, by glob.
# Precedence TODO > PARKING > JOURNAL (mirrors find_task_file in the
# sync-tasks script) for the abnormal case of a file present in more than one.
function taskid-path() {
  local id="${1:-}" d hit
  [ -n "$id" ] || return 1
  # find, not a shell glob: portable across bash and zsh callers (no compgen,
  # no nullglob mutation, no zsh no-matches-found abort).
  for d in dev/TODO dev/PARKING dev/JOURNAL; do
    hit="$(find "$d" -maxdepth 1 -name "*${id}*.md" 2>/dev/null | sort | head -n1)"
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
      return 0
    fi
  done
  return 1
}

# taskid-issue-number <TASKID> <SLUG> — issue number via gh search (title+body;
# the bot issue's body permalink carries the ID even when the title doesn't).
# Fails (non-zero) when gh is unavailable or finds nothing.
function taskid-issue-number() {
  local id="${1:-}" slug="${2:-}" num
  [ -n "$id" ] && [ -n "$slug" ] || return 1
  num="$(taskid-gh issue list --repo "$slug" --state all \
          --search "$id in:title,body" \
          --json number --jq '.[0].number // empty' 2>/dev/null)" || return 1
  [[ "$num" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$num"
}

# taskid-url <TASKID> [--issue]
#   default : blob link to the task's CURRENT file path (by glob, no network)
#   --issue : stable GitHub issue URL (never rots on a file move)
# Falls back to a repo code-search link when nothing resolves, so the
# reference is always clickable.
function taskid-url() {
  local id="${1:-}" mode="${2:-blob}"
  [ -n "$id" ] || { echo "taskid-url: missing task ID" >&2; return 2; }

  local slug
  slug="$(taskid-repo-slug)" || { echo "taskid-url: cannot resolve repo slug from origin" >&2; return 1; }

  # NB: not named `path` — in zsh callers that local would clobber the
  # PATH-tied array and every subsequent command lookup in scope.
  local task_file num
  if [ "$mode" = "--issue" ]; then
    if num="$(taskid-issue-number "$id" "$slug")"; then
      printf 'https://github.com/%s/issues/%s\n' "$slug" "$num"
      return 0
    fi
  elif task_file="$(taskid-path "$id")"; then
    printf 'https://github.com/%s/blob/%s/%s\n' "$slug" "$TASKID_URL_BRANCH" "$task_file"
    return 0
  fi

  # Nothing resolved: a code-search link still lands the maintainer on the task.
  printf 'https://github.com/search?q=repo:%s+%s&type=code\n' "$slug" "$id"
}

# taskid-slacklink <TASKID> [--issue] -> Slack mrkdwn link: <url|TASKID>
# Slack renders <url|text>, NOT [text](url) — use this for slack_send_message.
function taskid-slacklink() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "taskid-slacklink: missing task ID" >&2; return 2; }
  printf '<%s|%s>\n' "$(taskid-url "$@")" "$id"
}

# taskid-mdlink <TASKID> [--blob] -> markdown link: [TASKID](url)
#   default : --issue mode (permanently stable — never rots on a task-file move)
#   --blob  : current-path blob link (same tradeoff as taskid-url's default)
# Use for digest docs (ipm-weekly.md, retro-weekly.md) that are written once
# and never regenerated — a blob-mode link baked in at write time can still
# rot if the referenced task moves later, unlike taskid-slacklink's blob
# default, which is fine for a same-day Slack message read before a move is
# likely (T20260608-353422).
function taskid-mdlink() {
  local id="${1:-}" mode="${2:-}"
  [ -n "$id" ] || { echo "taskid-mdlink: missing task ID" >&2; return 2; }
  if [ "$mode" = "--blob" ]; then
    printf '[%s](%s)\n' "$id" "$(taskid-url "$id")"
  else
    printf '[%s](%s)\n' "$id" "$(taskid-url "$id" --issue)"
  fi
}

# CLI dispatch (skipped when sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --slack) shift; taskid-slacklink "$@" ;;
    --mdlink) shift; taskid-mdlink "$@" ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) taskid-url "$@" ;;
  esac
fi
