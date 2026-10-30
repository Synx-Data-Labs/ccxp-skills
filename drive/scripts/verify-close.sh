#!/usr/bin/env bash
# verify-close.sh <task-id> [--base <ref>] — /drive Phase 7 close check, run on the
# close commit before pushing (or on main after the merge).
#
# Checks the task's journal file as COMMITTED at HEAD (not the working tree, which
# is exactly what a `git mv` followed by unstaged edits gets wrong):
#   moved     exactly one dev/JOURNAL/*<id>-*.md at HEAD, no dev/TODO/<id>-*.md left
#   committed the journal file has no unstaged/staged-but-uncommitted edits
#   rename    the move is not a bare 100% rename vs <ref> (default main; skipped
#             when <ref> does not resolve, e.g. after the merge on main)
#   status    frontmatter `status: Done`
#   claim     frontmatter `claimed_by:` absent or empty (body text is ignored)
#   closed    a `## Closed (` section exists
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

tree="$(git ls-tree --name-only HEAD dev/JOURNAL/ dev/TODO/ 2>/dev/null)"
todo="$(printf '%s\n' "$tree" | grep -E "^dev/TODO/${id}(-.*)?\.md$" || true)"
journal="$(printf '%s\n' "$tree" | grep -E "^dev/JOURNAL/.*${id}(-.*)?\.md$" || true)"
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
fi

if [ "${#fails[@]}" -gt 0 ]; then
  printf '%s\n' "${fails[@]}"
  exit 1
fi
echo "ok $file"
