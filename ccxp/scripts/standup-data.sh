#!/usr/bin/env bash
# standup-data.sh — ccxp Phase 1.1 / 1.2.1 / 1.2a: collect the standup FACTS as
# one JSON document. Collection only: no Slack, no writes, no judgment
# (highlights, RCA, classification, top-5 ordering, trend stay with the caller;
# render-standup.sh turns facts + judgment into text).
#
# Usage:  standup-data.sh [--date YYYY-MM-DD] [--dir REPO]
#   --date  "today" for the report (default: $TODAY, else the system date);
#           "yesterday" is the previous calendar day, via _date/date.sh
#           (portable GNU/BSD). The window is [yesterday 00:00, today 00:00).
#   --dir   target repo (default: cwd). Everything is read from it.
# Env:
#   STANDUP_GH            gh command (default: `bash <skills-root>/_gh/gh.sh`)
#   STANDUP_PR_TASK_ID    PR number -> task id command (default
#                         `bash <skills-root>/_session/pr_task_id.sh`)
#   THREADS_FILE          drive-threads.json (default .claude/state/... in --dir)
#
# Stdout: ONE JSON object. Every section is gathered independently: a failing
# section yields its empty default and a message under .errors.<section>; the
# script still exits 0 (the standup must not abort on one bad read). Exit 2 on
# bad usage / invalid date, 3 when --dir is not a directory.
#
# Shape (all keys always present):
#   date, since, errors{}
#   git_log[{sha,subject}]              commits in the window
#   merged_prs[{number,title,mergedAt}]
#   open_prs[{number,title,updatedAt}]
#   attention[{number,title,reasons[]}] deterministic 1.2a rules only: a
#       human-decision unchecked `- [ ]` item, mergeable=CONFLICTING, an
#       unresolved drive-thread on the PR's task. The "CI failed 2+ times"
#       rule needs run history and stays with the caller.
#   journal_yesterday[basename]         dev/JOURNAL files dated yesterday
#   previous_summary                    newest dev/JOURNAL/*-daily-summary.md dated <= today, or ""
#   threads[{key,type,sent_at,summary}] unresolved escalations
#   ipm_file                            current committed IPM path, or ""
#   nightly{since,total,failures[{id,name,createdAt}]}
#   attribution{rows[{location,class,shipped,in_flight,total}]}  [] on a no-data day
#   epics{text,slack[]}                 epic-status.sh render / render --slack
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
date_in="" dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    --date) [ $# -ge 2 ] || { echo "standup-data: --date needs a value" >&2; exit 2; }; date_in="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || { echo "standup-data: --dir needs a value" >&2; exit 2; }; dir="$2"; shift 2 ;;
    *) echo "standup-data: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$dir" ] || { echo "standup-data: not a directory: $dir" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "standup-data: jq is required" >&2; exit 3; }
cd "$dir" || exit 3

today="${date_in:-$(bash "$ROOT/_date/date.sh" today)}"
since="$(bash "$ROOT/_date/date.sh" add "$today" -1)" || exit 2
bash "$ROOT/_date/date.sh" dow "$today" >/dev/null || exit 2   # validates --date

gh_cmd="${STANDUP_GH:-bash $ROOT/_gh/gh.sh}"
prid_cmd="${STANDUP_PR_TASK_ID:-bash $ROOT/_session/pr_task_id.sh}"

ERRS='{}'
err() { ERRS="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$ERRS")"; }

# section <name> <default-json> <command...>: run the command, accept its stdout
# only if it is valid JSON; else record the error and use the default.
OUT='{}'
section() {
  local name="$1" def="$2" val; shift 2
  if val="$("$@" 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"$val"; then :
  else err "$name" "collection failed"; val="$def"; fi
  OUT="$(jq -c --arg k "$name" --argjson v "$val" '. + {($k): $v}' <<<"$OUT")"
}

s_git_log() {
  git log --since="$since 00:00" --until="$today 00:00" --format='%h%x09%s' \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {sha: .[0], subject: (.[1:] | join("\t"))})'
}
s_merged() {
  # shellcheck disable=SC2086
  $gh_cmd pr list --state merged --search "merged:>=$since merged:<$today" --limit 100 --json number,title,mergedAt \
    | jq -c 'map({number,title,mergedAt}) | sort_by(.number)'
}
OPEN_RAW='[]'
s_open_raw() {
  # shellcheck disable=SC2086
  $gh_cmd pr list --state open --limit 100 --json number,title,body,mergeable,updatedAt | jq -c 'sort_by(.number)'
}
s_attention() {
  local n title body mergeable id reasons unresolved open_items
  # a failed read must fail the section (never "nothing needs attention")
  unresolved="$(bash "$ROOT/_threads/threads.sh" list --unresolved 2>/dev/null)" || return 1
  unresolved="$(cut -f1 <<<"$unresolved")"
  jq -c '.[]' <<<"$OPEN_RAW" | while IFS= read -r pr; do
    n="$(jq -r .number <<<"$pr")"; title="$(jq -r .title <<<"$pr")"
    body="$(jq -r '.body // ""' <<<"$pr")"; mergeable="$(jq -r '.mergeable // ""' <<<"$pr")"
    reasons=()
    open_items="$(grep -E '^[[:space:]]*[-*][[:space:]]+\[ \]' <<<"$body" || true)"
    if grep -qiE 'maintainer|your call|decision|approve|escalation' <<<"$open_items"; then
      reasons+=("unchecked pre-merge item needs a human decision")
    fi
    [ "$mergeable" = CONFLICTING ] && reasons+=("merge conflicts")
    # shellcheck disable=SC2086
    id="$($prid_cmd "$n" 2>/dev/null)" || return 1
    id="${id%%$'\n'*}"
    if [ -n "$id" ] && grep -qxE "$id|$id-pr$n" <<<"$unresolved"; then
      reasons+=("unresolved escalation on $id")
    fi
    [ "${#reasons[@]}" -gt 0 ] || continue
    printf '%s\n' "${reasons[@]}" | jq -R . | jq -s -c --argjson n "$n" --arg t "$title" '{number:$n,title:$t,reasons:.}'
  done | jq -s -c '.'
}
s_journal() {
  local f
  for f in dev/JOURNAL/"$since"*; do if [ -e "$f" ]; then basename "$f"; fi; done | LC_ALL=C sort | jq -R -s -c 'split("\n") | map(select(length>0))'
}
s_prev() {
  local f b best=""
  for f in dev/JOURNAL/*-daily-summary.md; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"; [ "${b:0:10}" \> "$today" ] && continue
    best="$f"
  done
  jq -n -c --arg p "$best" '$p'
}
s_threads() {
  bash "$ROOT/_threads/threads.sh" list --unresolved 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {key:.[0], type:.[2], sent_at:.[3], summary:.[4]})'
}
s_ipm() { jq -n -c --arg p "$(IPM_TODAY="$today" bash "$ROOT/_ipm/current.sh" dev/JOURNAL 2>/dev/null)" '$p'; }
s_nightly() {
  local raw
  # shellcheck disable=SC2086
  raw="$($gh_cmd run list --branch main --created ">=$since" --limit 100 --json databaseId,name,conclusion,createdAt)" || return 1
  jq -c --arg s "$since" '{since:$s, total:length,
    failures: [.[] | select(.conclusion=="failure") | {id:.databaseId, name, createdAt}]}' <<<"$raw"
}
s_attribution() {
  bash "$ROOT/_session/attribution.sh" table "dev" "$since" "$today" 2>/dev/null | awk -F'|' '
    NR>2 && NF>=7 { for (i=2;i<=6;i++) { gsub(/^ +| +$/, "", $i) }
      printf "%s\t%s\t%s\t%s\t%s\n", $2,$3,$4,$5,$6 }' \
    | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t")
        | {location:.[0], class:.[1], shipped:(.[2]|tonumber), in_flight:(.[3]|tonumber), total:(.[4]|tonumber)})'
}
s_epics() {
  local t sl
  t="$(bash "$ROOT/ccxp/scripts/epic-status.sh" render 2>/dev/null)" || return 1
  sl="$(bash "$ROOT/ccxp/scripts/epic-status.sh" render --slack 2>/dev/null)" || return 1
  jq -n -c --arg t "$t" --arg s "$sl" '{text:$t, slack:($s | split("\n") | map(select(length>0)))}'
}

section git_log '[]' s_git_log
section merged_prs '[]' s_merged
if OPEN_RAW="$(s_open_raw 2>/dev/null)" && jq -e . >/dev/null 2>&1 <<<"$OPEN_RAW"; then
  OUT="$(jq -c --argjson v "$(jq -c 'map({number,title,updatedAt})' <<<"$OPEN_RAW")" '. + {open_prs:$v}' <<<"$OUT")"
else
  err open_prs "collection failed"; OPEN_RAW='[]'
  OUT="$(jq -c '. + {open_prs:[]}' <<<"$OUT")"
fi
section attention '[]' s_attention
section journal_yesterday '[]' s_journal
section previous_summary '""' s_prev
section threads '[]' s_threads
section ipm_file '""' s_ipm
section nightly "{\"since\":\"$since\",\"total\":0,\"failures\":[]}" s_nightly
section attribution '[]' s_attribution
section epics '{"text":"","slack":[]}' s_epics

jq -n -c --arg d "$today" --arg s "$since" --argjson e "$ERRS" --argjson o "$OUT" \
  '{date:$d, since:$s, errors:$e} + $o'
