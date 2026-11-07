#!/usr/bin/env bash
# review-threads.sh — /address-pr: list, answer and safely resolve the review
# threads that a `required_review_thread_resolution` ruleset treats as
# merge-blocking (T20260724-373565).
#
#   review-threads.sh list <pr>
#   review-threads.sh reply <pr> <thread-id> (--fixed <sha> | --pushback <file>)
#   review-threads.sh resolve <pr> [--max-pushback N]
#
# list: one TSV row per UNRESOLVED thread (cursor-paginated):
#   <thread-id> <bot|human> <outdated|current> <path:line> <none|fixed|pushback>
#   where the last column is the marker our own latest reply in the thread carries.
# reply: posts the in-thread reply whose first line is `Addressed in <sha>` or
#   `Not changing: <reason>` (the marker `resolve` looks for).
# resolve: closes a thread only when ALL hold:
#   - its first comment is by a Bot (a human-opened thread is never auto-resolved);
#   - viewerCanResolve is true;
#   - our latest comment in it starts with a marker; for `Addressed in <sha>` the
#     sha is an ancestor of the PR head and its diff touches the thread's path;
#   - `Not changing:` resolutions are capped at --max-pushback per run (default 5).
#   `isOutdated` alone never resolves a thread. Then it prints what remains.
#
# Exit: 0 nothing unresolved | 10 bot-opened threads remain (fix or reply, loop)
#   | 11 only human-opened threads remain (escalate to the owner, do not loop)
#   | 3 gh/API/git failure (fail closed) | 2 usage.
#
# Env (tests): GH_SH overrides the gh wrapper (default _gh/gh.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SH="${GH_SH:-$HERE/../../_gh/gh.sh}"

function usage() {
  echo "usage: review-threads.sh list <pr> | reply <pr> <thread-id> (--fixed <sha> | --pushback <file>) | resolve <pr> [--max-pushback N]" >&2
  exit 2
}
function fail() { echo "review-threads.sh: $*" >&2; exit 3; }
function gh_() { bash "$GH_SH" "$@"; }

# fetch_threads <pr> -> JSON array of ALL review threads on stdout
function fetch_threads() {
  local pr="$1" owner name after="" page nodes="[]" more
  owner="$(gh_ repo view --json owner,name --jq .owner.login 2>/dev/null)" || fail "could not read the repo owner"
  name="$(gh_ repo view --json owner,name --jq .name 2>/dev/null)" || fail "could not read the repo name"
  [ -n "$owner" ] && [ -n "$name" ] || fail "could not read the repo owner/name"
  while :; do
    page="$(gh_ api graphql -f owner="$owner" -f name="$name" -F number="$pr" ${after:+-f after="$after"} -f query='
      query($owner: String!, $name: String!, $number: Int!, $after: String) {
        repository(owner: $owner, name: $name) { pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id isResolved isOutdated viewerCanResolve path line
              comments(first: 50) { nodes { body author { login __typename } } } }
          } } } }' 2>/dev/null)" || fail "could not read the review threads of PR #$pr"
    printf '%s' "$page" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1 \
      || fail "unexpected review-thread data for PR #$pr"
    nodes="$(jq -cn --argjson a "$nodes" --argjson p "$page" '$a + $p.data.repository.pullRequest.reviewThreads.nodes')"
    more="$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')"
    [ "$more" = "true" ] || break
    after="$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"
    [ -n "$after" ] && [ "$after" != "null" ] || fail "pagination cursor missing"
  done
  printf '%s' "$nodes"
}

function current_user() {
  local me
  me="$(gh_ api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)" || me=""
  [ -n "$me" ] || fail "could not read the current gh user"
  printf '%s' "$me"
}

# rows <threads-json> <me> -> unresolved threads as TSV-ish JSON lines
# {id,kind,outdated,loc,path,marker,sha,canResolve}
function unresolved_rows() {
  printf '%s' "$1" | jq -c --arg me "$2" '
    .[] | select(.isResolved == false)
    | (.comments.nodes) as $c
    | ([$c[] | select(.author.login == $me)] | last // null) as $mine
    | {id, canResolve: (.viewerCanResolve // false),
       kind: (if ($c[0].author.__typename // "") == "Bot" then "bot" else "human" end),
       outdated: (if .isOutdated then "outdated" else "current" end),
       path: (.path // ""), loc: ((.path // "?") + ":" + ((.line // 0) | tostring)),
       marker: (if $mine == null then "none"
                elif ($mine.body | test("^Addressed in [0-9a-f]{7,40}")) then "fixed"
                elif ($mine.body | test("^Not changing:")) then "pushback" else "none" end),
       sha: (if $mine == null then "" else ($mine.body | capture("^Addressed in (?<s>[0-9a-f]{7,40})").s? // "") end)}'
}

function print_rows() {
  jq -r '[.id, .kind, .outdated, .loc, .marker] | @tsv'
}

function exit_for() { # <rows-json-lines>
  local rows="$1"
  [ -n "$rows" ] || exit 0
  if printf '%s\n' "$rows" | jq -e 'select(.kind == "bot")' >/dev/null 2>&1; then exit 10; fi
  exit 11
}

function cmd_list() {
  local pr="$1" threads me rows
  threads="$(fetch_threads "$pr")" || exit $?
  me="$(current_user)" || exit $?
  rows="$(unresolved_rows "$threads" "$me")" || fail "could not classify the threads"
  [ -z "$rows" ] || printf '%s\n' "$rows" | print_rows
  exit_for "$rows"
}

function cmd_reply() {
  local pr="$1" tid="$2" mode="$3" arg="$4" body
  case "$mode" in
    --fixed)
      [[ "$arg" =~ ^[0-9a-f]{7,40}$ ]] || usage
      git rev-parse --verify --quiet "${arg}^{commit}" >/dev/null || fail "unknown commit $arg"
      body="Addressed in $arg" ;;
    --pushback)
      [ -s "$arg" ] || usage
      body="Not changing: $(cat "$arg")" ;;
    *) usage ;;
  esac
  gh_ api graphql -f tid="$tid" -f body="$body" -f query='
    mutation($tid: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $tid, body: $body}) { comment { id } }
    }' >/dev/null 2>&1 || fail "could not reply to thread $tid (PR #$pr)"
  echo "replied $tid"
}

function sha_ok() { # <sha> <path> <head>
  git merge-base --is-ancestor "$1" "$3" >/dev/null 2>&1 || return 1
  git diff-tree --root --no-commit-id --name-only -r -m "$1" 2>/dev/null | grep -Fxq -- "$2"
}

function cmd_resolve() {
  local pr="$1" cap="$2" threads me head rows row id kind canres marker sha path pushed=0 ok
  threads="$(fetch_threads "$pr")" || exit $?
  me="$(current_user)" || exit $?
  head="$(gh_ pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)" || head=""
  [[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || fail "could not read the head commit of PR #$pr"
  rows="$(unresolved_rows "$threads" "$me")" || fail "could not classify the threads"
  local resolved_ids=" "
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(jq -r .id <<<"$row")"; kind="$(jq -r .kind <<<"$row")"; canres="$(jq -r .canResolve <<<"$row")"
    marker="$(jq -r .marker <<<"$row")"; sha="$(jq -r .sha <<<"$row")"; path="$(jq -r .path <<<"$row")"
    [ "$kind" = bot ] && [ "$canres" = true ] || continue
    ok=0
    case "$marker" in
      fixed) sha_ok "$sha" "$path" "$head" && ok=1 ;;
      pushback) if [ "$pushed" -lt "$cap" ]; then ok=1; pushed=$((pushed + 1)); fi ;;
    esac
    [ "$ok" = 1 ] || continue
    gh_ api graphql -f tid="$id" -f query='
      mutation($tid: ID!) { resolveReviewThread(input: {threadId: $tid}) { thread { id isResolved } } }' >/dev/null 2>&1 \
      || fail "could not resolve thread $id"
    echo "resolved $id ($marker)"
    resolved_ids="$resolved_ids$id "
  done <<<"$rows"
  local remaining=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(jq -r .id <<<"$row")"
    case "$resolved_ids" in *" $id "*) continue ;; esac
    remaining="$remaining$row"$'\n'
  done <<<"$rows"
  remaining="${remaining%$'\n'}"
  [ -z "$remaining" ] || printf '%s\n' "$remaining" | print_rows
  exit_for "$remaining"
}

function main() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ "$#" -ge 2 ] || usage
  local sub="$1" pr="$2"
  [[ "$pr" =~ ^[0-9]+$ ]] || usage
  case "$sub" in
    list) [ "$#" -eq 2 ] || usage; cmd_list "$pr" ;;
    reply) [ "$#" -eq 5 ] || usage; cmd_reply "$pr" "$3" "$4" "$5" ;;
    resolve)
      local cap=5
      if [ "$#" -eq 4 ] && [ "$3" = "--max-pushback" ] && [[ "$4" =~ ^[0-9]+$ ]]; then cap="$4"
      elif [ "$#" -ne 2 ]; then usage; fi
      cmd_resolve "$pr" "$cap" ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
