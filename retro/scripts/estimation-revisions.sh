#!/usr/bin/env bash
# estimation-revisions.sh [--since YYYY-MM-DD] [--repo-root DIR] T<id> [T<id> ...]
#
# Emit each task's estimation-revision ARC from the task file's git history, so
# /retro can show the trajectory (filed -> revised -> revised) instead of only
# the final `estimation:` value. The retro estimate-vs-actual grade otherwise
# loses 3 of 4 estimation-discipline signals (under-estimate, healthy upward
# discovery, scope-cut-to-fit). See build-pipeline-repo T20260513-725614.
#
# For each task id:
#   * locate the task file in dev/TODO/ or (post-close) dev/JOURNAL/
#   * `git log --follow -p --since=<window>` over it (--follow tracks the
#     TODO->JOURNAL rename)
#   * collect every commit that ADDED an estimation line, in BOTH metadata
#     formats: frontmatter `estimation:` (post-2026-05-14) and the legacy
#     `- **Estimation**:` bullet (pre-migration files)
#   * print `T<id>: filed `X` (subject) -> `Y` (subject) ...`, or
#     `T<id>: no revisions` when the window holds no estimation change.
#
# The window defaults to the last 7 days (the retro period); override with
# --since for a specific iteration or for deterministic tests. Best-effort: a
# missing file is reported (not fatal); no task ids is a usage error (exit 2).
#
# Used by /retro Phase 2 (focus-list grade) + Phase 5 (shipping table).
set -euo pipefail

since=""
repo="."
ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since)     since="${2:?--since needs a date}"; shift 2 ;;
    --repo-root) repo="${2:?--repo-root needs a dir}"; shift 2 ;;
    -h|--help)   sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'; exit 0 ;;
    -*)          echo "estimation-revisions.sh: unknown option '$1'" >&2; exit 2 ;;
    *)           ids+=("$1"); shift ;;
  esac
done

[ "${#ids[@]}" -gt 0 ] || {
  echo "usage: estimation-revisions.sh [--since YYYY-MM-DD] [--repo-root DIR] T<id>..." >&2
  exit 2
}

# default window: last 7 days (GNU date, then BSD date)
if [ -z "$since" ]; then
  since="$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F)"
fi

# Locate the current task file (TODO first, then a closed JOURNAL copy).
# Prints the repo-relative path, or returns non-zero if none exists.
find_task_file() {
  local id="$1" f
  for f in "$repo/dev/TODO/${id}"-*.md "$repo"/dev/JOURNAL/*-"${id}"-*.md; do
    [ -e "$f" ] || continue
    printf '%s\n' "${f#"$repo"/}"
    return 0
  done
  return 1
}

revisions_for() {
  local id="$1" path arc
  if ! path="$(find_task_file "$id")"; then
    printf '%s: (task file not found)\n' "$id"
    return 0
  fi

  # NOTE: no --reverse — `git log --follow` silently drops pre-rename history
  # when combined with --reverse (it only emits the rename commit). So walk
  # newest-first (where --follow works) and reverse the events in awk to get the
  # chronological filed->revised arc.
  arc="$(
    git -C "$repo" log --follow -p --since="$since" \
        --format='===CMT===%H%x09%s' -- "$path" 2>/dev/null \
    | awk '
        BEGIN { n=0; creation=0; subj="" }
        /^===CMT===/ {
          line=substr($0,10); t=index(line,"\t")
          subj=(t>0 ? substr(line,t+1) : line)
          creation=0; next
        }
        /^new file mode/ { creation=1; next }
        /^\+estimation:/ {
          v=$0; sub(/^\+estimation:[ \t]*/,"",v); record(v); next
        }
        /^\+- \*\*Estimation\*\*:/ {
          v=$0; sub(/^\+- \*\*Estimation\*\*:[ \t]*/,"",v); record(v); next
        }
        function record(v) { n++; val[n]=v; sj[n]=subj; cr[n]=creation }
        END {
          # events recorded newest-first; emit oldest-first (i = n .. 1)
          idx=0
          for (i=n; i>=1; i--) {
            idx++
            s=sj[i]; if (length(s)>48) s=substr(s,1,48) "…"
            if (idx==1 && cr[i]) label="filed "
            else if (idx==1)     label=""
            else                 label="→ "
            printf "%s`%s` (%s)  ", label, val[i], s
          }
        }
      '
  )"
  arc="${arc%"${arc##*[![:space:]]}"}"   # rstrip trailing whitespace

  if [ -z "$arc" ]; then
    printf '%s: no revisions\n' "$id"
  else
    printf '%s: %s\n' "$id" "$arc"
  fi
}

for id in "${ids[@]}"; do
  revisions_for "$id"
done
