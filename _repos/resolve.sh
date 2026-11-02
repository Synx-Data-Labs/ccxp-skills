#!/usr/bin/env bash
# resolve.sh — shared repo matcher/resolver behind /repo switch (T20261031-139856).
#
#   repo-resolve [--repo <query|path>] [--any]
#
# Order: explicit --repo > $CCXP_REPO > git toplevel of $PWD > error.
# A value starting with `/`, `./`, `../` or `~` is a path; anything else is a
# name matched against the registry (`name`, `owner/name`, `aliases`,
# case-insensitive). The first tier with any hit wins and is never widened:
# exact, prefix, substring, subsequence. Several hits in that tier = ambiguous.
#
# Never mutates, never cd's: callers use `git -C "$root"` and "$root/dev/TODO".
#
# Exit codes: 0 one repo (path on stdout) | 2 usage / no repo at $PWD |
#   3 ambiguous (candidate lines `path<TAB>name<TAB>slug` on stdout, sorted by
#   name then path) | 4 no match | 5 refused (path not registered, or no
#   dev/TODO/, without --any) | 6 malformed registry.
#
# Sourced by repos.sh (which supplies the registry helpers); functions only.

# repo-match-name <query> — candidates of the first tier with a hit, one
# `path<TAB>name<TAB>slug` line each (sorted); rc 4 when nothing matches.
function repo-match-name() {
  local q="$1" reg exist="" p out
  reg="$(repos-registry-read)" || return 6
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && exist="${exist}${p}
"
  done <<<"$(printf '%s' "$reg" | jq -r '.repos // [] | .[].path')"
  exist="$(printf '%s' "$exist" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  out="$(printf '%s' "$reg" | jq -r --arg q "$q" --argjson exist "$exist" '
    def lc: ascii_downcase;
    def subseq($q): ($q | explode) as $qc
      | reduce (. | explode)[] as $c ({i: 0};
          if .i < ($qc | length) and $qc[.i] == $c then .i += 1 else . end)
      | .i == ($qc | length);
    ($q | lc) as $q
    | (.repos // [] | map(select(.path as $p | $exist | index($p)))
        | map(. + {keys: ([.name, .slug] + (.aliases // []) | map(select(. != null and . != "") | lc))})) as $r
    | [ ($r | map(select(.keys | any(. == $q)))),
        ($r | map(select(.keys | any(startswith($q))))),
        ($r | map(select(.keys | any(contains($q))))),
        ($r | map(select(.keys | any(subseq($q))))) ]
    | map(select(length > 0)) | (.[0] // [])
    | sort_by([.name, .path]) | .[] | [.path, .name, (.slug // "")] | @tsv')"
  if [ -z "$out" ]; then return 4; fi
  printf '%s\n' "$out"
}

# repo-resolve-path <path> <any> — path rule: a registered repo (or a linked
# worktree / subfolder of one) resolves to its git toplevel; --any also accepts
# any git work tree. Prints the toplevel.
function repo-resolve-path() {
  local want="$1" any="$2" abs top main reg
  abs="$(repos-abs "$(repos-expand "$want")")" || { printf 'repo: not a folder: %s\n' "$want" >&2; return 4; }
  top="$(repos-toplevel "$abs")"
  if [ -z "$top" ]; then
    printf 'repo: not inside a git repo: %s\n' "$want" >&2
    return 5
  fi
  if [ "$any" = 1 ]; then printf '%s\n' "$top"; return 0; fi
  reg="$(repos-registry-read)" || return 6
  main="$(repos-main-of "$top" || true)"
  if [ -n "$main" ] && printf '%s' "$reg" | jq -e --arg m "$main" '(.repos // []) | any(.path == $m)' >/dev/null; then
    printf '%s\n' "$top"
    return 0
  fi
  printf 'repo: %s is not in the registry; run /repo scan (or pass --any)\n' "$want" >&2
  return 5
}

function repo-resolve() {
  local q="" any=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) q="${2:-}"; [ $# -ge 2 ] || { printf 'repo: --repo needs a value\n' >&2; return 2; }; shift 2 ;;
      --repo=*) q="${1#--repo=}"; shift ;;
      --any) any=1; shift ;;
      *) printf 'repo: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [ -n "$q" ] || q="${CCXP_REPO:-}"
  if [ -n "$q" ]; then
    # shellcheck disable=SC2088
    case "$q" in
      /*|./*|../*|"~"|"~/"*|.|..) repo-resolve-path "$q" "$any"; return $? ;;
    esac
    local hits n rc=0
    hits="$(repo-match-name "$q")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" = 4 ]; then printf 'repo: no repo matches "%s"; run /repo scan\n' "$q" >&2; fi
      return "$rc"
    fi
    n="$(printf '%s\n' "$hits" | grep -c .)"
    if [ "$n" -eq 1 ]; then printf '%s\n' "$hits" | cut -f1; return 0; fi
    printf '%s\n' "$hits"
    return 3
  fi
  local top
  top="$(repos-toplevel)"
  if [ -z "$top" ]; then
    printf 'repo: not inside a git repo and no --repo given\n' >&2
    return 2
  fi
  if [ "$any" = 0 ] && [ ! -d "$top/dev/TODO" ]; then
    printf 'repo: %s has no dev/TODO/; pass --any to use it anyway\n' "$top" >&2
    return 5
  fi
  printf '%s\n' "$top"
}
