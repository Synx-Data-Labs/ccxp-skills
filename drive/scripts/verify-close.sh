#!/usr/bin/env bash
# verify-close.sh <task-id> [--base <ref>] — /drive Phase 7 close check, run on the
# close commit before pushing (or on main after the merge).
#
# Checks the task's journal file as COMMITTED at HEAD (not the working tree, which
# is exactly what a `git mv` followed by unstaged edits gets wrong):
#   moved     exactly one dev/JOURNAL/*<id>-*.md at HEAD and no dev/TODO/<id>-*.md
#             left; the id is matched exactly (T1 never matches T10, and a short
#             id never matches a longer T<8 digits>-<6 digits> id)
#   committed the journal file has no unstaged/staged-but-uncommitted edits
#   rename    the move is not a bare 100% rename vs <ref> (default main; skipped
#             when <ref> does not resolve, e.g. after the merge on main)
#   status    frontmatter `status: Done`
#   claim     frontmatter `claimed_by:` absent or empty (body text is ignored)
#   closed    a `## Closed (` section exists
#   quality   when dev/quality/metrics.jsonl at HEAD has a record for the id whose
#             delta regressed, the `## Closed (` section carries a
#             `- Quality regression ...: <explanation>` line (skipped when there is
#             no scoreboard/record or no jq; notes go to stderr)
#
# stdout: `ok <journal-path>` (exit 0), or one `FAIL <check>: <detail>` line per
# failure (exit 1). Exit 2 usage, 3 not a git repository.
# Judgment stays with the caller: what to write in the Closed section.

set -uo pipefail

usage() { echo "usage: verify-close.sh <task-id> [--base <ref>]" >&2; exit 2; }

id="" base=main
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; base="$2"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$id" ] || usage; id="$1"; shift ;;
  esac
done
[ -n "$id" ] || usage
[[ "$id" =~ ^T[0-9]+(-[0-9]+)?$ ]] || { echo "verify-close.sh: not a task id: $id" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "verify-close.sh: not a git repository" >&2; exit 3; }

fails=()
fail() { fails+=("FAIL $1: $2"); }

# The id a file name carries, matched EXACTLY: a short id (T20000101) must not
# claim the files of a longer one (T20000101-000001). The long form
# T<8 digits>-<6 digits> wins when the name starts with it.
file_id() {
  local b="${1##*/}"
  b="$(printf '%s' "$b" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"
  printf '%s\n' "$b" | sed -nE \
    -e 's/^(T[0-9]{8}-[0-9]{6})([-.].*)$/\1/p;t' \
    -e 's/^(T[0-9]+)([-.].*)$/\1/p'
}
matching() { # <dir-prefix> — paths from $tree under it whose file id is exactly $id
  local p
  while IFS= read -r p; do
    case "$p" in "$1"*.md) [ "$(file_id "$p")" = "$id" ] && echo "$p" ;; esac
  done <<<"$tree"
}

tree="$(git ls-tree --name-only HEAD dev/JOURNAL/ dev/TODO/ 2>/dev/null)"
todo="$(matching dev/TODO/)"
journal="$(matching dev/JOURNAL/)"
[ -z "$todo" ] || fail moved "still in dev/TODO ($(echo $todo)); the close must move it to dev/JOURNAL"
n="$(printf '%s' "$journal" | grep -c . || true)"
file=""
if [ "$n" = 0 ]; then
  fail moved "no dev/JOURNAL file for $id at HEAD"
elif [ "$n" -gt 1 ]; then
  fail moved "$n dev/JOURNAL files match $id: $(echo $journal)"
else
  file="$journal"
fi

if [ -n "$file" ]; then
  [ -z "$(git status --porcelain -- "$file" 2>/dev/null)" ] \
    || fail committed "$file has uncommitted edits; the committed blob is not what you wrote (git add it)"
  if git rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 \
     && git diff -M --name-status "$base...HEAD" 2>/dev/null | grep -qE "^R100[[:space:]].*[[:space:]]${file}\$"; then
    fail rename "$file is a bare 100% rename vs $base: the Closed section and status edit never reached the commit"
  fi
  blob="$(git show "HEAD:$file" 2>/dev/null)"
  fm="$(printf '%s\n' "$blob" | awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}')"
  st="$(printf '%s\n' "$fm" | sed -n 's/^status:[[:space:]]*//p' | head -n1 | tr -d "\"'" | sed 's/[[:space:]]*$//')"
  [ "$st" = Done ] || fail status "status is '${st:-missing}', expected Done"
  cb="$(printf '%s\n' "$fm" | sed -n 's/^claimed_by:[[:space:]]*//p' | head -n1 | tr -d "\"'" | sed 's/[[:space:]]*$//')"
  case "$cb" in ""|null|~) ;; *) fail claim "claimed_by is still '$cb'; clear it with _session/task_claim.sh release $id Done" ;; esac
  printf '%s\n' "$blob" | grep -qE '^## Closed \(' || fail closed "no '## Closed (YYYY-MM-DD)' section"
  # quality: every scoreboard record for this exact id, a later clean re-run must not mask an earlier regression.
  mf="$(git show HEAD:dev/quality/metrics.jsonl 2>/dev/null || true)"
  if [ -n "$mf" ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "verify-close.sh: skip quality check: jq not installed" >&2
    else
      regs="$(printf '%s\n' "$mf" | jq -R -r --arg id "$id" -L "$(dirname "${BASH_SOURCE[0]}")/../../quality-probe/scripts" \
        'include "regress"; (fromjson? // empty) | select(type == "object" and .task == $id) | (.delta // {}) | qp_regressed | split(" ")[0]' 2>/dev/null | sort -u | paste -sd, -)"
      if [ -n "$regs" ]; then
        note="$(printf '%s\n' "$blob" | awk '/^## Closed \(/{f=1; next} /^## /{f=0} f' \
          | sed -nE 's/^- Quality regression[^:]*:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | grep -v -e '<your explanation>' -e '<one-line explanation>' | head -n1)"
        [ -n "$note" ] || fail quality "scoreboard shows a regression ($regs) with no '- Quality regression (...): <explanation>' line in the ## Closed section"
      fi
    fi
  fi
fi

if [ "${#fails[@]}" -gt 0 ]; then
  printf '%s\n' "${fails[@]}"
  exit 1
fi
echo "ok $file"
