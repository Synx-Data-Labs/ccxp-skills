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
