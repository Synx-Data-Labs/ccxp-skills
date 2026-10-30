#!/usr/bin/env bash
# render-standup.sh — ccxp Phase 1.3 / 1.4: render the standup text from the
# FACTS (standup-data.sh output) plus the caller's JUDGMENT. Dumb on purpose:
# no gh, no git, no Slack, no clock; same inputs -> byte-identical output.
# It never sends anything: the `slack_send_message` / slack-fallback.sh call
# stays in SKILL.md.
#
# Usage: render-standup.sh DATA.json JUDGMENT.json [--format slack|journal] [--max-chars N]
#   --format slack    (default) the *Daily Standup* mrkdwn message of Phase 1.4,
#                     including its omit rules and trim ladder.
#   --format journal  the dev/JOURNAL/YYYY-MM-DD-daily-summary.md of Phase 1.3.
#   --max-chars N     slack length cap (default 5000, the MCP text-element cap).
#
# JUDGMENT.json (everything the scripts must not decide; all keys optional
# except top5):
#   resolved[]          {pr, text}   highlight per merged PR, text verbatim,
#                                    e.g. "<url|Tid> - what and why"; " (PR #N)"
#                                    is appended. A merged PR with no entry
#                                    falls back to its title.
#   nightly_failures[]  {run, workflow?, classification, task_link?, task_id?}
#                                    one per failed run in DATA.nightly.failures.
#                                    A failure with no entry is an input error.
#   alert_replies       {posted, no_alert, already}   (journal, only when failures)
#   attention[]         {pr, title, why}   replaces DATA.attention (use it to add
#                                    the CI-failure rule); absent = DATA.attention
#   top5[]              strings, required (may be empty)
#   weekly_focus        {shipped, total, in_flight, not_started, trend, table?}
#                                    absent = the Weekly focus block is omitted
#   links               {<thread key>: "<url|Tid>"}   mrkdwn links for Blockers
#
# Omit rules (as in SKILL.md 1.4): Weekly focus (no weekly_focus), Epic
# progress (no epic lines) and Attribution (no ccxp/interactive rows) vanish;
# Resolved, Nightly, Needs your attention, Top 5 next and Blockers always
# render with their None/Nothing/all-green fallback. A failed data section
# (DATA.errors) renders as "unavailable", never as a clean answer.
# Trim ladder when slack output exceeds --max-chars: (1) one line per Resolved
# item and the first reason per attention item, (2) drop Attribution; still too
# long -> exit 5, nothing on stdout (shorten the judgment text and rerun).
# Exit: 0 ok, 2 usage, 3 unreadable/invalid JSON, 4 missing judgment, 5 too long.
set -euo pipefail

die() { echo "render-standup: $2" >&2; exit "$1"; }
[ $# -ge 2 ] || die 2 "usage: render-standup.sh DATA.json JUDGMENT.json [--format slack|journal] [--max-chars N]"
data="$1" judg="$2"; shift 2
fmt=slack max=5000
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die 2 "$1 needs a value"
  case "$1" in
    --format) fmt="$2"; shift 2 ;;
    --max-chars) max="$2"; shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
case "$fmt" in slack|journal) ;; *) die 2 "--format must be slack or journal" ;; esac
[[ "$max" =~ ^[0-9]{1,9}$ ]] || die 2 "--max-chars must be a positive integer"
command -v jq >/dev/null 2>&1 || die 3 "jq is required"
if ! { [ -r "$data" ] && jq -e 'type=="object" and has("date") and has("nightly")' "$data" >/dev/null 2>&1; }; then
  die 3 "DATA.json is not a standup-data.sh document: $data"
fi
if ! { [ -r "$judg" ] && jq -e 'type=="object"' "$judg" >/dev/null 2>&1; }; then
  die 3 "JUDGMENT.json is not a JSON object: $judg"
fi

missing="$(jq -r -n --slurpfile d "$data" --slurpfile j "$judg" '
  ($j[0].nightly_failures // []) as $nf
  | (if ($j[0].top5|type)=="array" then empty else "top5" end),
    ($d[0].nightly.failures[]? | select(.id as $i | ($nf | map(.run) | index($i)) == null) | "nightly_failures run \(.id)")')"
[ -z "$missing" ] || die 4 "missing judgment: $(echo "$missing" | paste -sd, -)"

# Shared jq definitions.
read -r -d '' DEFS <<'JQ' || true
def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
def unavail($k): ($d.errors[$k] // null) != null;
def one(l): if l >= 1 then split("\n")[0] else . end;
def firstreason(l): if l >= 1 then split("; ")[0] else . end;
def attn: ($j.attention // ($d.attention | map({pr: .number, title: .title, why: (.reasons | join("; "))})));
def resolved(l): [ $d.merged_prs[]? | . as $p
    | (($j.resolved // []) | map(select(.pr == $p.number)) | first // null) as $r
    | "\(($r.text // ($p.title | esc)) | one(l)) (PR #\($p.number))" ];
def fails: $d.nightly.failures;
def jf($id): (($j.nightly_failures // []) | map(select(.run == $id)) | first);
def cls: ([ $d.attribution[]? | select(.class=="ccxp" or .class=="interactive") ]);
def clsum($c; $k): ([ cls[] | select(.class==$c) | .[$k] ] | add // 0);
JQ

render_slack() { # $1 = trim level 0|1|2
  jq -n -r --slurpfile d "$data" --slurpfile j "$judg" --argjson lvl "$1" "
  \$d[0] as \$d | \$j[0] as \$j | $DEFS
  (if \$lvl >= 1 then 1 else 0 end) as \$l1 |
  [ \"*Daily Standup* (\(\$d.date))\", \"\" ] +
  ( resolved(\$l1) as \$r |
    if (\$d.errors.merged_prs // null) then [\"*✅ Resolved*: unavailable (merged-PR query failed)\"]
    else [\"*✅ Resolved* (\(\$r|length))\"] + (if (\$r|length)==0 then [\"Nothing merged yesterday\"] else (\$r | map(\"• \" + .)) end) end ) +
  [ \"\" ] +
  ( if (\$d.errors.nightly // null) then [\"*🌙 Nightly*: unavailable (run query failed)\"]
    elif (fails|length)==0 then [\"*🌙 Nightly*: all green (\(\$d.nightly.total) runs)\"]
    else [\"*🌙 Nightly*: \(fails|length) failure(s) / \(\$d.nightly.total) runs\"] +
      ( fails | map( jf(.id) as \$f | \"• \(\$f.workflow // (.name | esc)) (run \(.id)) — \(\$f.classification) — \(\$f.task_link // \$f.task_id // \"no task filed (transient/infra)\")\" ) ) end ) +
  [ \"\" ] +
  ( attn as \$a |
    if (unavail(\"open_prs\") or unavail(\"attention\")) and (\$j.attention|not) then [\"*🔀 Needs your attention*: unavailable (PR query failed)\"]
    else [\"*🔀 Needs your attention* (\(\$a|length))\"] +
      (if (\$a|length)==0 then [\"None — every open PR is actionable or already in flight\"]
       else (\$a | map(\"• PR #\(.pr) — \(.title | esc) — \(.why | firstreason(\$l1))\")) end) end ) +
  [ \"\", \"*📋 Top 5 next*\" ] +
  ( if (\$j.top5|length)==0 then [\"None — nothing workable in the queue\"]
    else (\$j.top5[:5] | to_entries | map(\"\(.key+1). \(.value)\")) end ) +
  ( if unavail(\"epics\") then [\"\", \"*🎯 Epic progress*\", \"unavailable (epic read failed)\"]
    elif ((\$d.epics.slack // [])|length) > 0 then [\"\", \"*🎯 Epic progress*\"] + \$d.epics.slack else [] end ) +
  ( if \$j.weekly_focus then [\"\", \"*📌 Weekly focus*\",
      \"• \(\$j.weekly_focus.shipped)/\(\$j.weekly_focus.total) shipped, \(\$j.weekly_focus.in_flight) in flight, \(\$j.weekly_focus.not_started) not started\",
      \"• Trend: \(\$j.weekly_focus.trend)\"] else [] end ) +
  ( if unavail(\"attribution\") and \$lvl < 2 then [\"\", \"*📊 Attribution*\", \"• unavailable (attribution read failed)\"]
    elif (cls|length) > 0 and \$lvl < 2 then [\"\", \"*📊 Attribution*\",
      \"• ccxp: \(clsum(\"ccxp\"; \"shipped\")) shipped / \(clsum(\"ccxp\"; \"in_flight\")) in-flight\",
      \"• interactive: \(clsum(\"interactive\"; \"shipped\")) shipped / \(clsum(\"interactive\"; \"in_flight\")) in-flight\"] else [] end ) +
  [ \"\", \"*🚧 Blockers*\" ] +
  ( if unavail(\"threads\") then [\"• unavailable (escalation read failed)\"]
    elif (\$d.threads|length)==0 then [\"• None\"]
    else (\$d.threads | map(\"• \((\$j.links[.key]) // .key) — \(.summary | esc)\")) end )
  | join(\"\n\")"
}

render_journal() {
  jq -n -r --slurpfile d "$data" --slurpfile j "$judg" "
  \$d[0] as \$d | \$j[0] as \$j | $DEFS
  [ \"# Daily Summary: \(\$d.date)\", \"\", \"## Resolved\" ] +
  ( resolved(0) as \$r |
    if (\$d.errors.merged_prs // null) then [\"Unavailable — merged-PR query failed.\"]
    elif (\$r|length)==0 then [\"Nothing merged yesterday\"] else (\$r | map(\"- \" + .)) end ) +
  [ \"\", \"## Nightly health\" ] +
  ( if (\$d.errors.nightly // null) then [\"- Unavailable — run query failed.\"]
    else
      [ \"- Runs checked: \(\$d.nightly.total)\",
        \"- Failures: \(fails|length) (\(if (fails|length)==0 then \"None\" else (fails | map(jf(.id).workflow // .name) | join(\", \")) end))\" ] +
      ( [ fails[] | jf(.id) | (.task_id // empty) ] as \$t |
        [\"- Tasks created: \(\$t|length) (\(if (\$t|length)==0 then \"None\" else (\$t|join(\", \")) end))\"] ) +
      [ \"- Classification breakdown: \(if (fails|length)==0 then \"All green\" else
          ( [ fails[] | jf(.id).classification | ascii_downcase ] | group_by(.) | map(\"\(length) \(.[0])\") | join(\", \") ) end)\" ] +
      ( if (fails|length) > 0 and \$j.alert_replies then
          [\"- Alert-thread replies: \(\$j.alert_replies.posted // 0) posted, \(\$j.alert_replies.no_alert // 0) no matching alert found, \(\$j.alert_replies.already // 0) already replied\"] else [] end )
    end ) +
  [ \"\", \"## PRs needing attention\", \"\" ] +
  ( attn as \$a |
    if (unavail(\"open_prs\") or unavail(\"attention\")) and (\$j.attention|not) then [\"Unavailable — PR query failed.\"]
    elif (\$a|length)==0 then [\"None — every open PR is actionable or already in flight\"]
    else [\"| PR | Title | Why it needs you |\", \"|----|-------|-------------------|\"] +
      (\$a | map(\"| #\(.pr) | \(.title | gsub(\"\\\\|\"; \"/\")) | \(.why | gsub(\"\\\\|\"; \"/\")) |\")) end ) +
  [ \"\", \"## Top 5 next\", \"\" ] +
  ( if (\$j.top5|length)==0 then [\"None — nothing workable in the queue\"]
    else (\$j.top5[:5] | to_entries | map(\"\(.key+1). \(.value)\")) end ) +
  [ \"\", \"## Epic progress\", \"\", (if unavail(\"epics\") then \"Unavailable — epic read failed.\" else (\$d.epics.text // \"\") end) ] +
  ( if \$j.weekly_focus then [\"\", \"## Weekly focus progress\", \"\",
      \"References: \(\$d.ipm_file)\", \"\"] +
      (if \$j.weekly_focus.table then [\$j.weekly_focus.table, \"\"] else [] end) +
      [\"**Summary**: \(\$j.weekly_focus.shipped)/\(\$j.weekly_focus.total) shipped, \(\$j.weekly_focus.in_flight) in flight, \(\$j.weekly_focus.not_started) not started. **Trend**: \(\$j.weekly_focus.trend).\"] else [] end ) +
  ( if unavail(\"attribution\") then [\"\", \"## Task attribution by location\", \"\", \"Unavailable — attribution read failed.\"]
    elif (\$d.attribution|length) > 0 then [\"\", \"## Task attribution by location\", \"\",
      \"| Location | Class | Shipped | In-flight | Total |\", \"|----------|-------|---------|-----------|-------|\"] +
      (\$d.attribution | map(\"| \(.location) | \(.class) | \(.shipped) | \(.in_flight) | \(.total) |\")) else [] end ) +
  [ \"\", \"## Open escalations\" ] +
  ( if unavail(\"threads\") then [\"- Unavailable — escalation read failed.\"]
    elif (\$d.threads|length)==0 then [\"- None\"] else (\$d.threads | map(\"- \(.key) — \(.summary)\")) end ) +
  [ \"\", \"## Housekeeping\", \"- No claim housekeeping needed (one session per clone)\" ]
  | join(\"\n\")"
}

if [ "$fmt" = journal ]; then render_journal; exit 0; fi

for lvl in 0 1 2; do
  out="$(render_slack "$lvl")"
  if [ "${#out}" -le "$max" ]; then printf '%s\n' "$out"; exit 0; fi
done
die 5 "standup is ${#out} chars after the full trim ladder (cap $max); shorten the judgment text and rerun"
