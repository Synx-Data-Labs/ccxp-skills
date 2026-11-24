#!/usr/bin/env bash
# _gh/fresh-base.sh — fail loudly when a branch or clone is not based on the
# latest origin/main (decision d129): run it before work, before a push and
# before dispatching any workflow run.
#
# Usage:
#   fresh-base.sh check  [--base main] [--remote origin] [--rebase] [--dir <path>]
#   fresh-base.sh remote [--base main] [--remote origin] [--dir <path>] <branch>
#
#   check   fetches, then compares HEAD with <remote>/<base>. With --rebase, a
#           stale HEAD gets a plain `git rebase` (never a force-push; a conflict
#           aborts the rebase and fails).
#   remote  fetches, then checks the pushed <remote>/<branch> contains
#           <remote>/<base> (run before `gh workflow run --ref <branch>`).
#
# One line on stdout, the exit code is the verdict:
#   0  fresh <sha>                    up to date
#   0  rebased <old> <new>            was behind, rebase succeeded (check --rebase)
#   10 stale behind=<N>               behind (check), or the remote branch lacks the base (remote)
#   11 conflict                       rebase hit a conflict and was aborted
#   12 dirty                          --rebase refused: uncommitted changes
#   13 detached | in-progress         --rebase refused: detached HEAD, or a rebase/merge already under way
#   3  fetch-failed                   fetch failed, including a base or <branch> missing on the remote (never read as fresh);
#                                     no-base is a defensive verdict if a fetched ref still does not resolve
#   2  usage
#
# Env: FRESH_BASE_GIT overrides the git command (default: the sibling git.sh,
# which picks the gh account for HTTPS auth).
# Sourceable; the work is in functions (set -uo pipefail applies only when run directly).
_FB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function fresh-base-git() {
  local g="${FRESH_BASE_GIT:-}"
  if [[ -n "$g" ]]; then "$g" "$@"; else bash "$_FB_DIR/git.sh" "$@"; fi
}

function fresh-base-fetch() {
  # Explicit refspecs: a narrowed remote.<name>.fetch must not leave a stale <remote>/<base> trusted.
  local remote="$1" base="$2" extra="${3:-}"
  local specs=("+refs/heads/$base:refs/remotes/$remote/$base")
  [[ -z "$extra" ]] || specs+=("+refs/heads/$extra:refs/remotes/$remote/$extra")
  fresh-base-git fetch --quiet "$remote" "${specs[@]}" >/dev/null 2>&1 || { echo "fetch-failed"; return 3; }
  git rev-parse --verify --quiet "refs/remotes/$remote/$base^{commit}" >/dev/null || { echo "no-base"; return 3; }
  return 0
}

function fresh-base-check() {
  local base="$1" remote="$2" rebase="$3" head old behind
  local ref="$remote/$base"
  fresh-base-fetch "$remote" "$base" || return 3
  head="$(git rev-parse HEAD)" || { echo "no-base"; return 3; }
  behind="$(git rev-list --count "HEAD..$ref")"
  if [[ "$behind" == 0 ]]; then echo "fresh $head"; return 0; fi
  if [[ "$rebase" != true ]]; then echo "stale behind=$behind"; return 10; fi
  local gd; gd="$(git rev-parse --git-dir)"
  if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]]; then echo "in-progress"; return 13; fi
  git symbolic-ref -q HEAD >/dev/null || { echo "detached"; return 13; }
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then echo "dirty"; return 12; fi
  old="$head"
  if ! git rebase "$ref" >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1 || true
    echo "conflict"; return 11   # also a rebase git refused to start (e.g. an untracked file in the way)
  fi
  echo "rebased $old $(git rev-parse HEAD)"; return 0
}

function fresh-base-remote() {
  local base="$1" remote="$2" branch="$3" behind
  fresh-base-fetch "$remote" "$base" "$branch" || return 3
  git rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}" >/dev/null || { echo "no-base"; return 3; }
  behind="$(git rev-list --count "$remote/$branch..$remote/$base")"
  if [[ "$behind" == 0 ]]; then echo "fresh $(git rev-parse "$remote/$branch")"; return 0; fi
  echo "stale behind=$behind"; return 10
}

function fresh-base-main() {
  local verb="${1:-}" base=main remote=origin rebase=false dir="" branch=""
  [[ "$verb" == check || "$verb" == remote ]] || { echo "usage: fresh-base.sh check|remote [--base B] [--remote R] [--rebase] [--dir D] [<branch>]" >&2; return 2; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) [[ $# -ge 2 ]] || return 2; base="$2"; shift 2 ;;
      --remote) [[ $# -ge 2 ]] || return 2; remote="$2"; shift 2 ;;
      --dir) [[ $# -ge 2 ]] || return 2; dir="$2"; shift 2 ;;
      --rebase) rebase=true; shift ;;
      -*) echo "fresh-base.sh: unknown option $1" >&2; return 2 ;;
      *) [[ -z "$branch" ]] || return 2; branch="$1"; shift ;;
    esac
  done
  if [[ "$verb" == check ]]; then
    [[ -z "$branch" ]] || { echo "usage: fresh-base.sh check takes no branch argument" >&2; return 2; }
  else
    [[ -n "$branch" && "$rebase" == false ]] || { echo "usage: fresh-base.sh remote <branch> (no --rebase)" >&2; return 2; }
  fi
  # A subshell keeps --dir from changing the caller's cwd when sourced.
  (
    if [[ -n "$dir" ]]; then cd "$dir" 2>/dev/null || { echo "fresh-base.sh: no such dir $dir" >&2; exit 2; }; fi
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "fresh-base.sh: not a git repo" >&2; exit 2; }
    if [[ "$verb" == check ]]; then fresh-base-check "$base" "$remote" "$rebase"; else fresh-base-remote "$base" "$remote" "$branch"; fi
  )
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  fresh-base-main "$@"
fi
