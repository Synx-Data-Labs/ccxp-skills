#!/usr/bin/env bats
# Tests for autopilot/scripts/autopilot-state.sh (T20261028-151063).

load test_helper
SCRIPT="$REPO_ROOT/autopilot/scripts/autopilot-state.sh"

setup() {
  export AUTOPILOT_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  export AUTOPILOT_CONFIG_FILE="$BATS_TEST_TMPDIR/config.json"
  export AUTOPILOT_TODAY="2026-10-28"
  export AUTOPILOT_NOW="2026-10-28T10:00:00Z"
  # Slack env vars unset: the fallback must be the normal, error-free path.
  unset SLACK_WEBHOOK_URL SLACK_WEBHOOK_URL_DEV
  export AUTOPILOT_SLACK_SEND="$BATS_TEST_TMPDIR/no-such-sender.sh"
}

_ap() { bash "$SCRIPT" "$@"; }
_j() { jq -r "$1" "$AUTOPILOT_STATE_FILE"; }

@test "grammar: SKILL.md documents exactly on/off/pause/resume/status, no duration" {
  run grep -n 'argument-hint' "$REPO_ROOT/autopilot/SKILL.md"
  [[ "$output" == *"on | off | pause | resume | status"* ]]
  run grep -nE '<duration>|--now' "$REPO_ROOT/autopilot/SKILL.md"
  [ "$status" -ne 0 ]
  # The old resume token survives only in the one sentence that refuses it.
  [ "$(grep -c 'until <ISO' "$REPO_ROOT/autopilot/SKILL.md")" -eq 1 ]
  run grep -n 'ScheduleWakeup(delaySeconds.*prompt: "/autopilot on"' "$REPO_ROOT/autopilot/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "status: missing file is off" {
  run _ap status; [ "$output" = off ]
}

@test "status: legacy and malformed state files read as off" {
  printf '%s' '{"status":"running","end_time":"2026-10-28T20:00:00Z"}' > "$AUTOPILOT_STATE_FILE"
  run _ap status; [ "$output" = off ]
  printf '%s' '{"status":"paused","end_time":"x"}' > "$AUTOPILOT_STATE_FILE"
  run _ap status; [ "$output" = off ]
  printf '{not json' > "$AUTOPILOT_STATE_FILE"
  run _ap status; [ "$output" = off ]
}

@test "start: off -> on writes a fresh schema-2 state, overwriting a legacy file" {
  printf '%s' '{"status":"running","end_time":"2026-10-28T20:00:00Z"}' > "$AUTOPILOT_STATE_FILE"
  run _ap start; [ "$output" = started ]
  [ "$(_j .schema)" = 2 ]; [ "$(_j .status)" = on ]; [ "$(_j .cycle_count)" = 0 ]
  [ "$(_j 'has("end_time")')" = false ]
}

@test "start: on again dispatches only when due and not busy; paused stays paused" {
  _ap start >/dev/null
  run _ap start; [ "$output" = dispatch ]
  _ap record progress 0 T1 >/dev/null        # arms next_wake_at 60 s ahead
  run _ap start; [ "$output" = already-on ]  # a typed "on" before the wake is due
  AUTOPILOT_NOW="2026-10-28T10:00:40Z" run _ap start; [ "$output" = dispatch ]   # within the 30 s tolerance
  AUTOPILOT_NOW="2026-10-28T10:05:00Z" run _ap start; [ "$output" = dispatch ]
  _ap busy on
  AUTOPILOT_NOW="2026-10-28T10:05:00Z" run _ap start; [ "$output" = already-on ]
  AUTOPILOT_NOW="2026-10-28T14:00:00Z" run _ap start; [ "$output" = dispatch ]  # busy mark older than 3 h = crashed
  _ap pause >/dev/null
  run _ap start; [ "$output" = paused ]; [ "$(_ap status)" = paused ]
}

@test "stale wake after off then on does nothing before the new next_wake_at" {
  _ap start >/dev/null; _ap off >/dev/null
  run _ap start; [ "$output" = started ]
  _ap record progress 0 T1 >/dev/null
  run _ap start; [ "$output" = already-on ]
}

@test "off clears next_wake_at and skip_ids but keeps busy_since until the cycle reports" {
  _ap start >/dev/null; _ap skip T9 "needs build" >/dev/null
  _ap record progress 0 T1 >/dev/null; _ap busy on
  _ap off >/dev/null
  [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .next_wake_at)" = null ]; [ "$(_j '.skip_ids|length')" = 0 ]
}

@test "on right after off while the old cycle is busy does nothing (busy)" {
  _ap start >/dev/null; _ap busy on; _ap off >/dev/null
  run _ap start; [ "$output" = busy ]
  [ "$(_ap status)" = on ]; [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]
  _ap busy off
  AUTOPILOT_NOW="2026-10-28T10:02:00Z" run _ap start; [ "$output" = dispatch ]
}

@test "resume: shifts started_at by the pause length and dispatches; busy means do nothing" {
  _ap start >/dev/null
  AUTOPILOT_NOW="2026-10-28T11:00:00Z" _ap pause >/dev/null
  AUTOPILOT_NOW="2026-10-28T12:00:00Z" run _ap resume
  [ "$output" = dispatch ]
  [ "$(_j .started_at)" = "2026-10-28T11:00:00Z" ]
  _ap pause >/dev/null; _ap busy on
  run _ap resume; [ "$output" = busy ]
}

@test "status report: shows needs-attention, notices and overdue" {
  _ap start >/dev/null
  _ap skip T9 "needs a real build" >/dev/null
  _ap notify idle "nothing drivable" >/dev/null
  _ap record idle >/dev/null
  AUTOPILOT_NOW="2026-10-28T20:00:00Z" run _ap report
  [[ "$output" == *"needs attention: T9"* ]]
  [[ "$output" == *"notice [fallback] idle"* ]]
  [[ "$output" == *"overdue"* ]]
}

@test "waiting: notice once when it repeats, cleared by progress" {
  _ap start >/dev/null
  run _ap record waiting 0 T1; [ "$output" = none ]
  run _ap record waiting 0 T1; [ "$output" = waiting ]
  run _ap record waiting 0 T1; [ "$output" = none ]
  _ap record progress 1 T1 >/dev/null
  [ "$(_j .waiting_notified)" = false ]
}

@test "skip: a new task notifies once with its reason; skip_ids clear at the daily rollover" {
  _ap start >/dev/null
  run _ap skip T1 "publishes a tag"; [ "$output" = attention ]
  run _ap skip T1 "publishes a tag"; [ "$output" = none ]
  [ "$(_j '.needs_attention[0].reason')" = "publishes a tag" ]
  AUTOPILOT_TODAY=2026-10-29 _ap cap >/dev/null
  [ "$(_j '.skip_ids|length')" = 0 ]
}

@test "pause/resume/off transitions and no-ops" {
  run _ap pause; [ "$output" = noop ]
  _ap start >/dev/null
  run _ap pause; [ "$output" = paused ]; [ "$(_j .paused_at)" = "$AUTOPILOT_NOW" ]
  run _ap resume; [ "$output" = dispatch ]; [ "$(_ap status)" = on ]; [ "$(_j .paused_at)" = null ]
  run _ap resume; [ "$output" = noop ]
  run _ap off; [[ "$output" == off* ]]; [ "$(_ap status)" = off ]
  run _ap off; [ "$output" = noop ]
}

@test "off: reports the dispatch clone for removal and clears it" {
  _ap start >/dev/null
  jq '.dispatch_clone_path = "/tmp/autopilot-clone-x"' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/t" && mv "$BATS_TEST_TMPDIR/t" "$AUTOPILOT_STATE_FILE"
  run _ap off; [ "$output" = "off /tmp/autopilot-clone-x" ]
  [ "$(_j .dispatch_clone_path)" = null ]
}

@test "delay: progress 60s, idle from config (default 45 min), capped 1h" {
  _ap start >/dev/null
  run _ap delay progress; [ "$output" = 60 ]
  run _ap delay idle; [ "$output" = 2700 ]
  printf '%s' '{"idle_retry_minutes": 30}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap delay idle; [ "$output" = 1800 ]
  run _ap delay capped; [ "$output" = 3600 ]
}

@test "delay: stuck ladder 5,10,20,30,30 minutes" {
  _ap start >/dev/null
  local want=(300 600 1200 1800 1800) i
  for i in 0 1 2 3 4; do
    _ap record stuck 0 T1 "ci red" >/dev/null
    run _ap delay stuck; [ "$output" = "${want[$i]}" ]
  done
}

@test "record progress: counts merges, resets stuck, sets last_task" {
  _ap start >/dev/null
  _ap record stuck 0 T1 "x" >/dev/null
  run _ap record progress 2 T2; [ "$output" = none ]
  [ "$(_j .merged_count)" = 2 ]; [ "$(_j .stuck_count)" = 0 ]; [ "$(_j .last_outcome)" = progress ]
  [ "$(_j .merges_today)" = 2 ]; [ "$(_j .cycles_today)" = 2 ]
}

@test "idle: notice once, silent on retries, 'resumed' when work returns" {
  _ap start >/dev/null
  run _ap record idle; [ "$output" = idle ]
  run _ap record idle; [ "$output" = none ]
  run _ap record idle; [ "$output" = none ]
  run _ap record progress 1 T3; [ "$output" = resumed ]
  run _ap record idle; [ "$output" = idle ]
}

@test "stuck: notice once when stuck_count reaches 3" {
  _ap start >/dev/null
  run _ap record stuck 0 T1 r; [ "$output" = none ]
  run _ap record stuck 0 T1 r; [ "$output" = none ]
  run _ap record stuck 0 T1 r; [ "$output" = stuck ]
  run _ap record stuck 0 T1 r; [ "$output" = none ]
}

@test "record: ignored unless on; bad outcome rejected" {
  run _ap record idle; [ "$output" = none ]
  _ap start >/dev/null
  run _ap record bogus; [ "$status" -ne 0 ]
}

@test "cap: defaults 24 cycles / 12 merges, from config, rolls at midnight" {
  _ap start >/dev/null
  run _ap cap; [ "$output" = ok ]
  printf '%s' '{"daily_cycle_cap": 2, "daily_merge_cap": 9}' > "$AUTOPILOT_CONFIG_FILE"
  _ap record progress 1 T1 >/dev/null
  run _ap cap; [ "$output" = ok ]
  _ap record progress 0 T2 >/dev/null
  run _ap cap; [ "$output" = capped:cycles ]
  run _ap record capped; [ "$output" = capped ]
  run _ap record capped; [ "$output" = none ]
  [ "$(_j .cycles_today)" = 2 ]
  AUTOPILOT_TODAY=2026-10-29 run _ap cap; [ "$output" = ok ]
  [ "$(_j .day)" = 2026-10-29 ]
}

@test "cap: merge cap" {
  _ap start >/dev/null
  printf '%s' '{"daily_merge_cap": 1}' > "$AUTOPILOT_CONFIG_FILE"
  _ap record progress 1 T1 >/dev/null
  run _ap cap; [ "$output" = capped:merges ]
}

@test "cap: invalid config values fall back to defaults" {
  _ap start >/dev/null
  printf '%s' '{"daily_cycle_cap": "lots", "daily_merge_cap": 0}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap cap; [ "$output" = ok ]
  printf '{not json' > "$AUTOPILOT_CONFIG_FILE"
  run _ap cap; [ "$output" = ok ]
}

@test "eligible: status-line markers that need a human are refused" {
  local t="$BATS_TEST_TMPDIR/t.md"
  printf -- '---\nstatus: Open\nestimation: 1\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
  printf -- '---\nstatus: In Progress — SUPERVISED (needs VPN)\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -ne 0 ]
  printf -- '---\nstatus: Blocked by T20260101-000001\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -ne 0 ]
  printf -- '---\nstatus: Open\n---\n# T\nSUPERVISED in the body is not a status marker\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
  run _ap eligible "$BATS_TEST_TMPDIR/missing.md"; [ "$status" -ne 0 ]
}

@test "notify: unset Slack env vars fall back to the state file, exit 0, no error output" {
  _ap start >/dev/null
  run _ap notify idle "nothing drivable"
  [ "$status" -eq 0 ]; [ "$output" = fallback ]
  [ "$(_j '.notices[-1].kind')" = idle ]; [ "$(_j '.notices[-1].via')" = fallback ]
}

@test "notify: uses the Slack sender when it reports success" {
  _ap start >/dev/null
  printf '#!/usr/bin/env bash\necho "Message sent successfully"\n' > "$BATS_TEST_TMPDIR/ok-send.sh"
  AUTOPILOT_SLACK_SEND="$BATS_TEST_TMPDIR/ok-send.sh" run _ap notify idle "x"
  [ "$status" -eq 0 ]; [ "$output" = slack ]
  [ "$(_j '.notices[-1].via')" = slack ]
}

@test "notify: a failing sender and a missing state file never error" {
  printf '#!/usr/bin/env bash\necho boom >&2; exit 1\n' > "$BATS_TEST_TMPDIR/bad-send.sh"
  AUTOPILOT_SLACK_SEND="$BATS_TEST_TMPDIR/bad-send.sh" run _ap notify stuck "x"
  [ "$status" -eq 0 ]; [ "$output" = fallback ]
}

@test "real slack-send.sh with the env vars unset degrades to the fallback" {
  _ap start >/dev/null
  unset AUTOPILOT_SLACK_SEND
  HOME="$BATS_TEST_TMPDIR/nohome" run _ap notify idle "x"
  [ "$status" -eq 0 ]; [ "$output" = fallback ]
}

@test "busy off clears the mark even after off, so a later on is not refused" {
  _ap start >/dev/null; _ap busy on; _ap off >/dev/null
  _ap busy off
  [ "$(_j .busy_since)" = null ]
  run _ap start; [ "$output" = started ]
}

@test "report: a fresh run with no next_wake_at is not flagged overdue" {
  _ap start >/dev/null
  AUTOPILOT_NOW="2026-10-28T10:20:00Z" run _ap report
  [[ "$output" != *overdue* ]]
}

@test "skip --kind: stores the category, validates it, backfills on a repeat, stays backward compatible" {
  _ap start >/dev/null
  run _ap skip T1 "waits on HashData" --kind external; [ "$output" = attention ]
  [ "$(_j '.needs_attention[0].kind')" = external ]
  [ "$(_j '.needs_attention[0].reason')" = "waits on HashData" ]
  run _ap skip T2 --kind=decision; [ "$output" = attention ]
  [ "$(_j '.needs_attention[1].kind')" = decision ]; [ "$(_j '.needs_attention[1].reason')" = "needs attention" ]
  _ap skip T3 "plain" >/dev/null
  [ "$(_j '.needs_attention[2]|has("kind")')" = false ]
  run _ap skip T3 "plain" --kind blocked; [ "$output" = none ]
  [ "$(_j '.needs_attention[2].kind')" = blocked ]
  run _ap skip T4 "x" --kind nonsense; [ "$status" -eq 2 ]
  [ "$(_j '.skip_ids|index("T4")')" = null ]
}

# --- classify / attention / clone-path / done / final-report -----------------

_report() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/report.txt"; }

@test "classify: one merged task is progress with its id" {
  _report 'MERGED: T9111111 (fix-thing) — PR #12'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]; [ "$output" = "progress 1 T9111111 -" ]
}

@test "classify: several merged tasks count, runs suffix is ignored, stdin works" {
  run bash -c "printf '%s\n' 'MERGED: T9111111 (a) — PR #1; runs: https://x/1' 'MERGED: T9222222 (b) — PR #2' | bash '$SCRIPT' classify -"
  [ "$status" -eq 0 ]; [ "$output" = "progress 2 T9222222 -" ]
}

@test "classify: merged plus stuck is stuck, keeping the merged count and the stuck task" {
  _report 'MERGED: T9111111 (a) — PR #1' \
    'STUCK: CI red on a flaky test — last task T9222222 (b); runs: https://x/9'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]; [ "$output" = "stuck 1 T9222222 CI red on a flaky test" ]
}

@test "classify: stuck without a task id falls back to the last merged id, else dash" {
  _report 'STUCK: dispatch died'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "stuck 0 - dispatch died" ]
}

@test "classify: waiting with nothing merged is waiting; merged beats waiting" {
  _report 'WAITING: PR #44 needs a formal approval'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "waiting 0 - PR #44 needs a formal approval" ]
  _report 'MERGED: T9111111 (a) — PR #1' 'WAITING: PR #44 needs approval'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "progress 1 T9111111 -" ]
}

@test "classify: waiting beats stuck when nothing merged (Phase 4 order)" {
  _report 'STUCK: x — last task T9111111 (a)' 'WAITING: PR #44 approval'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "${output%% *}" = waiting ]
}

@test "classify: a lone NEEDS-ATTENTION is idle, and attention lists it" {
  _report 'NEEDS-ATTENTION: T9333333 — needs an owner decision on scope'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]; [ "${output%% *}" = idle ]
  run _ap attention "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "$(printf 'T9333333\tneeds an owner decision on scope')" ]
}

@test "classify: NEEDS-ATTENTION next to a merge is still progress" {
  _report 'MERGED: T9111111 (a) — PR #1' 'NEEDS-ATTENTION: T9333333 — external party'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "progress 1 T9111111 -" ]
}

@test "classify: tolerates bullets, bold and CRLF; ignores placeholder template lines" {
  printf -- '- **MERGED:** T9111111 (a) — PR #1\r\nSTUCK: <short reason>\r\n' > "$BATS_TEST_TMPDIR/report.txt"
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]; [ "$output" = "progress 1 T9111111 -" ]
}

@test "classify: garbage, empty and a missing file are unparseable (exit 2, stuck line)" {
  _report 'I did some things and all went well.'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 2 ]; [ "$output" = "stuck 0 - dispatch failed or report unparseable" ]
  : > "$BATS_TEST_TMPDIR/report.txt"
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"; [ "$status" -eq 2 ]
  run _ap classify "$BATS_TEST_TMPDIR/none.txt"; [ "$status" -eq 2 ]
  run _ap classify; [ "$status" -eq 2 ]
}

@test "classify: output feeds record directly" {
  _ap start >/dev/null
  _report 'MERGED: T9111111 (a) — PR #1'
  read -r o m id reason < <(_ap classify "$BATS_TEST_TMPDIR/report.txt")
  run _ap record "$o" "$m" "$id" "$reason"
  [ "$status" -eq 0 ]; [ "$(_j .merged_count)" = 1 ]; [ "$(_j .last_task)" = T9111111 ]
}

@test "clone-path: deterministic, repo-named, 8-hex hash that matches the original shasum recipe" {
  run _ap clone-path /work/some-repo
  [ "$status" -eq 0 ]
  want="/tmp/autopilot-clone-some-repo-$(printf '%s' /work/some-repo | shasum -a 256 | cut -c1-8)"
  [ "$output" = "$want" ]
  [[ "$output" =~ ^/tmp/autopilot-clone-some-repo-[0-9a-f]{8}$ ]]
  run _ap clone-path /other/some-repo
  [ "$output" != "$want" ]
}

@test "clone-path: defaults to the current git toplevel" {
  d="$(make_fixture_repo "$BATS_TEST_TMPDIR/cp-repo")"
  cd "$d"
  top="$(git rev-parse --show-toplevel)"
  run _ap clone-path
  [ "$output" = "$(_ap clone-path "$top")" ]
}

_final_fixture() {
  d="$(make_fixture_repo "$BATS_TEST_TMPDIR/fr-repo")"
  cd "$d"
  _ap start >/dev/null
  _ap_set_start
}
_ap_set_start() { jq '.started_at = "2026-10-28T08:00:00Z"' "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"; }

@test "final-report: empty run prints the template with the two empty bullets" {
  _final_fixture
  AUTOPILOT_NOW="2026-10-28T09:05:00Z" run _ap final-report
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Autopilot run: 1h 5m elapsed — stopped: user-requested" ]
  [[ "$output" == *$'Done:\n- No tasks merged this run\n'* ]]
  [[ "$output" == *$'Needs your attention:\n- Nothing outstanding'* ]]
}

@test "final-report: under an hour prints minutes only; --stopped overrides the reason" {
  _final_fixture
  AUTOPILOT_NOW="2026-10-28T08:42:00Z" run _ap final-report --stopped capped
  [ "${lines[0]}" = "Autopilot run: 42m elapsed — stopped: capped" ]
}

@test "final-report: Done lists journal files added since started_at with slug and the one PR ref" {
  _final_fixture
  cat > dev/JOURNAL/2026-10-28-T9111111-fix-widget.md <<'MD'
---
status: Done
---

# T9111111: Fix widget

Shipped in PR #77.
MD
  cat > dev/JOURNAL/2026-10-28-T9222222-two-prs.md <<'MD'
---
status: Done
---

Design PR #5, implementation PR #6.
MD
  cat > dev/JOURNAL/2026-10-28-T9333333-fm-pr.md <<'MD'
---
status: Done
pr: https://github.com/o/r/pull/91
---

Mentions PR #3 in passing.
MD
  git add -A; GIT_AUTHOR_DATE="2026-10-28T08:30:00Z" GIT_COMMITTER_DATE="2026-10-28T08:30:00Z" git commit -q -m journal
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap done
  [ "$status" -eq 0 ]
  [[ "$output" == *"- Merged T9111111 (fix-widget) — PR #77"* ]]
  [[ "$output" == *"- Merged T9222222 (two-prs)"* ]]
  [[ "$output" != *"two-prs) — PR"* ]]
  [[ "$output" == *"- Merged T9333333 (fm-pr) — PR #91"* ]]
}

@test "final-report: journal files from before started_at are not Done" {
  _final_fixture
  echo x > dev/JOURNAL/2026-10-01-T9444444-old.md
  git add -A; GIT_AUTHOR_DATE="2026-10-01T08:30:00Z" GIT_COMMITTER_DATE="2026-10-01T08:30:00Z" git commit -q -m old
  run _ap done
  [ "$output" = "- No tasks merged this run" ]
}

@test "final-report: needs_attention and a stuck last task are listed once each, with slugs" {
  _final_fixture
  cat > dev/TODO/T9555555-big-decision.md <<'MD'
---
status: Open
---
MD
  cat > dev/TODO/T9666666-flaky.md <<'MD'
---
status: Open
---
MD
  _ap skip T9555555 "needs an owner decision" >/dev/null
  _ap record stuck 0 T9666666 "CI keeps failing" >/dev/null
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap final-report
  [[ "$output" == *"- T9555555 (big-decision) — needs an owner decision"* ]]
  [[ "$output" == *"- Stuck: T9666666 (flaky) — CI keeps failing"* ]]
  [[ "$output" != *"Nothing outstanding"* ]]
  # a stuck task already in needs_attention is not listed twice
  _ap skip T9666666 "also blocked" >/dev/null
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap final-report
  [ "$(grep -c 'T9666666' <<<"$output")" = 1 ]
}

@test "final-report: an id with no task file stays bare; missing state file is exit 2" {
  _final_fixture
  _ap skip T9777777 "gone" >/dev/null
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap final-report
  [[ "$output" == *"- T9777777 — gone"* ]]
  rm "$AUTOPILOT_STATE_FILE"
  run _ap final-report; [ "$status" -eq 2 ]
}
