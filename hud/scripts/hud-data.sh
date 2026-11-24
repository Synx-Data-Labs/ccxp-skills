#!/usr/bin/env bash
# JSON data helper for the ccxp-hud mod (T20261022-345549).
#
# Reads a statusLine-shaped JSON object on stdin ({cwd, session_id, ...}) and
# prints ONE JSON object built from the SAME sl-* functions (hud-lib.sh)
# so there is a single source of truth and the claimant secret never
# leaves bash (the mod only ever sees task id/title, never the claimed_by value):
#
#   {"repo","task_id","task_title","branch","worktree",
#    "cwd","repo_slug","repo_root","head","dirty","gh_account",  # repo identity for the session
#                         # cwd. `repo` stays the always-present name (origin's last path part, else
#                         # the folder name). The rest are null outside a git repo: repo_slug =
#                         # owner/name; head = short id when detached ("" otherwise); dirty = changed
#                         # tracked files, capped 99, null when unknown; gh_account from direnv/.envrc
#                         # GH_CONFIG_DIR + hosts.yml (never the token; cached 60 s; no network)
#    "autopilot": null | {"status","prefix","elapsed_hr","requested_hr",
#                         "stuck","cycle","last_outcome","last_task",
#                         "stuck_reason","stop_reason","merged",
#                         "next_wake_at",   # epoch secs of the next loop, 0 = none/unknown
#                         "busy","current_task",   # busy: a cycle is running; current_task: its task id ("" = unknown)
#                         "busy_slots",   # parallel cycles running (max_dop > 1), 0 when none, 1 for a single cycle
#                         "busy_routine", # of those, the cycles in routine slots (not marked urgent), the ones counted against max_dop less reserved
#                         "stats"},   # null | {"has_history","approx","merged_24h","cycles_24h","avg_merged_24h","trend"}: rolling 24h vs lifetime avg/day
#    "ap_config": null | {"max_dop","reserved_slots","source","file"},   # the autopilot's EFFECTIVE settings (autopilot-state.sh config-show --json via sl-autopilot-config, cached per repo): null unless the autopilot is on/paused or dev/.autopilot-config.json exists; reserved_slots is null when the autopilot script does not report it; source = override|default; file = the config file exists
#    "ledger": null | {"running":[{"job","title"}],"lifetime_jobs","parked":[{"id"}],
#                      "next_job","updated_at"},   # ledger.sh file
#    "queue": null | {"total","ready","held","epic","claimed","autoparked","apholds"[,"source","branch"|"fallback"][,"hwm":{"lm","lw","tw"}]},
#                         # dev/TODO/queue.md breakdown (sl-queue-json in hud-lib.sh: buckets sum to total); null without a queue.
#                         # `source`/`branch` unless stdin `queue_source` is "working-tree" (opt-in): read from origin/<branch>
#                         # (git object reads, no checkout); `source:"working-tree",fallback:true` when origin/<default> was unavailable
#                         # `hwm`: {"lm","lw","tw"} the largest queue length in the 14-to-42-days-ago, 7-to-14-days-ago and last-7-days windows (null = no data), from
#                         # git history of the default branch's queue file plus local samples (hud-queue-hwm.sh); absent when unknown
#    "ci": null | {"state","at"[,"eta"]},   # last run of the CONFIGURED workflow (hud-ci.sh); eta only while running
#    "nightly": null | {"red","green"?,"strip"},   # SynxDB nightly: red and green days in the last 30 UTC days + last-7-days strip (+ - .), cached 30 min (hud-nightly.sh)
#    "issues": null | {"open","undelivered","hwm"?: {"d180","d30","d7"}},   # opt-in customer-issue stats (stdin `issues` {repo,gh_config_dir?}); cached 15 min, detached refresh (hud-issues.sh)
#    "bus": null | {"unread","from"},   # unread cross-account bus notes (count, newest sender); local files only (hud-bus.sh, _bus/bus.sh status --json); null when off or nothing unread
#    "behind": null | {"behind","ahead","base"},   # commits the branch is behind / ahead of its upstream ("base":"upstream") or origin's default branch ("origin"); null when 0/0, detached, or no reference (hud-behind.sh)
#    "plugin": null | {"installed","latest","url"?},   # ccxp-skills version; latest = highest known release, null when unknown (hud-version.sh)
#    "last_input_at": 0}        # epoch secs of this session's last prompt (0 = unknown)
#
# stdin also carries the mod's `ci` config ({workflow,branch?,repo?} or null) and
# `ci_ttl` (poll seconds), `show_version` (bool, default true), `show_bus` (bool, default true),
# `issues` ({repo,gh_config_dir?} or null = off), `queue_source` ("default-branch" default, also for absent or unknown | "working-tree" opt-in). Never exits non-zero: any failure prints "{}" so the mod
# keeps its last good snapshot. The only network use is the detached, cached,
# time-limited CI lookup in hud-ci.sh; the only writes are its cache files (and the rate-limited detached `git fetch origin <default>` unless queue_source is working-tree, and only when a queue exists).

_HD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-lib.sh
. "$_HD_DIR/hud-lib.sh"
# shellcheck source=hud-ci.sh
. "$_HD_DIR/hud-ci.sh"
# shellcheck source=hud-bus.sh
. "$_HD_DIR/hud-bus.sh"
# shellcheck source=hud-version.sh
. "$_HD_DIR/hud-version.sh"
# shellcheck source=hud-behind.sh
. "$_HD_DIR/hud-behind.sh"
# shellcheck source=hud-queue-hwm.sh
. "$_HD_DIR/hud-queue-hwm.sh"
# shellcheck source=hud-nightly.sh
. "$_HD_DIR/hud-nightly.sh"
# shellcheck source=hud-issues.sh
. "$_HD_DIR/hud-issues.sh"

hud-data() {
  local input cwd session_id ci_cfg ci_ttl show_version queue_source
  input=$(cat)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // ""' 2>/dev/null) || cwd=""
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
  [ -n "$cwd" ] || cwd="$PWD"
  ci_cfg=$(printf '%s' "$input" | jq -c '.ci // null' 2>/dev/null) || ci_cfg="null"
  ci_ttl=$(printf '%s' "$input" | jq -r '(.ci_ttl // 0) | floor' 2>/dev/null) || ci_ttl=0

  show_version=$(printf '%s' "$input" | jq -r 'if .show_version == false then 0 else 1 end' 2>/dev/null) || show_version=1

  queue_source=$(printf '%s' "$input" | jq -r 'if .queue_source == "working-tree" then "working-tree" else "default-branch" end' 2>/dev/null) || queue_source="default-branch"

  local repo_root clone_id label task_id="" task_title="" branch rec
  repo_root=$(sl-repo-root "$cwd")
  clone_id=$(sl-clone-id "$repo_root")
  label=$(sl-claimed-task-label "$repo_root/dev/TODO" "$clone_id")
  if [ -n "$label" ]; then
    task_id="${label%%:*}"
    [ "$label" = "$task_id" ] || task_title="${label#*: }"
  fi
  branch=$(sl-branch-name "$repo_root")
  # Linked worktree name ("" in the main checkout): git-dir differs from the
  # shared common dir only inside `git worktree add` checkouts.
  local worktree="" gd cd_
  gd=$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  cd_=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || cd_=""
  if [ -n "$gd" ] && [ -n "$cd_" ] && [ "$gd" != "$cd_" ]; then worktree=$(basename "$repo_root"); fi
  rec=$(sl-autopilot-fields "$repo_root")
  local ap_stats=""
  [ -z "$rec" ] || ap_stats=$(sl-autopilot-stats "$repo_root" 2>/dev/null) || ap_stats=""
  [ -n "$ap_stats" ] || ap_stats="null"
  local ap_config; ap_config=$(sl-autopilot-config "$repo_root" "$rec" 2>/dev/null) || ap_config=""
  [ -n "$ap_config" ] || ap_config="null"

  # Repo identity: only when cwd is really inside a git work tree. Outside one
  # these stay empty and become JSON null (`repo` still names the folder).
  local slug="" top="" head="" dirty="" gh_account="" behind="null"
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ]; then
    slug=$(sl-repo-slug "$top")
    head=$(sl-detached-head "$top")
    dirty=$(sl-dirty-count "$top")
    gh_account=$(sl-gh-account "$top")
    behind=$(hud-behind-json "$top" 2>/dev/null) || behind="null"
    [ -n "$behind" ] || behind="null"
  fi

  local ledger; ledger=$(sl-ledger-json)
  [ -n "$ledger" ] || ledger="null"

  local queue; queue=$(sl-queue-json "$repo_root" "$queue_source" 2>/dev/null) || queue=""
  [ -n "$queue" ] || queue="null"
  if [ "$queue" != "null" ]; then
    # High watermark (hud-queue-hwm.sh): samples the length, kicks a detached git-history backfill, reads local files only.
    local hwm; hwm=$(sl-queue-hwm "$repo_root" "$(printf '%s' "$queue" | jq -r '.total // empty' 2>/dev/null)" 2>/dev/null) || hwm=""
    if [ -n "$hwm" ]; then queue=$(printf '%s' "$queue" | jq -c --argjson h "$hwm" '. + {hwm: $h}' 2>/dev/null) || true; fi
    [ -n "$queue" ] || queue="null"
  fi

  local repo_name ci
  repo_name=$(sl-origin-name "$repo_root")
  [ -n "$repo_name" ] || repo_name=$(basename "$repo_root")
  ci=$(hud-ci-json "$repo_root" "$ci_cfg" "$ci_ttl" 2>/dev/null) || ci="null"
  [ -n "$ci" ] || ci="null"

  local nightly
  nightly=$(hud-nightly-json 2>/dev/null) || nightly="null"
  [ -n "$nightly" ] || nightly="null"

  local issues="null" issues_repo issues_gh
  issues_repo=$(printf '%s' "$input" | jq -r '.issues.repo // empty | strings' 2>/dev/null) || issues_repo=""
  issues_gh=$(printf '%s' "$input" | jq -r '.issues.gh_config_dir // empty | strings' 2>/dev/null) || issues_gh=""
  if [ -n "$issues_repo" ]; then issues=$(hud-issues-json "$issues_repo" "$issues_gh" 2>/dev/null) || issues="null"; fi
  [ -n "$issues" ] || issues="null"

  local bus show_bus
  show_bus=$(printf '%s' "$input" | jq -r 'if .show_bus == false then 0 else 1 end' 2>/dev/null) || show_bus=1
  bus=$(hud-bus-json "$(cd "$_HD_DIR/../.." && pwd)" "$show_bus" 2>/dev/null) || bus="null"
  [ -n "$bus" ] || bus="null"

  local plugin
  plugin=$(hud-version-json "$(cd "$_HD_DIR/../.." && pwd)" "$show_version" 2>/dev/null) || plugin="null"
  [ -n "$plugin" ] || plugin="null"

  local last_input_at
  last_input_at=$(sl-last-input-epoch "$LAST_INPUT_STATE_DIR" "$session_id")
  [[ "$last_input_at" =~ ^[0-9]+$ ]] || last_input_at=0

  jq -n -c \
    --arg task_id "$task_id" --arg task_title "$task_title" \
    --arg branch "$branch" --arg worktree "$worktree" --arg cwd "$cwd" --arg slug "$slug" --arg top "$top" \
    --arg head "$head" --arg dirty "$dirty" --arg gh_account "$gh_account" --arg rec "$rec" --argjson apstats "$ap_stats" --argjson apconfig "$ap_config" --argjson ledger "$ledger" --argjson queue "$queue" --argjson ci "$ci" --argjson bus "$bus" --argjson nightly "$nightly" --argjson issues "$issues" --argjson plugin "$plugin" --argjson behind "$behind" --arg repo "$repo_name" --argjson last_input_at "$last_input_at" '
    ($rec | split("\u001f")) as $f
    | {repo: $repo, task_id: $task_id, task_title: $task_title, branch: $branch, worktree: $worktree,
       cwd: $cwd, repo_slug: (if $slug == "" then null else $slug end),
       repo_root: (if $top == "" then null else $top end), head: $head,
       dirty: (if $dirty == "" then null else ($dirty | tonumber? // null) end),
       gh_account: (if $gh_account == "" then null else $gh_account end),
       autopilot: (if $rec == "" then null else {
         status: $f[0], prefix: $f[1],
         elapsed_hr: ($f[2] | tonumber), requested_hr: ($f[3] | tonumber),
         stuck: ($f[4] | tonumber), cycle: ($f[5] | tonumber),
         last_outcome: $f[6], last_task: $f[7],
         stuck_reason: $f[8], stop_reason: $f[9], merged: (($f[10] // "0") | tonumber? // 0),
         next_wake_at: (($f[11] // "") | tonumber? // 0),
         busy: (($f[12] // "") == "1"), current_task: ($f[13] // ""), busy_slots: (($f[14] // "") | tonumber? // 0), busy_routine: (($f[15] // "") | tonumber? // 0), stats: $apstats} end),
       ap_config: $apconfig, ledger: $ledger, queue: $queue, ci: $ci, nightly: $nightly, issues: $issues, bus: $bus, plugin: $plugin, behind: $behind,
       last_input_at: $last_input_at}'
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _hd_out=$(hud-data "$@" 2>/dev/null) || _hd_out=""
  # Never fail the mod's call: empty/failed output becomes an empty object.
  if [ -n "$_hd_out" ]; then printf '%s\n' "$_hd_out"; else printf '{}\n'; fi
  exit 0
fi
