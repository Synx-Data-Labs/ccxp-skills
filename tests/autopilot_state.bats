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

@test "done: only dated top-level journal .md files count (not digests, archive/ or other files)" {
  _final_fixture
  mkdir -p dev/JOURNAL/archive/2026-09
  echo x > dev/JOURNAL/2026-10-digest.md
  echo x > dev/JOURNAL/archive/2026-09/2026-09-01-T20000101-000001-old.md
  echo x > dev/JOURNAL/2026-10-28-notes.txt
  echo x > dev/JOURNAL/2026-10-28-real-task.md
  git add -A; GIT_AUTHOR_DATE="2026-10-28T08:30:00Z" GIT_COMMITTER_DATE="2026-10-28T08:30:00Z" git commit -q -m j
  run _ap done
  [ "$output" = "- Merged (2026-10-28-real-task)" ] || [ "$output" = "- Merged (real-task)" ]
}

@test "classify: a MERGED line without a task id still counts; the unfilled template does not" {
  _report 'MERGED: fix-thing — PR #5'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "progress 1 - -" ]
  _report 'MERGED: T<id> (<slug>) — PR #<n>'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"; [ "$status" -eq 2 ]
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

@test "busy on <id> stores current_task; busy off clears it" {
  _ap start >/dev/null
  _ap busy on T20261028-151063
  [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .current_task)" = T20261028-151063 ]
  _ap busy off
  [ "$(_j .busy_since)" = null ]; [ "$(_j .current_task)" = null ]
}

@test "busy on without an id marks busy and clears a stale current_task" {
  _ap start >/dev/null
  _ap busy on T20261028-151063
  _ap busy on
  [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .current_task)" = null ]
}

@test "busy on with an invalid id is ignored: still busy, no error, no task" {
  _ap start >/dev/null
  local bad
  for bad in "" nope T123 "T20261028-15106" "T20261028-1510633" 't20261028-151063' 'T20261028-151063;x'; do
    run _ap busy on "$bad"; [ "$status" -eq 0 ]
    [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .current_task)" = null ]
    _ap busy off
  done
}

@test "record clears current_task along with busy_since" {
  _ap start >/dev/null; _ap busy on T20261028-151063
  _ap record progress 1 T20261028-151063 >/dev/null
  [ "$(_j .busy_since)" = null ]; [ "$(_j .current_task)" = null ]
}

@test "a state file without current_task (5.4.0) still works: busy on/off, record, start" {
  _ap start >/dev/null
  jq 'del(.current_task)' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$AUTOPILOT_STATE_FILE"
  run _ap busy off; [ "$status" -eq 0 ]
  _ap busy on; [ "$(_j .current_task)" = null ]
  _ap busy on T20261028-151063; [ "$(_j .current_task)" = T20261028-151063 ]
  run _ap record idle 0; [ "$status" -eq 0 ]
  [ "$(_j .current_task)" = null ]
}

@test "off keeps current_task with busy_since; a later on carries both until the cycle reports" {
  _ap start >/dev/null; _ap busy on T20261028-151063; _ap off >/dev/null
  run _ap start; [ "$output" = busy ]
  [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .current_task)" = T20261028-151063 ]
  _ap busy off
  [ "$(_j .current_task)" = null ]
}

@test "start writes a fresh state with current_task null" {
  _ap start >/dev/null
  [ "$(_j .current_task)" = null ]
}

@test "unskip: removes a listed id from skip_ids and needs_attention, noop when absent" {
  _ap start >/dev/null
  _ap skip T1 "a" --kind decision >/dev/null; _ap skip T2 "b" >/dev/null
  run _ap unskip T1; [ "$status" -eq 0 ]; [ "$output" = "unskipped T1" ]
  [ "$(_j '.skip_ids|index("T1")')" = null ]; [ "$(_j '.skip_ids|index("T2")')" = 0 ]
  [ "$(_j '.needs_attention|length')" = 1 ]; [ "$(_j '.needs_attention[0].id')" = T2 ]
  run _ap unskip T1; [ "$output" = noop ]
  run _ap unskip T99; [ "$output" = noop ]
  run _ap unskip; [ "$status" -eq 2 ]
  # skipping again after an unskip notifies again
  run _ap skip T1 "again"; [ "$output" = attention ]
}

@test "unskip --all: clears every skip, noop when there are none" {
  _ap start >/dev/null
  run _ap unskip --all; [ "$output" = noop ]
  _ap skip T1 "a" >/dev/null; _ap skip T2 "b" >/dev/null
  run _ap unskip --all; [ "$output" = "unskipped all" ]
  [ "$(_j '.skip_ids|length')" = 0 ]; [ "$(_j '.needs_attention|length')" = 0 ]
}

@test "unskip: a state file without the fields, or no file, is a noop and stays valid" {
  run _ap unskip T1; [ "$output" = noop ]
  printf '{"schema":2,"status":"on"}' > "$AUTOPILOT_STATE_FILE"
  run _ap unskip T1; [ "$status" -eq 0 ]; [ "$output" = noop ]
  run _ap unskip --all; [ "$output" = noop ]
  [ "$(_j .status)" = on ]
}

@test "eligible: task size, estimation and umbrella wording never refuse a task" {
  t="$BATS_TEST_TMPDIR/big.md"
  printf -- '---\nestimation: 8\nstatus: Open\ndescription: umbrella epic for many things\n---\n# T1: Umbrella epic\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
}

@test "SKILL.md: big tasks are split, not skipped, and unskip is documented" {
  run grep -n 'Big tasks' "$REPO_ROOT/autopilot/SKILL.md"; [ "$status" -eq 0 ]
  run grep -n -- 'blocks: T<original-id>' "$REPO_ROOT/autopilot/SKILL.md"; [ "$status" -eq 0 ]
  run grep -n 'autopilot-state.sh unskip' "$REPO_ROOT/autopilot/SKILL.md"; [ "$status" -eq 0 ]
  run grep -n -i 'umbrella task)' "$REPO_ROOT/autopilot/SKILL.md"; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# History log + stats: rolling 24 h, lifetime average, off/start persistence
# ---------------------------------------------------------------------------

_hist() { printf '%s' "$AUTOPILOT_STATE_FILE" | sed 's#[^/]*$#.autopilot-history.jsonl#'; }
# $1 ts, $2 outcome, $3 merged: append one history line by hand
_hline() { printf '{"ts":"%s","outcome":"%s","merged":%s,"task":""}\n' "$1" "$2" "$3" >> "$(_hist)"; }
_stat() { _ap stats --json | jq -r "$1"; }

@test "record appends one {ts,outcome,merged,task} line to the history log" {
  _ap start >/dev/null
  _ap record progress 2 T20261028-111111 "free text must not be logged" >/dev/null
  _ap record idle >/dev/null
  [ "$(wc -l < "$(_hist)" | tr -d ' ')" = 2 ]
  run jq -c . "$(_hist)"
  [ "${lines[0]}" = '{"ts":"2026-10-28T10:00:00Z","outcome":"progress","merged":2,"task":"T20261028-111111"}' ]
  [ "${lines[1]}" = '{"ts":"2026-10-28T10:00:00Z","outcome":"idle","merged":0,"task":""}' ]
  ! grep -q "free text" "$(_hist)"
}

@test "record logs a non-task id as an empty task and nothing when autopilot is off" {
  _ap start >/dev/null
  _ap record stuck 0 "not an id" >/dev/null
  [ "$(jq -r .task "$(_hist)")" = "" ]
  _ap off >/dev/null
  _ap record progress 1 >/dev/null
  [ "$(wc -l < "$(_hist)" | tr -d ' ')" = 1 ]
}

@test "record survives a history write failure (unwritable path) and still counts" {
  _ap start >/dev/null
  export AUTOPILOT_HISTORY_FILE="$BATS_TEST_TMPDIR/blocker/sub/h.jsonl"
  : > "$BATS_TEST_TMPDIR/blocker"   # a file where a directory is needed
  run _ap record progress 1 T20261028-111111 x
  [ "$status" -eq 0 ]
  [ "$(_j .merged_count)" = 1 ]
  [ "$(_j .lifetime_merged)" = 1 ]
}

@test "stats: missing state and history is all zero, never an error" {
  run _ap stats --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.has_history, .merged_24h, .lifetime_cycles, .lifetime_days, .avg_merged_24h, .trend' <<<"$output" | paste -sd' ')" = "false 0 0 1 0 flat" ]
  run _ap stats
  [ "${lines[0]}" = "24h: no history logged yet" ]
}

@test "stats: window boundary is exclusive at exactly 24 h and includes 23h59m59s" {
  _hline 2026-10-27T10:00:00Z progress 5   # exactly 24 h old: out
  _hline 2026-10-27T10:00:01Z progress 2   # 23:59:59 old: in
  _hline 2026-10-28T09:00:00Z progress 1
  [ "$(_stat .merged_24h)" = 3 ]
  [ "$(_stat .cycles_24h)" = 2 ]
  [ "$(_stat .has_history)" = true ]
}

@test "stats: counts stuck, waiting, idle in the window; capped is not a cycle" {
  _hline 2026-10-28T01:00:00Z stuck 0
  _hline 2026-10-28T02:00:00Z waiting 0
  _hline 2026-10-28T03:00:00Z idle 0
  _hline 2026-10-28T04:00:00Z idle 0
  _hline 2026-10-28T05:00:00Z capped 0
  _hline 2026-10-28T06:00:00Z progress 3
  run _ap stats --json
  [ "$(jq -r '[.cycles_24h,.stuck_24h,.waiting_24h,.idle_24h,.merged_24h]|join(",")' <<<"$output")" = "5,1,1,2,3" ]
}

@test "stats: malformed history lines are skipped" {
  printf 'not json\n[1]\n{"ts":"bad","outcome":"progress","merged":9}\n' > "$(_hist)"
  _hline 2026-10-28T09:00:00Z progress 1
  [ "$(_stat .merged_24h)" = 1 ]
}

@test "stats: lifetime average uses the state baseline and started_at span" {
  # 8 days, 40 cycles, 16 merged before the log existed; today's log adds 2 merged/2 cycles
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":40,"merged_count":16}' > "$AUTOPILOT_STATE_FILE"
  _hline 2026-10-28T09:00:00Z progress 0
  [ "$(_stat .lifetime_merged)" = 16 ]
  [ "$(_stat .lifetime_cycles)" = 40 ]
  [ "$(_stat .lifetime_days)" = 8 ]
  [ "$(_stat .avg_merged_24h)" = 2 ]
  [ "$(_stat .avg_cycles_24h)" = 5 ]
}

@test "stats: lifetime days are fractional above one day and floored at one day" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-27T04:00:00Z","cycle_count":10,"merged_count":6}' > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .lifetime_days)" = 1.25 ]   # 30 h
  [ "$(_stat .avg_merged_24h)" = 4.8 ]
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-28T09:00:00Z","cycle_count":2,"merged_count":3}' > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .lifetime_days)" = 1 ]
  [ "$(_stat .avg_merged_24h)" = 3 ]
}

@test "stats: an older first log line stretches the span; log totals win when larger" {
  _hline 2026-10-18T10:00:00Z progress 4
  _hline 2026-10-28T09:00:00Z progress 4
  [ "$(_stat .lifetime_days)" = 10 ]
  [ "$(_stat .lifetime_merged)" = 8 ]
  [ "$(_stat .lifetime_cycles)" = 2 ]
}

@test "stats: trend compares merged_24h with the one-decimal average" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-18T10:00:00Z","cycle_count":10,"merged_count":20}' > "$AUTOPILOT_STATE_FILE"   # avg 2.0/day
  _hline 2026-10-28T09:00:00Z progress 3
  [ "$(_stat .trend)" = up ]
  : > "$(_hist)"; _hline 2026-10-28T09:00:00Z progress 2
  [ "$(_stat .trend)" = flat ]
  : > "$(_hist)"; _hline 2026-10-28T09:00:00Z progress 1
  [ "$(_stat .trend)" = down ]
  run _ap stats
  [[ "${lines[0]}" == "24h: 1 merged/1 cycles (0 stuck, 0 waiting, 0 idle) ▼" ]]
  [[ "${lines[1]}" == "lifetime: 20 merged/10 cycles over 10 days · average 2 merged/1 cycles per 24h" ]]
}

@test "stats: no history log and no cycle in the window is an exact zero (approx false)" {
  # last cycle two days ago, calendar-day counters of that day: nothing can be inside the window
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":35,"merged_count":17,"last_cycle_at":"2026-10-26T10:00:00Z","cycles_today":19,"merges_today":5}' > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .has_history)" = false ]
  [ "$(_stat .approx)" = false ]
  [ "$(_stat .merged_24h)" = 0 ]
  [ "$(_stat .cycles_24h)" = 0 ]
  [ "$(_stat .trend)" = down ]   # 0 against a non-zero average
}

@test "stats: no history log but a cycle inside the window uses the calendar-day counters as an estimate (approx true)" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":35,"merged_count":17,"last_cycle_at":"2026-10-28T08:00:00Z","cycles_today":4,"merges_today":3}' > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .has_history)" = false ]
  [ "$(_stat .approx)" = true ]
  [ "$(_stat .merged_24h)" = 3 ]
  [ "$(_stat .cycles_24h)" = 4 ]
}

@test "stats: a log that starts inside the window is incomplete, so the larger of log and counters wins (approx true)" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":35,"merged_count":17,"last_cycle_at":"2026-10-28T09:00:00Z","cycles_today":4,"merges_today":3}' > "$AUTOPILOT_STATE_FILE"
  _hline 2026-10-28T09:00:00Z progress 1
  [ "$(_stat .approx)" = true ]
  [ "$(_stat .merged_24h)" = 3 ]
  # logged work larger than the counters is kept
  : > "$(_hist)"; _hline 2026-10-28T08:00:00Z progress 2; _hline 2026-10-28T09:00:00Z progress 2
  [ "$(_stat .merged_24h)" = 4 ]
}

@test "stats: a log reaching back over the whole window is exact (approx false) whatever the counters say" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":35,"merged_count":17,"last_cycle_at":"2026-10-28T09:00:00Z","cycles_today":9,"merges_today":9}' > "$AUTOPILOT_STATE_FILE"
  _hline 2026-10-20T10:00:00Z progress 1
  _hline 2026-10-28T09:00:00Z progress 2
  [ "$(_stat .approx)" = false ]
  [ "$(_stat .merged_24h)" = 2 ]
}

@test "stats: approx is off when last_cycle_at is missing, null, malformed or in the future, and exact at the 24 h boundary" {
  local base='"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":35,"merged_count":17,"cycles_today":4,"merges_today":3'
  printf '{%s}' "$base" > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .approx)" = false ]; [ "$(_stat .merged_24h)" = 0 ]
  printf '{%s,"last_cycle_at":null}' "$base" > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .approx)" = false ]
  printf '{%s,"last_cycle_at":"garbage"}' "$base" > "$AUTOPILOT_STATE_FILE"
  [ "$(_stat .approx)" = false ]
  printf '{%s,"last_cycle_at":"2026-10-29T10:00:00Z"}' "$base" > "$AUTOPILOT_STATE_FILE"   # in the future
  [ "$(_stat .approx)" = false ]
  printf '{%s,"last_cycle_at":"2026-10-27T10:00:00Z"}' "$base" > "$AUTOPILOT_STATE_FILE"   # exactly 24 h old: out
  [ "$(_stat .approx)" = false ]
  printf '{%s,"last_cycle_at":"2026-10-27T10:00:01Z"}' "$base" > "$AUTOPILOT_STATE_FILE"   # 23:59:59 old: in
  [ "$(_stat .approx)" = true ]
}

@test "stats: an estimate is spelled out in the text form and the trend stays one-decimal flat/up/down" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-18T10:00:00Z","cycle_count":10,"merged_count":20,"last_cycle_at":"2026-10-28T08:00:00Z","cycles_today":2,"merges_today":2}' > "$AUTOPILOT_STATE_FILE"   # avg 2.0/day
  [ "$(_stat .approx)" = true ]
  [ "$(_stat .trend)" = flat ]
  run _ap stats
  [[ "${lines[0]}" == "24h: ~2 merged/~2 cycles (estimate"* ]]
}

@test "stats: bad argument is a usage error" {
  run _ap stats --bogus
  [ "$status" -eq 2 ]
}

@test "lifetime baseline: a pre-existing state is carried through record, off and start" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-20T10:00:00Z","cycle_count":40,"merged_count":16,"stuck_count":0,"waiting_count":0,"cycles_today":0,"merges_today":0,"day":"2026-10-28","notified":false,"idle_notified":false,"stuck_notified":false,"waiting_notified":false,"capped_notified":false}' > "$AUTOPILOT_STATE_FILE"
  _ap record progress 2 T20261028-111111 >/dev/null
  [ "$(_j .lifetime_cycles)" = 41 ]
  [ "$(_j .lifetime_merged)" = 18 ]
  [ "$(_j .lifetime_started_at)" = 2026-10-20T10:00:00Z ]
  _ap off >/dev/null
  AUTOPILOT_NOW="2026-10-29T10:00:00Z" run _ap start
  [ "$output" = started ]
  [ "$(_j .started_at)" = 2026-10-29T10:00:00Z ]
  [ "$(_j .cycle_count)" = 0 ]
  [ "$(_j .lifetime_cycles)" = 41 ]
  [ "$(_j .lifetime_merged)" = 18 ]
  [ "$(_j .lifetime_started_at)" = 2026-10-20T10:00:00Z ]
  _ap record progress 1 >/dev/null
  [ "$(_j .lifetime_merged)" = 19 ]
  [ "$(wc -l < "$(_hist)" | tr -d ' ')" = 2 ]   # the log was not reset either
}

@test "lifetime baseline: off then start on a pre-upgrade state seeds it from the old counters" {
  printf '%s' '{"schema":2,"status":"off","started_at":"2026-10-20T10:00:00Z","cycle_count":40,"merged_count":16}' > "$AUTOPILOT_STATE_FILE"
  _ap start >/dev/null
  [ "$(_j .lifetime_cycles)" = 40 ]
  [ "$(_j .lifetime_merged)" = 16 ]
  [ "$(_j .lifetime_started_at)" = 2026-10-20T10:00:00Z ]
}

@test "lifetime baseline: a first-ever start begins now and a legacy file does not poison it" {
  _ap start >/dev/null
  [ "$(_j .lifetime_started_at)" = "$AUTOPILOT_NOW" ]
  [ "$(_j .lifetime_cycles)" = 0 ]
  _ap off >/dev/null
  printf '%s' '{"status":"running","end_time":"x"}' > "$AUTOPILOT_STATE_FILE"
  _ap start >/dev/null
  [ "$(_j .lifetime_started_at)" = "$AUTOPILOT_NOW" ]
  [ "$(_j .lifetime_merged)" = 0 ]
}

@test "lifetime baseline: a capped tick is logged but adds no lifetime cycle" {
  _ap start >/dev/null
  _ap record capped >/dev/null
  [ "$(_j .lifetime_cycles)" = 0 ]
  [ "$(_stat .cycles_24h)" = 0 ]
}

@test "SKILL.md documents the stats subcommand and the history file" {
  grep -q 'autopilot-state.sh stats' "$REPO_ROOT/autopilot/SKILL.md"
  grep -q '.autopilot-history.jsonl' "$REPO_ROOT/autopilot/SKILL.md"
}

@test "stats: a future-dated history line is not in the 24h window" {
  _hline 2026-10-28T10:00:01Z progress 4
  _hline 2026-10-28T09:00:00Z progress 1
  [ "$(_stat .merged_24h)" = 1 ]
}

@test "lifetime baseline: a corrupt started_at is not carried, counters still are" {
  printf '%s' '{"schema":2,"status":"off","started_at":"yesterday","cycle_count":7,"merged_count":3}' > "$AUTOPILOT_STATE_FILE"
  _ap start >/dev/null
  [ "$(_j .lifetime_started_at)" = "$AUTOPILOT_NOW" ]
  [ "$(_j .lifetime_cycles)" = 7 ]
  [ "$(_j .lifetime_merged)" = 3 ]
}

@test "usage text lists stats and stops before the code" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stats [--json]"* ]]
  [[ "$output" != *"set -euo pipefail"* ]]
}
