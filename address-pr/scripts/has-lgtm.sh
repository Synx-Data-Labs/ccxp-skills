#!/usr/bin/env bash
#
# has-lgtm.sh — does the PR author's latest decisive comment say LGTM?
# (T20261012-255195; contract in that task's design.)
#
# Usage:
#   bash has-lgtm.sh <pr-number> [--after <iso-time>]
#   bash has-lgtm.sh --from-json <file> [--after <iso-time>]   # pure decision
#
# Exit 0 + author login on stdout: a qualifying LGTM stands.
# Exit 1 + reason on stderr:       no qualifying LGTM (stale, revoked, absent).
# Exit 2:                          usage, fetch or malformed-input error
#                                  (callers treat it as "no LGTM", fail-safe).
#
# Normalized input (--from-json; the live path builds the same shape):
#   {"author":"<login>","pushedAt":"<iso>","comments":[{"login","createdAt","body"}]}
#
# Rules: only the PR author counts (never bots: `[bot]` suffix / `app/` prefix;
# never a `**Claude Code review:**` comment); the comment must be strictly
# after pushedAt (and --after); the first non-empty line must be `lgtm` plus an
# optional `!`/`.`/`,` and short tail (thanks / ship it / merge it) — so
# "LGTM but", "not LGTM", quotes and code fences don't count; the latest
# author comment wins (anything but a clean LGTM revokes), so a later hold,
# "wait", or any other author comment requires a fresh LGTM.
# Timestamps are UTC `...Z`, so string comparison orders them.
#
# GH_SH is overridable for hermetic tests.
set -euo pipefail

GH_SH="${GH_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_gh" && pwd)/gh.sh}"

# Normalize live PR data into the input shape on stdout.
function has-lgtm-fetch() {
  local pr="$1" view rc timeline
  view="$(bash "$GH_SH" pr view "$pr" --json author,commits,comments,reviews)" || return 2
  rc="$(bash "$GH_SH" api --paginate "repos/{owner}/{repo}/pulls/${pr}/comments?per_page=100" \
    | jq -s 'add // []')" || return 2
  timeline="$(bash "$GH_SH" api --paginate "repos/{owner}/{repo}/issues/${pr}/timeline?per_page=100" \
    | jq -s 'add // []')" || return 2
  jq -n --argjson v "$view" --argjson rc "$rc" --argjson tl "$timeline" '
    {
      author: $v.author.login,
      pushedAt: ([($v.commits // [])[].committedDate]
                 + [$tl[] | select(.event == "head_ref_force_pushed") | .created_at]
                 | max // ""),
      comments: (
        [($v.comments // [])[]  | {login: .author.login, createdAt: .createdAt,   body: (.body // "")}]
      + [($v.reviews // [])[]   | {login: .author.login, createdAt: .submittedAt, body: (.body // "")}]
      + [$rc[]                  | {login: .user.login,   createdAt: .created_at,  body: (.body // "")}]
      )
    }'
}

# Decide from normalized JSON on stdin.
function has-lgtm-decide() {
  local after="$1" out
  out="$(jq -r --arg after "$after" '
    def first_line: (.body // "" | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | .[0] // "");
    def bot($l): ($l | test("\\[bot\\]$") or startswith("app/"));
    def rest_ok: ([.body // "" | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | .[1:][]] | join(" ") | ascii_downcase)
                 | test("\\b(but|however|except|unless|before|until|wait|hold|not|don.t|fix|bug|broken|wrong|nit)\\b") | not;
    def kind:
      first_line as $f | ($f | ascii_downcase) as $x
      | if ($f | startswith("**Claude Code review:**")) then "none"
        elif ($x | test("^lgtm([ ]*[!.,]+)?([ ,]+(thanks|thank you|ship it|merge it))?[ !.]*$")) and rest_ok then "lgtm"
        else "other" end;
    (.author // "") as $a
    | (if ($a == "" ) then error("missing author") else . end)
    | (.pushedAt // "") as $p
    | (if ($after > $p) then $after else $p end) as $lo
    | if bot($a) then "no:author is a bot"
      else
        [ .comments[]
          | select(.login == $a and (bot(.login) | not) and (.createdAt > $lo))
          | {t: .createdAt, k: kind} | select(.k != "none") ]
        | sort_by(.t) | last
        | if . == null then "no:no LGTM after the last push"
          elif .k == "lgtm" then "yes:\($a)"
          else "no:revoked by a later author comment" end
      end' 2>/dev/null)" || return 2
  case "$out" in
    yes:*) printf '%s\n' "${out#yes:}" ;;
    no:*)  printf 'has-lgtm: %s\n' "${out#no:}" >&2; return 1 ;;
    *)     return 2 ;;
  esac
}

function has-lgtm-main() {
  local pr="" from="" after=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-json) [ $# -ge 2 ] || { echo "has-lgtm: --from-json needs a value" >&2; return 2; }
                   from="$2"; shift 2 ;;
      --after)     [ $# -ge 2 ] || { echo "has-lgtm: --after needs a value" >&2; return 2; }
                   after="$2"; shift 2 ;;
      *)           pr="$1"; shift ;;
    esac
  done
  local data
  if [ -n "$from" ]; then
    [ -r "$from" ] || { echo "has-lgtm: cannot read $from" >&2; return 2; }
    data="$(cat "$from")"
  elif [ -n "$pr" ]; then
    data="$(has-lgtm-fetch "$pr")" || { echo "has-lgtm: fetch failed" >&2; return 2; }
  else
    echo "usage: has-lgtm.sh <pr-number> | --from-json <file> [--after <iso>]" >&2
    return 2
  fi
  has-lgtm-decide "$after" <<<"$data"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  has-lgtm-main "$@"
fi
