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
  [[ "$output" == *"on | off | pause | resume | status | config"* ]]
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
  AUTOPILOT_NOW="2026-10-28T10:00:40Z" run _ap start; [ "$output" = dispatch ]   # within the 59 s tolerance
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

@test "waiting: notice once when it repeats, cleared by progress" {
  _ap start >/dev/null
  run _ap record waiting 0 T1; [ "$output" = none ]
  run _ap record waiting 0 T1; [ "$output" = waiting ]
  run _ap record waiting 0 T1; [ "$output" = none ]
  _ap record progress 1 T1 >/dev/null
  [ "$(_j .waiting_notified)" = false ]
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

@test "delay: progress 60s, idle from config (default 32 min), capped 1h" {
  _ap start >/dev/null
  run _ap delay progress; [ "$output" = 60 ]
  run _ap delay idle; [ "$output" = 1920 ]
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

@test "cap: defaults 64 cycles / 64 merges, from config, rolls at midnight" {
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

@test "eligible: a Blocked by status is refused, SUPERVISED prose is not (d174)" {
  local t="$BATS_TEST_TMPDIR/t.md"
  printf -- '---\nstatus: Open\nestimation: 1\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
  printf -- '---\nstatus: In Progress — SUPERVISED (needs VPN)\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
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

@test "classify: a lone NEEDS-ATTENTION is bottomed with 0 merged, and attention lists it" {
  _report 'NEEDS-ATTENTION: T9333333 — needs an owner decision on scope'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$status" -eq 0 ]; [ "${output%% *}" = bottomed ]; [[ "$output" == "bottomed 0 - "* ]]
  run _ap attention "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "$(printf 'T9333333\tneeds an owner decision on scope')" ]
}

@test "classify: ADVANCED alone is progress with 0 merged; ADVANCED next to STUCK is stuck" {
  _report 'ADVANCED: T9111111 — design PR #12 merged'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = "progress 0 T9111111 -" ]
  _report 'ADVANCED: T9111111 — design PR #12 merged' 'STUCK: CI red — last task T9111111 (a)'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "${output%% *}" = stuck ]
  _report 'ADVANCED: T9111111 — design PR #12 merged' 'WAITING: approval on #12'
  run _ap classify "$BATS_TEST_TMPDIR/report.txt"
  [ "${output%% *}" = waiting ]
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
_ap_set_start() { jq '.started_at = "2026-10-28T08:00:00Z" | .run_started_at = "2026-10-28T08:00:00Z"' "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"; }

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

@test "eligible: task size, estimation and umbrella wording never refuse a task" {
  t="$BATS_TEST_TMPDIR/big.md"
  printf -- '---\nestimation: 8\nstatus: Open\ndescription: umbrella epic for many things\n---\n# T1: Umbrella epic\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
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
  [[ "$output" == *"final-report"* ]]
  [[ "$output" != *"set -euo pipefail"* ]]
}

# ---------------------------------------------------------------------------
# T20261102-261809: no skip list; "needs a human" marker in the task files
# ---------------------------------------------------------------------------

_nh_repo() {
  export AUTOPILOT_REPO_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$AUTOPILOT_REPO_ROOT/dev/TODO" "$AUTOPILOT_REPO_ROOT/dev/JOURNAL"
}
# $1 id, $2 status, $3 slug (default slug)
_nh_task() {
  printf -- '---\nstatus: %s\nestimation: 1\n---\n# %s\n' "$2" "$1" > "$AUTOPILOT_REPO_ROOT/dev/TODO/$1-${3:-slug}.md"
  printf -- '- [%s](%s-%s.md): t\n' "$1" "$1" "${3:-slug}" >> "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
}

@test "off clears next_wake_at but keeps busy_since until the cycle reports" {
  _ap start >/dev/null
  _ap record progress 0 T1 >/dev/null; _ap busy on
  _ap off >/dev/null
  [ "$(_j .busy_since)" = "$AUTOPILOT_NOW" ]; [ "$(_j .next_wake_at)" = null ]
}

@test "retired commands: skip, unskip, marked, attention-list, visit, advance, parked and parked-list are usage errors" {
  _ap start >/dev/null
  local c
  for c in skip unskip marked attention-list visit advance parked parked-list; do run _ap "$c" T1; [ "$status" -eq 2 ]; done
}

@test "eligible: the old human-only words are no gate any more; only Blocked by is refused (d174)" {
  local t="$BATS_TEST_TMPDIR/t.md" s
  for s in 'In Progress — SUPERVISED (needs VPN)' 'Open — BLOCKED upstream' 'Review — needs manual QA' 'Open — sign-off pending'; do
    printf -- '---\nstatus: %s\n---\n# T\n' "$s" > "$t"
    run _ap eligible "$t"; [ "$status" -eq 0 ]
  done
  printf -- '---\nstatus: Blocked by T20260101-000001\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -ne 0 ]
  printf -- '---\nstatus: Open — needs a human [decision]: pick one\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
  printf -- '---\nstatus: Open — UNBLOCKED now\n---\n# T\n' > "$t"
  run _ap eligible "$t"; [ "$status" -eq 0 ]
}

# --- visits: bottom after a no-progress visit, park at max_visits (T20261102-296642) ---

_hlines() { cat "$(_hist)" 2>/dev/null || true; }

@test "done: a merge from before a pause stays in the Done list (the pause shifts started_at, not run_started_at)" {
  _final_fixture
  printf -- '---\nstatus: Done\n---\n\nPR #77.\n' > dev/JOURNAL/2026-10-28-T9111111-fix-widget.md
  git add -A; GIT_AUTHOR_DATE="2026-10-28T09:00:00Z" GIT_COMMITTER_DATE="2026-10-28T09:00:00Z" git commit -q -m journal
  AUTOPILOT_NOW="2026-10-28T10:00:00Z" _ap pause >/dev/null
  AUTOPILOT_NOW="2026-10-28T14:00:00Z" _ap resume >/dev/null
  [ "$(_j .started_at)" = "2026-10-28T12:00:00Z" ]; [ "$(_j .run_started_at)" = "2026-10-28T08:00:00Z" ]
  AUTOPILOT_NOW="2026-10-28T15:00:00Z" run _ap done
  [[ "$output" == *"- Merged T9111111 (fix-widget) — PR #77"* ]]
}

# --- plan: which tasks a cycle advanced and which it stalled on ---

_plan() { _report "$@"; _ap plan "$BATS_TEST_TMPDIR/report.txt"; }

@test "plan: MERGED and ADVANCED are advanced; NEEDS-ATTENTION and STUCK last task are stalled, each with its source" {
  run _plan 'MERGED: T20260101-000001 (a) — PR #1' 'ADVANCED: T20260101-000002 — design PR #2 merged' \
    'NEEDS-ATTENTION: T20260101-000003 — needs an owner decision' 'STUCK: CI red — last task T20260101-000004 (d)'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = $'T20260101-000001\tadvanced\t(a) — PR #1\tmerged' ]
  [ "${lines[1]}" = $'T20260101-000002\tadvanced\tdesign PR #2 merged\tadvanced' ]
  [ "${lines[2]}" = $'T20260101-000003\tstalled\tneeds an owner decision\tattention' ]
  [ "${lines[3]}" = $'T20260101-000004\tstalled\tCI red\tstuck' ]
}

@test "plan: advanced wins when the same task is also stalled; repeats collapse" {
  run _plan 'STUCK: split but CI red — last task T20260101-000001 (a)' 'ADVANCED: T20260101-000001 — split into 3 sub-tasks' \
    'NEEDS-ATTENTION: T20260101-000002 — x' 'NEEDS-ATTENTION: T20260101-000002 — y'
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'T20260101-000001\tadvanced\tsplit into 3 sub-tasks\tadvanced' ]
  [ "${lines[1]}" = $'T20260101-000002\tstalled\tx\tattention' ]
}

@test "plan: WAITING, a STUCK without a task id, template lines and garbage name nothing" {
  run _plan 'WAITING: approval on #3' 'STUCK: dispatch failed' 'MERGED: <id>' 'garbage' 'ADVANCED: no id here'
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run _ap plan "$BATS_TEST_TMPDIR/missing.txt"; [ "$status" -eq 2 ]
  run _ap plan; [ "$status" -eq 2 ]
}

@test "plan --fallback: a STUCK without a task id names the task recorded before dispatch; a bad fallback is ignored" {
  _report 'STUCK: CI red, forgot the id'
  run _ap plan "$BATS_TEST_TMPDIR/report.txt" --fallback T20260101-000009
  [ "$output" = $'T20260101-000009\tstalled\tCI red, forgot the id\tstuck' ]
  run _ap plan "$BATS_TEST_TMPDIR/report.txt" --fallback nonsense
  [ -z "$output" ]
  # a STUCK that does name its task keeps that task, and an unparseable report never uses the fallback
  _report 'STUCK: x — last task T20260101-000004 (d)'
  run _ap plan "$BATS_TEST_TMPDIR/report.txt" --fallback T20260101-000009
  [ "$output" = $'T20260101-000004\tstalled\tx\tstuck' ]
  _report 'garbage'
  run _ap plan "$BATS_TEST_TMPDIR/report.txt" --fallback T20260101-000009
  [ -z "$output" ]
}

@test "plan: --fallback without a value ends (no hang); a bare id with no reason keeps its whole id" {
  _report 'STUCK: CI red'
  bash "$SCRIPT" plan "$BATS_TEST_TMPDIR/report.txt" --fallback > "$BATS_TEST_TMPDIR/pl.out" 2>&1 & local pid=$!
  ( sleep 5; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local dog=$!
  local rc=0; wait "$pid" || rc=$?
  kill "$dog" 2>/dev/null || true
  [ "$rc" -eq 0 ]; [ ! -s "$BATS_TEST_TMPDIR/pl.out" ]
  run _plan 'NEEDS-ATTENTION: T20260101-000044' 'ADVANCED: T20260101-000045'
  [ "${lines[0]}" = $'T20260101-000044\tstalled\tneeds attention\tattention' ]
  [ "${lines[1]}" = $'T20260101-000045\tadvanced\tadvanced\tadvanced' ]
  run _ap attention "$BATS_TEST_TMPDIR/report.txt"
  _report 'NEEDS-ATTENTION: T20260101-000044'
  run _ap attention "$BATS_TEST_TMPDIR/report.txt"
  [ "$output" = $'T20260101-000044\tneeds attention' ]
}

@test "plan: tolerates bullets, bold and a runs suffix; strips tabs from reasons" {
  run _plan $'- **NEEDS-ATTENTION: T20260101-000003 — a\tb**; runs: https://x/1'
  [ "$output" = $'T20260101-000003\tstalled\ta b\tattention' ]
}

@test "record bottomed: a cycle that wakes in 60 s and leaves the stuck/waiting counters and notices alone" {
  _ap start >/dev/null
  _ap record stuck 0 T20260101-000001 "ci" >/dev/null; _ap record stuck 0 T20260101-000001 "ci" >/dev/null
  run _ap record bottomed 0 T20260101-000002; [ "$output" = none ]
  [ "$(_j .stuck_count)" = 2 ]; [ "$(_j .last_outcome)" = bottomed ]; [ "$(_j .cycle_count)" = 3 ]
  [ "$(_j .next_wake_at)" = "2026-10-28T10:01:00Z" ]
  run _ap delay bottomed; [ "$output" = 60 ]
  # after an idle notice it does not fire "resumed" (it is not progress)
  _ap record idle >/dev/null
  run _ap record bottomed 0 T20260101-000003; [ "$output" = none ]
  [ "$(_j .idle_notified)" = true ]
  run _ap record progress 1 T20260101-000004; [ "$output" = resumed ]
}

@test "top: the id /drive will pick, skipping Blocked by tasks; a SUPERVISED word is no gate" {
  _nh_repo
  echo "# TODO Queue" > "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ -z "$output" ]
  _nh_task T20260101-000001 "Blocked by T20260101-000009" a
  _nh_task T20260101-000002 "Open — SUPERVISED (needs VPN)" b
  _nh_task T20260101-000003 "Open" c
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000002 ]
}

# --- reports list the revisited and parked tasks ---

@test "final-report: missing state file is exit 2" {
  _final_fixture
  rm "$AUTOPILOT_STATE_FILE"
  run _ap final-report; [ "$status" -eq 2 ]
}

@test "pickable: pick, drift and none; a Blocked by status never counts as pickable, SUPERVISED prose does" {
  _nh_repo
  echo "# TODO Queue" > "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
  _nh_task T20260101-000001 "Blocked by T20260101-000009" a
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = none ]
  _nh_task T20260101-000002 "Open" b
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = pick ]
  # nothing pickable but a task file is missing from the queue: a sweep would fix it
  sed -i.bak '/000002/d' "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = drift ]
}

@test "no script writes a marker into a task file: needs-human.sh and its parser are gone" {
  [ ! -e "$REPO_ROOT/todo/scripts/needs-human.sh" ]
  run grep -rn 'todo-needs-human-kind\|skip-needs-human' "$REPO_ROOT/todo" "$REPO_ROOT/autopilot" "$REPO_ROOT/drive" "$REPO_ROOT/hud" "$REPO_ROOT/tests"
  # only this test and the todo-next usage-error test may name the retired flag
  [ "$(grep -v 'autopilot_state.bats\|todo-next.bats' <<<"$output" | grep -c .)" = 0 ]
}

@test "SKILL.md: a stalled cycle creates a hold (no bottom PR, no housekeeping agent), no marker or skip list" {
  local s="$REPO_ROOT/autopilot/SKILL.md"
  run grep -n 'Big tasks' "$s"; [ "$status" -eq 0 ]
  run grep -n -- 'blocks: T<original-id>' "$s"; [ "$status" -eq 0 ]
  run grep -n -i 'umbrella task)' "$s"; [ "$status" -ne 0 ]
  run grep -n -- '/drive --auto-selected' "$s"; [ "$status" -eq 0 ]
  run grep -n 'autopilot-state.sh pickable' "$s"; [ "$status" -eq 0 ]
  run grep -n 'autopilot-state.sh hold-report' "$s"; [ "$status" -eq 0 ]
  run grep -n 'autopilot-state.sh holds-check' "$s"; [ "$status" -eq 0 ]
  run grep -n 'autopilot-state.sh prune' "$s"; [ "$status" -eq 0 ]
  run grep -n 'No `/bottom`, no `queue.md` edit, no housekeeping agent' "$s"; [ "$status" -eq 0 ]
  run grep -n -E 'autopilot-state.sh visit|park refused|BOTTOMED:|HOUSEKEEPING-FAILED' "$s"; [ "$status" -ne 0 ]
  run grep -n -E 'max_visits|parked-list|park after|no-progress visit' "$s"; [ "$status" -ne 0 ]   # retired in T20261124-115593
  run grep -n -E 'needs-human\.sh|autopilot-state\.sh (marked|attention-list|skip|unskip)|skip_ids|--skip-needs-human' "$s"; [ "$status" -ne 0 ]
}

# --- config-show / config-set / config-reset ---

@test "config-show: no file shows defaults and the path" {
  run _ap config-show
  [ "$status" -eq 0 ]
  [[ "$output" == *"daily_cycle_cap"*"64"*"default"* ]]
  [[ "$output" == *"idle_retry_minutes"*"32"*"default"* ]]
  [[ "$output" == *"config file: $AUTOPILOT_CONFIG_FILE (absent"* ]]
}

@test "config-show: overrides are marked and --json is valid" {
  printf '%s' '{"daily_cycle_cap": 100}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show
  [[ "$output" == *"daily_cycle_cap"*"100"*"override"* ]]
  [[ "$output" == *"idle_retry_minutes"*"32"*"default"* ]]
  run _ap config-show --json
  [ "$(printf '%s' "$output" | jq -r '.settings.daily_cycle_cap.value')" = 100 ]
  [ "$(printf '%s' "$output" | jq -r '.settings.daily_cycle_cap.source')" = override ]
  [ "$(printf '%s' "$output" | jq -r '.settings.idle_retry_minutes.source')" = default ]
  [ "$(printf '%s' "$output" | jq -r '.file')" = "$AUTOPILOT_CONFIG_FILE" ]
}

@test "config-show: an invalid override is ignored (shown as default)" {
  printf '%s' '{"idle_retry_minutes": "abc", "daily_merge_cap": 0}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show
  [[ "$output" == *"idle_retry_minutes"*"32"*"default"* ]]
  [[ "$output" == *"daily_merge_cap"*"64"*"default"* ]]
}

@test "config-set: creates the file with mode 600 and takes effect at the next cap check" {
  run _ap config-set daily_cycle_cap 2
  [ "$status" -eq 0 ]
  [ "$(jq -r '.daily_cycle_cap' "$AUTOPILOT_CONFIG_FILE")" = 2 ]
  [ "$(stat -c %a "$AUTOPILOT_CONFIG_FILE" 2>/dev/null || stat -f %Lp "$AUTOPILOT_CONFIG_FILE")" = 600 ]
  _ap start >/dev/null
  _ap record progress 0 >/dev/null; _ap record progress 0 >/dev/null
  run _ap cap; [ "$output" = "capped:cycles" ]
  _ap config-set daily_cycle_cap 24 >/dev/null
  run _ap cap; [ "$output" = ok ]
}

@test "config-set: preserves other and unknown keys, leaves no temp file" {
  printf '%s' '{"daily_cycle_cap": 5, "future_key": "x"}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-set idle_retry_minutes 30
  [ "$status" -eq 0 ]
  [ "$(jq -r '.daily_cycle_cap' "$AUTOPILOT_CONFIG_FILE")" = 5 ]
  [ "$(jq -r '.future_key' "$AUTOPILOT_CONFIG_FILE")" = x ]
  [ "$(jq -r '.idle_retry_minutes' "$AUTOPILOT_CONFIG_FILE")" = 30 ]
  run _ap delay idle; [ "$output" = 1800 ]
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep 'config.json.tmp')" ]
}

@test "config-set: rejects bad keys and values without touching the file" {
  printf '%s' '{"max_visits": 5}' > "$AUTOPILOT_CONFIG_FILE"
  before=$(cat "$AUTOPILOT_CONFIG_FILE")
  for args in "bogus 5" "max_visits 3" "daily_cycle_cap 0" "daily_cycle_cap -1" "daily_cycle_cap abc" "daily_cycle_cap 1.5" "reserved_slots 9" \
              "daily_cycle_cap 1001" "daily_merge_cap 0" "idle_retry_minutes 29" "idle_retry_minutes 61" "daily_cycle_cap 007" "daily_cycle_cap"; do
    run _ap config-set $args
    [ "$status" -eq 2 ] || { echo "accepted: $args"; return 1; }
    [[ "$output" == *"config:"* || "$output" == *"config-set"* ]]
  done
  [ "$(cat "$AUTOPILOT_CONFIG_FILE")" = "$before" ]
}

@test "config-set: accepts the range bounds" {
  run _ap config-set daily_cycle_cap 1000; [ "$status" -eq 0 ]
  run _ap config-set max_dop 16; [ "$status" -eq 0 ]
  run _ap config-set idle_retry_minutes 60; [ "$status" -eq 0 ]
  run _ap config-set idle_retry_minutes 30; [ "$status" -eq 0 ]
}

@test "config-set: refuses to overwrite a file that is not a JSON object" {
  printf '{not json' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-set daily_cycle_cap 4
  [ "$status" -eq 2 ]
  [ "$(cat "$AUTOPILOT_CONFIG_FILE")" = "{not json" ]
}

@test "config-set: never touches the state file" {
  _ap start >/dev/null
  before=$(cat "$AUTOPILOT_STATE_FILE")
  _ap config-set daily_merge_cap 50 >/dev/null
  [ "$(cat "$AUTOPILOT_STATE_FILE")" = "$before" ]
}

@test "config-reset: one key keeps the rest, no key drops all five but keeps unknown keys" {
  printf '%s' '{"idle_retry_minutes": 31, "daily_cycle_cap": 9, "future_key": 1}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-reset idle_retry_minutes
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("idle_retry_minutes")' "$AUTOPILOT_CONFIG_FILE")" = false ]
  [ "$(jq -r '.daily_cycle_cap' "$AUTOPILOT_CONFIG_FILE")" = 9 ]
  run _ap config-reset
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' "$AUTOPILOT_CONFIG_FILE")" = '{"future_key":1}' ]
  run _ap config-show
  [[ "$output" == *"daily_cycle_cap"*"64"*"default"* ]]
}

@test "config-reset: no file is a noop; unknown key is refused" {
  run _ap config-reset; [ "$status" -eq 0 ]; [[ "$output" == noop* ]]
  [ ! -e "$AUTOPILOT_CONFIG_FILE" ]
  run _ap config-reset bogus; [ "$status" -eq 2 ]
}

@test "SKILL.md documents the config argument and its no-loop-effect rule" {
  run grep -n 'config set <key> <value>' "$REPO_ROOT/autopilot/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -n 'never starts, stops, pauses or dispatches' "$REPO_ROOT/autopilot/SKILL.md"
  [ "$status" -eq 0 ]
}

# --- max_dop: parallel cycles (T20261106-971582) ------------------------------

_ap_on() { _ap start >/dev/null; }

@test "max_dop: default 3, range 3-16, set/show/reset like the other keys (2 slots are reserved)" {
  run _ap config-show; [[ "$output" == *"max_dop"*"3"*"default"*"3 (3-16)"* ]]
  run _ap config-set max_dop 8; [ "$status" -eq 0 ]
  run _ap config-show --json; [ "$(jq -r .settings.max_dop.value <<<"$output")" = 8 ]
  [ "$(jq -r .settings.max_dop.source <<<"$output")" = override ]
  run _ap config-set max_dop 17; [ "$status" -eq 2 ]
  run _ap config-set max_dop abc; [ "$status" -eq 2 ]
  run _ap config-reset max_dop; [ "$status" -eq 0 ]
  run _ap config-show --json; [ "$(jq -r .settings.max_dop.value <<<"$output")" = 3 ]
  run _ap config-set max_dop 16; [ "$status" -eq 0 ]
  run _ap config-set max_dop 3; [ "$status" -eq 0 ]
}

@test "max_dop: 0, 1 and 2 are refused with the reserved-slots message and nothing is written" {
  for n in 0 1 2; do
    run _ap config-set max_dop "$n"
    [ "$status" -eq 2 ]
    [[ "$output" == *"2 slots are always reserved"* ]]
  done
  [ ! -e "$AUTOPILOT_CONFIG_FILE" ]
  printf '{"max_visits":7}' > "$AUTOPILOT_CONFIG_FILE"
  before=$(cat "$AUTOPILOT_CONFIG_FILE")
  run _ap config-set max_dop 2; [ "$status" -eq 2 ]
  [ "$(cat "$AUTOPILOT_CONFIG_FILE")" = "$before" ]
}

@test "max_dop clamp-on-read: a file value below 3 reads as 3, notice in config-show and report, file never rewritten" {
  printf '{"max_dop":1}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show --json
  [ "$(jq -r .settings.max_dop.value <<<"$output")" = 3 ]
  [[ "$(jq -r '.notices[0]' <<<"$output")" == *"max_dop 1"*"using 3"* ]]
  run _ap config-show; [[ "$output" == *"notice: max_dop 1"*"using 3"* ]]
  _ap_on
  run _ap report; [[ "$output" == *"notice: max_dop 1"* ]]
  [ "$(cat "$AUTOPILOT_CONFIG_FILE")" = '{"max_dop":1}' ]
  printf '{"max_dop":2}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show; [[ "$output" == *"notice: max_dop 2"* ]]
  printf '{"max_dop":4}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show; [[ "$output" != *"notice:"* ]]
}

@test "reserved_slots: default 2, range 0-8, set/show/reset, 0 is a valid override" {
  run _ap config-show; [[ "$output" == *"reserved_slots"*"2"*"default"*"2 (0-8)"* ]]
  _ap config-set max_dop 12 >/dev/null
  run _ap config-set reserved_slots 8; [ "$status" -eq 0 ]
  run _ap config-set reserved_slots 9; [ "$status" -eq 2 ]
  run _ap config-set reserved_slots -1; [ "$status" -eq 2 ]
  run _ap config-set reserved_slots abc; [ "$status" -eq 2 ]
  run _ap config-set reserved_slots 0; [ "$status" -eq 0 ]
  run _ap config-show --json
  [ "$(jq -r .settings.reserved_slots.value <<<"$output")" = 0 ]
  [ "$(jq -r .settings.reserved_slots.source <<<"$output")" = override ]
  run _ap config-reset reserved_slots; [ "$status" -eq 0 ]
  run _ap config-show --json; [ "$(jq -r .settings.reserved_slots.value <<<"$output")" = 2 ]
  [ "$(jq -r .settings.reserved_slots.source <<<"$output")" = default ]
}

@test "reserved_slots: at most max_dop minus 1, both directions, and capped on read with a notice" {
  run _ap config-set reserved_slots 3; [ "$status" -eq 2 ]    # max_dop 3 leaves 2 at most
  [[ "$output" == *"at most 2"* ]]
  run _ap config-set reserved_slots 2; [ "$status" -eq 0 ]
  _ap config-set max_dop 6 >/dev/null
  _ap config-set reserved_slots 5 >/dev/null
  run _ap config-set max_dop 5; [ "$status" -eq 2 ]            # would leave 5 reserved of 5
  [[ "$output" == *"lower reserved_slots first"* ]]
  [ "$(jq -r .max_dop "$AUTOPILOT_CONFIG_FILE")" = 6 ]
  printf '{"max_dop":4,"reserved_slots":7}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show --json
  [ "$(jq -r .settings.reserved_slots.value <<<"$output")" = 3 ]
  [[ "$(jq -r '.notices[0]' <<<"$output")" == *"reserved_slots 7"*"using 3"* ]]
  run _ap routine-free; [ "$output" = 1 ]
}

@test "routine limit: slots --summary, routine-free and report show max_dop minus reserved_slots" {
  _ap_on
  run _ap routine-free; [ "$output" = 1 ]
  run _ap slots --summary; [ "$output" = "routine 1 of 3, reserved 2, busy 0, routine-free 1, free 3" ]
  _ap config-set max_dop 10 >/dev/null
  run _ap slots --summary; [ "$output" = "routine 8 of 10, reserved 2, busy 0, routine-free 8, free 10" ]
  _ap busy on T20261106-000001 --slot 1
  _ap busy on T20261106-000002 --slot 2
  run _ap routine-free; [ "$output" = 6 ]
  run _ap report; [[ "$output" == *"slots: 2 of 10 running (routine 8 of 10, reserved 2)"* ]]
  _ap config-set reserved_slots 0 >/dev/null
  run _ap routine-free; [ "$output" = 8 ]
  run _ap slots --bogus; [ "$status" -eq 2 ]
  run _ap slots; [[ "$output" == *"T20261106-000001"* ]]
}

@test "routine limit: routine-free never goes below 0; an urgent slot does not use up routine-free" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  run _ap routine-free; [ "$output" = 0 ]
  _ap busy on T20261106-000002 --urgent --slot 2
  _ap busy on --slot 3 T20261106-000003 --urgent
  run _ap routine-free; [ "$output" = 0 ]
  run _ap slots --summary; [ "$output" = "routine 1 of 3, reserved 2, busy 3, routine-free 0, free 0" ]
  _ap busy off --slot 1
  run _ap routine-free; [ "$output" = 1 ]
  [ "$(_j '.slots["2"].urgent')" = true ]
  [ "$(_j '.slots["2"].task')" = T20261106-000002 ]
  [ "$(_j '.slots["3"].task')" = T20261106-000003 ]
}

@test "routine-free is capped by the slots physically free (all slots urgent)" {
  _ap_on
  _ap busy on T20261106-000001 --urgent --slot 1
  _ap busy on T20261106-000002 --urgent --slot 2
  _ap busy on T20261106-000003 --urgent --slot 3
  run _ap routine-free; [ "$output" = 0 ]
  run _ap slots --summary; [ "$output" = "routine 1 of 3, reserved 2, busy 3, routine-free 0, free 0" ]
}

@test "slots: busy on/off per slot; bare off clears all; the legacy mirror follows the oldest slot" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  AUTOPILOT_NOW="2026-10-28T10:05:00Z" _ap busy on T20261106-000002 --slot 2
  run _ap slots
  [ "$(wc -l <<<"$output" | tr -d ' ')" = 2 ]
  [[ "$output" == *"1"*"T20261106-000001"* ]]
  [ "$(_j .busy_since)" = "2026-10-28T10:00:00Z" ]
  [ "$(_j .current_task)" = T20261106-000001 ]
  _ap busy off --slot 1
  [ "$(_j '.slots | keys | join(",")')" = 2 ]
  [ "$(_j .current_task)" = T20261106-000002 ]
  _ap busy off
  [ "$(_j '.slots | length')" = 0 ]
  [ "$(_j .busy_since)" = null ]
}

@test "slots: a task already in another slot is refused (exit 3); re-marking the same slot is allowed" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  run _ap busy on T20261106-000001 --slot 2; [ "$status" -eq 3 ]
  run _ap busy on T20261106-000003 --slot 1; [ "$status" -eq 0 ]
  run _ap busy on T20261106-000003 --slot 17; [ "$status" -eq 2 ]
}

@test "slots: a pre-slots state file (busy_since only) reads as slot 1 busy and migrates on write" {
  _ap_on
  jq 'del(.slots) | .busy_since = "2026-10-28T09:30:00Z" | .current_task = "T20261106-000001"' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/t" && mv "$BATS_TEST_TMPDIR/t" "$AUTOPILOT_STATE_FILE"
  run _ap slots; [[ "$output" == "1"$'\t'"T20261106-000001"$'\t'"2026-10-28T09:30:00Z" ]]
  run _ap start; [ "$output" = already-on ]
  _ap busy on T20261106-000002 --slot 2
  [ "$(_j '.slots | keys | join(",")')" = "1,2" ]
  _ap record progress 0 T20261106-000001 "" --slot 1 >/dev/null
  [ "$(_j '.slots | keys | join(",")')" = 2 ]
}

@test "slots: a mark older than 3 h is stale and drops out of the in-flight set" {
  _ap_on
  AUTOPILOT_NOW="2026-10-28T05:00:00Z" _ap busy on T20261106-000001 --slot 2
  run _ap slots; [ -z "$output" ]
}

@test "record --slot: clears only its slot; counters stay global" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  _ap busy on T20261106-000002 --slot 2
  _ap record progress 1 T20261106-000002 "" --slot 2 >/dev/null
  [ "$(_j '.slots | keys | join(",")')" = 1 ]
  [ "$(_j .cycle_count)" = 1 ]
  [ "$(_j .merged_count)" = 1 ]
  [ "$(_j .current_task)" = T20261106-000001 ]
  _ap record progress 0 T20261106-000001 "" >/dev/null
  [ "$(_j '.slots | length')" = 0 ]
  [ "$(_j .cycle_count)" = 2 ]
}

@test "start/resume: due with a routine slot free, already-on when the routine limit is reached (default: one routine slot)" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  run _ap start; [ "$output" = already-on ]
  _ap config-set max_dop 4 >/dev/null
  run _ap start; [ "$output" = dispatch ]       # routine limit 2
  _ap busy on T20261106-000002 --slot 2
  run _ap start; [ "$output" = already-on ]
  _ap busy on T20261106-000003 --urgent --slot 3   # urgent work leaves the routine count alone
  run _ap start; [ "$output" = already-on ]
  _ap pause >/dev/null
  run _ap resume; [ "$output" = busy ]
  _ap busy off --slot 2
  _ap pause >/dev/null
  run _ap resume; [ "$output" = dispatch ]
}

@test "start (off then on) carries the busy slots over" {
  _ap_on
  _ap busy on T20261106-000001 --slot 1
  _ap busy on T20261106-000002 --slot 2
  _ap off >/dev/null
  run _ap start; [ "$output" = busy ]
  [ "$(_j '.slots | keys | join(",")')" = "1,2" ]
}

@test "cap: cycles in flight count against daily_cycle_cap" {
  _ap_on
  _ap config-set daily_cycle_cap 2 >/dev/null
  _ap busy on T20261106-000001 --slot 1
  run _ap cap; [ "$output" = ok ]
  _ap busy on T20261106-000002 --slot 2
  run _ap cap; [ "$output" = "capped:cycles" ]
}

@test "clone-path: slot 1 is unchanged, other slots get a distinct -sN path" {
  run _ap clone-path /work/repo; p1="$output"
  run _ap clone-path /work/repo --slot 1; [ "$output" = "$p1" ]
  run _ap clone-path /work/repo --slot 3; [ "$output" = "${p1}-s3" ]
  run _ap clone-path /work/repo --slot 0; [ "$status" -eq 2 ]
}

@test "set-clone / off: the extra slot clones are printed after the slot-1 line" {
  _ap_on
  _ap set-clone 1 /tmp/autopilot-clone-x
  _ap set-clone 2 /tmp/autopilot-clone-x-s2
  run _ap off
  [ "${lines[0]}" = "off /tmp/autopilot-clone-x" ]
  [ "${lines[1]}" = "clone /tmp/autopilot-clone-x-s2" ]
  [ "$(_j '.dispatch_clone_paths | length')" = 0 ]
}

@test "top --nth and in-flight: the next slot gets a different task, Blocked-by-in-flight is skipped" {
  _nh_repo
  echo "# TODO Queue" > "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
  _nh_task T20260101-000001 "Open" a
  _nh_task T20260101-000002 "Blocked by T20260101-000001" b
  _nh_task T20260101-000003 "Open" c
  _nh_task T20260101-000004 "Open" d
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000001 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 2; [ "$output" = T20260101-000003 ]  # the Blocked-by task is gated and skipped
  _ap_on
  _ap busy on T20260101-000001 --slot 1
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000003 ]
  _ap busy on T20260101-000003 --slot 2
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000004 ]
  _ap busy on T20260101-000004 --slot 3
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ -z "$output" ]
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = none ]
}

@test "guard: ok when memory and load are fine; holds with the reason otherwise; fails closed" {
  AUTOPILOT_GUARD_MEM_FREE_PCT=60 AUTOPILOT_GUARD_LOAD=2.0 AUTOPILOT_GUARD_NCPU=8 run _ap guard
  [ "$status" -eq 0 ]; [ "$output" = ok ]
  AUTOPILOT_GUARD_MEM_FREE_PCT=12 AUTOPILOT_GUARD_LOAD=2.0 AUTOPILOT_GUARD_NCPU=8 run _ap guard
  [ "$status" -eq 1 ]; [ "$output" = "hold free memory 12% is under 20%" ]
  AUTOPILOT_GUARD_MEM_FREE_PCT=60 AUTOPILOT_GUARD_LOAD=14 AUTOPILOT_GUARD_NCPU=8 run _ap guard
  [ "$status" -eq 1 ]; [[ "$output" == "hold load 1.75 per CPU is over 1.5" ]]
  AUTOPILOT_GUARD_MEM_FREE_PCT=oops AUTOPILOT_GUARD_LOAD=1 AUTOPILOT_GUARD_NCPU=8 run _ap guard
  [ "$status" -eq 1 ]; [[ "$output" == "hold free memory unreadable" ]]
  AUTOPILOT_GUARD_MEM_MIN_PCT=5 AUTOPILOT_GUARD_MEM_FREE_PCT=12 AUTOPILOT_GUARD_LOAD=1 AUTOPILOT_GUARD_NCPU=8 run _ap guard
  [ "$output" = ok ]
}

@test "guard: the real probe on this machine prints ok or hold <reason> (never errors)" {
  run _ap guard
  [[ "$output" == ok || "$output" == hold\ * ]]
}

@test "hold: sets the wake time and last_hold without counting a cycle; refuses bad seconds" {
  _ap_on
  run _ap hold 300 "free memory 12% is under 20%"; [ "$output" = 300 ]
  [ "$(_j .next_wake_at)" = "2026-10-28T10:05:00Z" ]
  [ "$(_j .last_hold.reason)" = "free memory 12% is under 20%" ]
  [ "$(_j .cycle_count)" = 0 ]
  run _ap hold 0 x; [ "$status" -eq 2 ]
  run _ap delay held; [ "$output" = 300 ]
}

@test "report: always shows the slots line with the routine limit (default max_dop 3, reserved 2)" {
  _ap_on
  run _ap report; [[ "$output" == *"slots: 0 of 3 running (routine 1 of 3, reserved 2)"* ]]
  _ap config-set max_dop 4 >/dev/null
  _ap busy on T20261106-000001 --slot 1
  run _ap report; [[ "$output" == *"slots: 1 of 4 running (routine 2 of 4, reserved 2)"* ]]; [[ "$output" == *"slot 1: T20261106-000001"* ]]
}

@test "state lock: a stale lock directory is broken; two writers both land" {
  _ap_on
  mkdir "$AUTOPILOT_STATE_FILE.lock"; touch -t 202001010000 "$AUTOPILOT_STATE_FILE.lock"
  run _ap busy on T20261106-000001 --slot 1; [ "$status" -eq 0 ]
  ( _ap busy on T20261106-000002 --slot 2 & _ap busy on T20261106-000003 --slot 3 & wait )
  [ "$(_j '.slots | keys | join(",")')" = "1,2,3" ]
}

@test "state lock: a lock seen stale but re-taken by a live writer is not broken (T20261120-258991)" {
  _ap_on
  local shim="$BATS_TEST_TMPDIR/shim" real; real="$(command -v stat)"; mkdir -p "$shim"
  # The first stat A makes reports an ancient mtime (its early look at the stale lock); later calls are real.
  printf '%s\n' '#!/usr/bin/env bash' "echo x >> '$shim/calls'" \
    "if [ \"\$(wc -l < '$shim/calls')\" -eq 1 ]; then echo 1; exit 0; fi" "exec '$real' \"\$@\"" > "$shim/stat"
  chmod +x "$shim/stat"
  # B is a live writer holding the lock now.
  bash -c 'source "$1"; _ap_lock; : > "$2/held"; until [ -e "$2/release" ]; do sleep 0.02; done; _ap_unlock' holder "$SCRIPT" "$BATS_TEST_TMPDIR" 3>&- &
  local bpid=$!
  until [ -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.02; done
  PATH="$shim:$PATH" bash "$SCRIPT" busy on T20261106-000002 --slot 2 3>&- &
  local apid=$! i
  for ((i = 0; i < 500; i++)); do
    kill -0 "$apid" 2>/dev/null || break
    [ "$(cat "$shim/calls" 2>/dev/null | wc -l)" -ge 2 ] && break
    sleep 0.02
  done
  local alive=0 owner=""
  kill -0 "$apid" 2>/dev/null && alive=1
  owner="$(cat "$AUTOPILOT_STATE_FILE.lock" 2>/dev/null || true)"
  : > "$BATS_TEST_TMPDIR/release"
  wait "$apid"; wait "$bpid"
  [ "$(cat "$shim/calls" | wc -l)" -ge 2 ]   # A looked at the age, then re-checked it before deciding
  [ "$alive" = 1 ]
  [ "$owner" = "$bpid" ]
  [ "$(_j '.slots | keys | join(",")')" = "2" ]
  [ ! -e "$AUTOPILOT_STATE_FILE.lock" ]
}

@test "state lock: mutual exclusion does not depend on mkdir being exclusive (uutils mkdir lets several callers win) (T20261120-258991)" {
  _ap_on
  local shim="$BATS_TEST_TMPDIR/shim" realstat; realstat="$(command -v stat)"; mkdir -p "$shim"
  # A mkdir that always succeeds, even when the directory exists; a stat that counts its calls (A looks at the lock's age only after a failed attempt).
  printf '%s\n' '#!/usr/bin/env bash' 'exec /bin/mkdir -p "$@"' > "$shim/mkdir"
  printf '%s\n' '#!/usr/bin/env bash' "echo x >> '$shim/calls'" "exec '$realstat' \"\$@\"" > "$shim/stat"
  chmod +x "$shim/mkdir" "$shim/stat"
  bash -c 'source "$1"; _ap_lock; : > "$2/held"; until [ -e "$2/release" ]; do sleep 0.02; done; _ap_unlock' holder "$SCRIPT" "$BATS_TEST_TMPDIR" 3>&- &
  local bpid=$!
  until [ -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.02; done
  PATH="$shim:$PATH" bash "$SCRIPT" busy on T20261106-000002 --slot 2 3>&- &
  local apid=$! i
  for ((i = 0; i < 500; i++)); do
    kill -0 "$apid" 2>/dev/null || break
    [ "$(cat "$shim/calls" 2>/dev/null | wc -l)" -ge 1 ] && break
    sleep 0.02
  done
  local alive=0; kill -0 "$apid" 2>/dev/null && alive=1
  : > "$BATS_TEST_TMPDIR/release"
  wait "$apid"; wait "$bpid"
  [ "$alive" = 1 ]
  [ "$(_j '.slots | keys | join(",")')" = "2" ]
}

@test "docs: reserved_slots, the routine limit and --urgent are documented (T20261124-182499)" {
  grep -q 'reserved_slots' "$REPO_ROOT/autopilot/SKILL.md"
  grep -q 'reserved_slots' "$REPO_ROOT/autopilot/parallel.md"
  grep -q -- '--urgent' "$REPO_ROOT/autopilot/parallel.md"
  grep -q 'routine-free' "$REPO_ROOT/autopilot/parallel.md"
  grep -q 'reserved_slots' "$REPO_ROOT/README.md"
}

@test "SKILL.md and parallel.md document max_dop (default 3), the guard and per-slot dispatch" {
  grep -q 'max_dop' "$REPO_ROOT/autopilot/SKILL.md"
  grep -q 'autopilot/parallel.md' "$REPO_ROOT/autopilot/SKILL.md"
  grep -q 'autopilot-state.sh guard' "$REPO_ROOT/autopilot/parallel.md"
  grep -q -- '--slot' "$REPO_ROOT/autopilot/parallel.md"
  grep -q -- '--flags autopilot' "$REPO_ROOT/autopilot/parallel.md"
  grep -q '/drive T<id> --auto-selected' "$REPO_ROOT/autopilot/parallel.md"
}

@test "overdue: seconds late beyond the grace; 0 when due, within the grace, paused, busy, off or without a wake time" {
  _ap start >/dev/null
  _j_set() { jq "$1" "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"; }
  run _ap overdue; [ "$output" = 0 ] # no wake time yet
  _j_set '.next_wake_at = "2026-10-28T09:59:00Z"'
  run _ap overdue; [ "$output" = 0 ] # 60 s late: inside the 600 s grace
  _j_set '.next_wake_at = "2026-10-28T09:50:00Z"'
  run _ap overdue; [ "$output" = 0 ] # exactly the grace
  _j_set '.next_wake_at = "2026-10-28T09:49:59Z"'
  run _ap overdue; [ "$output" = 601 ]
  _j_set '.next_wake_at = "2026-10-26T18:00:00Z"'
  run _ap overdue; [ "$output" = 144000 ] # 2026-10-26T18:00 to 2026-10-28T10:00 = 40 h of total lateness
  run _ap overdue 7200; [ "$output" = 144000 ]
  run _ap overdue 99999999; [ "$output" = 0 ]
  run _ap overdue x; [ "$status" -eq 2 ]
  _ap pause >/dev/null
  run _ap overdue; [ "$output" = 0 ] # paused
  _ap resume >/dev/null
  _j_set '.next_wake_at = "2026-10-26T18:00:00Z"'
  _ap busy on >/dev/null
  run _ap overdue; [ "$output" = 0 ] # a cycle is running: its stored wake time is stale by design
  _ap busy off >/dev/null
  _ap off >/dev/null
  run _ap overdue; [ "$output" = 0 ]
}

@test "wake: a stale next_wake_at reads overdue until the armed wake is recorded; touches nothing else (T20261123-418520)" {
  _ap_on
  _ap config-set max_dop 3 >/dev/null
  jq '.next_wake_at = "2026-10-28T06:27:00Z"' "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"
  run _ap overdue; [ "$output" = 12780 ] # the loop idles, a ScheduleWakeup is armed but nothing recorded: reads stalled
  _ap record progress 1 T20261028-111111 "x" >/dev/null
  jq '.next_wake_at = "2026-10-28T06:27:00Z"' "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"
  local before; before=$(jq -S 'del(.next_wake_at)' "$AUTOPILOT_STATE_FILE")
  run _ap wake 1800 "idle, slots busy"; [ "$status" -eq 0 ]; [ "$output" = 1800 ]
  [ "$(_j .next_wake_at)" = "2026-10-28T10:30:00Z" ]
  run _ap overdue; [ "$output" = 0 ]
  [ "$(jq -S 'del(.next_wake_at)' "$AUTOPILOT_STATE_FILE")" = "$before" ] # counters, slots, last_hold untouched
  [ "$(_j .last_hold)" = null ]
  run _ap wake 0; [ "$status" -eq 2 ]
  run _ap wake 86401; [ "$status" -eq 2 ]
  run _ap wake x; [ "$status" -eq 2 ]
  run _ap wake 08; [ "$output" = 8 ]
}

@test "wake: no state write unless the loop is on" {
  _ap_on
  _ap pause >/dev/null
  jq '.next_wake_at = null' "$AUTOPILOT_STATE_FILE" > "$AUTOPILOT_STATE_FILE.t" && mv "$AUTOPILOT_STATE_FILE.t" "$AUTOPILOT_STATE_FILE"
  run _ap wake 600; [ "$output" = 600 ]
  [ "$(_j .next_wake_at)" = null ]
}

@test "wake: SKILL.md and parallel.md pair every ScheduleWakeup with a state write" {
  run grep -c 'wake <s' "$REPO_ROOT/autopilot/SKILL.md"; [ "$output" -ge 2 ]
  run grep -c 'autopilot-state.sh wake' "$REPO_ROOT/autopilot/parallel.md"; [ "$output" -ge 1 ]
  run grep -ni 'never arm a wake without recording it' "$REPO_ROOT/autopilot/SKILL.md"; [ "$status" -eq 0 ]
}

@test "start: a wake fired early (minute rounding) dispatches within the 59 s tolerance, a typed on long before does not (T20261124-243982)" {
  _ap start >/dev/null
  AUTOPILOT_NOW="2026-10-28T10:00:00Z" _ap wake 170 >/dev/null     # next_wake_at 10:02:50Z
  AUTOPILOT_NOW="2026-10-28T10:02:50Z" run _ap start; [ "$output" = dispatch ]   # exactly due
  AUTOPILOT_NOW="2026-10-28T10:02:40Z" run _ap start; [ "$output" = dispatch ]   # 10 s early
  AUTOPILOT_NOW="2026-10-28T10:02:00Z" run _ap start; [ "$output" = dispatch ]   # 50 s early (observed)
  AUTOPILOT_NOW="2026-10-28T10:01:51Z" run _ap start; [ "$output" = dispatch ]   # 59 s early, boundary
  AUTOPILOT_NOW="2026-10-28T10:01:50Z" run _ap start; [ "$output" = already-on ] # 60 s early
  AUTOPILOT_NOW="2026-10-28T09:57:50Z" run _ap start; [ "$output" = already-on ] # 5 min early
  AP_WAKE_TOLERANCE=10 AUTOPILOT_NOW="2026-10-28T10:02:30Z" run _ap start; [ "$output" = already-on ]  # override
}

@test "start: documented trade-off, a typed on within the tolerance of a short wake dispatches (T20261124-243982)" {
  _ap start >/dev/null
  _ap record progress 0 T1 >/dev/null                                            # next_wake_at 10:01:00Z
  AUTOPILOT_NOW="2026-10-28T10:00:05Z" run _ap start; [ "$output" = dispatch ]   # 55 s early: indistinguishable from an early wake
  _ap wake 300 >/dev/null
  AUTOPILOT_NOW="2026-10-28T10:00:05Z" run _ap start; [ "$output" = already-on ] # a longer delay keeps a typed on out
}

# --- holds (T20261124-340374) ---------------------------------------------------

_hold_repo() {
  HROOT="$BATS_TEST_TMPDIR/hrepo"; mkdir -p "$HROOT/dev/TODO"
  printf -- '---\nstatus: Open\n---\n' > "$HROOT/dev/TODO/T20261124-000001-a.md"
  printf -- '---\nstatus: Open\n---\n' > "$HROOT/dev/TODO/T20261124-000002-b.md"
}
_gh_stub() { # _gh_stub <runs-status> <pr-state>
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *actions/runs/*) [ "$1" = fail ] && exit 1; echo "$1" ;;
  *pulls/*) [ "$2" = fail ] && exit 1; echo "$2" ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"; export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "hold-add: records a hold; holds lists it in TSV and JSON" {
  run _ap hold-add T20261124-000001 stalled "pr:12" "no progress twice"
  [ "$status" -eq 0 ]; [ "$output" = "held T20261124-000001 stalled" ]
  run _ap holds
  [ "$output" = $'T20261124-000001\tstalled\tno progress twice\tpr:12\t2026-10-28T10:00:00Z' ]
  run _ap holds --json
  [ "$(jq -r '.[0].task + " " + .[0].kind + " " + .[0].condition' <<<"$output")" = "T20261124-000001 stalled pr:12" ]
}

@test "hold-add: every condition form is accepted, as one argument or several" {
  _ap hold-add T20261124-000001 waiting "until 2026-11-01" "wait"
  [ "$(_j '.holds["T20261124-000001"].cond')" = "until 2026-11-01T00:00:00Z" ]
  _ap hold-add T20261124-000001 waiting until 2026-11-01T12:30Z "wait"
  [ "$(_j '.holds["T20261124-000001"].cond')" = "until 2026-11-01T12:30:00Z" ]
  _ap hold-add T20261124-000001 needs-human run:99 "r"
  [ "$(_j '.holds["T20261124-000001"].cond')" = "run:99" ]
  _ap hold-add T20261124-000001 needs-human "file-changed dev/TODO/x.md" "r"
  [ "$(_j '.holds["T20261124-000001"].cond')" = "file-changed dev/TODO/x.md" ]
  _ap hold-add T20261124-000001 stalled task-left-todo T20261124-000002 "r"
  [ "$(_j '.holds["T20261124-000001"].cond')" = "task-left-todo T20261124-000002" ]
  [ "$(_j '.holds | length')" -eq 1 ]   # same task again replaces its hold
}

@test "hold-add: refuses an unknown kind or condition and an empty reason (exit 2, nothing written)" {
  run _ap hold-add T20261124-000001 napping "pr:1" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "tomorrow" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "pr:abc" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "until someday" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "file-changed /etc/passwd" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "task-left-todo nope" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "pr:1" "   "; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled "pr:1"; [ "$status" -eq 2 ]
  run _ap hold-add nope stalled "pr:1" "r"; [ "$status" -eq 2 ]
  run _ap hold-add T20261124-000001 stalled $'file-changed a\tb' "r"; [ "$status" -eq 2 ]
  [ ! -s "$AUTOPILOT_STATE_FILE" ] || [ "$(_j '.holds // {} | length')" -eq 0 ]
}

@test "release: removes one hold; none when absent; bad id exits 2" {
  _ap hold-add T20261124-000001 stalled "pr:1" "r"; _ap hold-add T20261124-000002 waiting "pr:2" "r"
  run _ap release T20261124-000001; [ "$output" = released ]
  run _ap release T20261124-000001; [ "$output" = none ]
  [ "$(_j '.holds | keys | join(",")')" = T20261124-000002 ]
  run _ap release nope; [ "$status" -eq 2 ]
}

@test "holds: survive off and start; an old state file without holds reads fine" {
  _ap start >/dev/null; _ap hold-add T20261124-000001 stalled "pr:1" "r"
  _ap off >/dev/null; _ap start >/dev/null
  [ "$(_j '.holds | keys | join(",")')" = T20261124-000001 ]
  jq 'del(.holds)' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/o.json" && mv "$BATS_TEST_TMPDIR/o.json" "$AUTOPILOT_STATE_FILE"
  run _ap holds; [ "$status" -eq 0 ]; [ -z "$output" ]
  run _ap holds --json; [ "$output" = "[]" ]
  run _ap holds-check "$BATS_TEST_TMPDIR"; [ "$status" -eq 0 ]
}

@test "holds-check until: released once the time has passed" {
  _hold_repo
  _ap hold-add T20261124-000001 waiting "until 2026-10-28T11:00:00Z" "wait"
  run _ap holds-check "$HROOT"; [ -z "$output" ]
  AUTOPILOT_NOW="2026-10-28T11:00:00Z" run _ap holds-check "$HROOT"
  [ "$output" = "released T20261124-000001 (until 2026-10-28T11:00:00Z)" ]
  [ "$(_j '.holds | length')" -eq 0 ]
}

@test "holds-check run: and pr: use gh api; an error keeps the hold" {
  _hold_repo
  _ap hold-add T20261124-000001 waiting "run:55" "r"; _ap hold-add T20261124-000002 waiting "pr:7" "r"
  _gh_stub in_progress open
  run _ap holds-check "$HROOT"; [ -z "$output" ]
  _gh_stub fail fail
  run _ap holds-check "$HROOT"; [ -z "$output" ]; [ "$(_j '.holds | length')" -eq 2 ]
  _gh_stub completed open
  run _ap holds-check "$HROOT"; [ "$output" = "released T20261124-000001 (run:55)" ]
  _gh_stub completed closed
  run _ap holds-check "$HROOT"; [ "$output" = "released T20261124-000002 (pr:7)" ]
}

@test "holds-check file-changed: mtime or a git commit after the hold releases it" {
  _hold_repo
  export AUTOPILOT_NOW="2027-01-01T00:00:00Z"   # later than any real mtime
  echo a > "$HROOT/dev/f.txt"
  _ap hold-add T20261124-000001 waiting "file-changed dev/f.txt" "r"
  run _ap holds-check "$HROOT"; [ -z "$output" ]
  touch -t 203001010000 "$HROOT/dev/f.txt"
  run _ap holds-check "$HROOT"; [ "$output" = "released T20261124-000001 (file-changed dev/f.txt)" ]
  # a commit dated after the hold, file mtime still older
  touch -t 202001010000 "$HROOT/dev/f.txt"
  git -C "$HROOT" init -q; git -C "$HROOT" add dev/f.txt
  GIT_COMMITTER_DATE="2027-06-01T00:00:00Z" GIT_AUTHOR_DATE="2027-06-01T00:00:00Z" git -C "$HROOT" -c user.name=t -c user.email=t@t commit -q -m c
  _ap hold-add T20261124-000001 waiting "file-changed dev/f.txt" "r"
  run _ap holds-check "$HROOT"; [ "$output" = "released T20261124-000001 (file-changed dev/f.txt)" ]
  # a missing file is never a release
  _ap hold-add T20261124-000001 waiting "file-changed dev/none.txt" "r"
  run _ap holds-check "$HROOT"; [ -z "$output" ]
}

@test "holds-check task-left-todo: released when the named task has no dev/TODO file" {
  _hold_repo
  _ap hold-add T20261124-000001 stalled "task-left-todo T20261124-000002" "r"
  run _ap holds-check "$HROOT"; [ -z "$output" ]
  rm "$HROOT/dev/TODO/T20261124-000002-b.md"
  run _ap holds-check "$HROOT"; [ "$output" = "released T20261124-000001 (task-left-todo T20261124-000002)" ]
  # without a dev/TODO directory nothing is released (a wrong root never wipes holds)
  _ap hold-add T20261124-000001 stalled "task-left-todo T20261124-000002" "r"
  run _ap holds-check "$BATS_TEST_TMPDIR/nowhere"; [ -z "$output" ]
}

@test "prune: drops holds of tasks that left dev/TODO, prints each id once" {
  _hold_repo
  _ap start >/dev/null
  _ap hold-add T20261124-000001 stalled "pr:1" "r"; _ap hold-add T20261124-000009 stalled "pr:2" "r"
  run _ap prune "$HROOT"
  [ "$output" = "T20261124-000009" ]
  [ "$(_j '.holds | keys | join(",")')" = T20261124-000001 ]
}

# --- tiers and cursors (T20261124-670976) -----------------------------------------

# $1 id, $2 tier, $3 slug: an Open task with a frontmatter tier, queued last
_tier_task() {
  printf -- '---\nstatus: Open\nestimation: 1\ntier: %s\n---\n# %s\n' "$2" "$1" > "$AUTOPILOT_REPO_ROOT/dev/TODO/$1-${3:-slug}.md"
  printf -- '- [%s](%s-%s.md): t\n' "$1" "$1" "${3:-slug}" >> "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"
}
_tier_repo() { _nh_repo; echo "# TODO Queue" > "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"; }

@test "top: picks inside the highest tier that has an eligible task, queue order within it" {
  _tier_repo
  _tier_task T20260101-000001 4 a
  _tier_task T20260101-000002 3 b          # no tier would read the same default 3
  _nh_task T20260101-000003 Open c         # no tier: default 3
  _tier_task T20260101-000004 2 d
  _tier_task T20260101-000005 2 e
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000004 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 2; [ "$output" = T20260101-000005 ]   # --nth walks the same order
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 3; [ "$output" = T20260101-000002 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 4; [ "$output" = T20260101-000003 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 5; [ "$output" = T20260101-000001 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 6; [ -z "$output" ]
}

@test "top --urgent: only tiers 1 and 2 (the reserved slots)" {
  _tier_repo
  _tier_task T20260101-000001 3 a
  run _ap top "$AUTOPILOT_REPO_ROOT" --urgent; [ -z "$output" ]
  _tier_task T20260101-000002 2 b
  _tier_task T20260101-000003 1 c
  run _ap top "$AUTOPILOT_REPO_ROOT" --urgent; [ "$output" = T20260101-000003 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --urgent --nth 2; [ "$output" = T20260101-000002 ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --urgent --nth 3; [ -z "$output" ]
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth x; [ "$status" -eq 2 ]
}

@test "cursor: the task just dispatched goes behind its tier-mates, wraps, and a merged one is forgotten" {
  _tier_repo
  _tier_task T20260101-000001 3 a; _tier_task T20260101-000002 3 b; _tier_task T20260101-000003 3 c
  _ap_on
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000001 ]
  _ap busy on T20260101-000001; [ "$(_j '.cursors["3"]')" = T20260101-000001 ]
  _ap busy off
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000002 ]    # not re-picked ahead of its mates
  _ap busy on T20260101-000002; _ap busy off
  _ap busy on T20260101-000003; _ap busy off
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000001 ]    # wrapped to the tier's start
  # the cursor task finished (left the queue): the tier restarts at its top
  _ap busy on T20260101-000001; _ap busy off
  rm "$AUTOPILOT_REPO_ROOT/dev/TODO/T20260101-000001-a.md"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000002 ]
  # a single task is still picked again
  rm "$AUTOPILOT_REPO_ROOT/dev/TODO/T20260101-000002-b.md"
  _ap busy on T20260101-000003; _ap busy off
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000003 ]
}

@test "cursor: per tier, kept over off/start, a task without a file is ignored, old state loads" {
  _tier_repo
  _tier_task T20260101-000001 1 a; _tier_task T20260101-000002 3 b
  _ap_on
  _ap busy on T20260101-000001; _ap busy off
  _ap busy on T20260101-000002; _ap busy off
  _ap busy on T20260101-000999; _ap busy off     # no such task file: no cursor written, no error
  [ "$(_j '.cursors | keys | join(",")')" = "1,3" ]
  _ap off >/dev/null; _ap start >/dev/null
  [ "$(_j '.cursors["1"]')" = T20260101-000001 ]
  jq 'del(.cursors)' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/o.json" && mv "$BATS_TEST_TMPDIR/o.json" "$AUTOPILOT_STATE_FILE"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000001 ]
}

@test "holds: a held task is passed over by top and pickable, and release puts it back" {
  _tier_repo
  _tier_task T20260101-000001 2 a; _tier_task T20260101-000002 2 b; _tier_task T20260101-000003 3 c
  _ap_on
  _ap hold-add T20260101-000001 needs-human "pr:5" "waiting for the owner"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000002 ]
  _ap hold-add T20260101-000002 stalled "pr:6" "r"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000003 ]
  _ap hold-add T20260101-000003 waiting "pr:7" "r"
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ -z "$output" ]
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = none ]
  _ap release T20260101-000001
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000001 ]
  run _ap pickable "$AUTOPILOT_REPO_ROOT"; [ "$output" = pick ]
}

@test "todo-next --tier and --ids: filter by effective tier, list every survivor id" {
  _tier_repo
  _tier_task T20260101-000001 2 a; _nh_task T20260101-000002 Open b; _tier_task T20260101-000003 2 c
  cd "$AUTOPILOT_REPO_ROOT"
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --ids; [ "$output" = $'T20260101-000001\t2\nT20260101-000002\t3\nT20260101-000003\t2' ]
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --ids --tier 2; [ "$output" = $'T20260101-000001\t2\nT20260101-000003\t2' ]
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --ids --tier 3; [ "$output" = $'T20260101-000002\t3' ]
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --ids --tier 4; [ -z "$output" ]
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --tier 5; [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/todo/scripts/todo-next.sh" --tier 2 --check; [ "$status" -eq 0 ]
}

@test "cursor: keeps its place while the cursor task is in flight or held" {
  _tier_repo
  _tier_task T20260101-000001 3 a; _tier_task T20260101-000002 3 b; _tier_task T20260101-000003 3 c
  _ap_on
  _ap busy on T20260101-000002 --slot 1            # cursor = b, and b stays in flight
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000003 ]   # c next, not a again
  run _ap top "$AUTOPILOT_REPO_ROOT" --nth 2; [ "$output" = T20260101-000001 ]
  _ap busy off
  _ap hold-add T20260101-000002 stalled "pr:9" "r"  # b held: the cursor passes over it to c
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ "$output" = T20260101-000003 ]
}

# --- a stalled cycle creates a hold, not a bottom PR (T20261124-321658) -------------

@test "hold-report: NEEDS-ATTENTION -> needs-human on the task file, STUCK -> stalled for 2h, nothing written to queue.md" {
  _tier_repo; _tier_task T20260101-000001 3 a; _tier_task T20260101-000002 3 b
  cp "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md" "$BATS_TEST_TMPDIR/q.before"
  _ap_on
  printf 'NEEDS-ATTENTION: T20260101-000001 — needs an owner decision\nSTUCK: ci red — last task T20260101-000002 (b)\n' > "$BATS_TEST_TMPDIR/r.txt"
  run _ap hold-report "$BATS_TEST_TMPDIR/r.txt"
  [ "$output" = $'held T20260101-000001 needs-human\nheld T20260101-000002 stalled' ]
  [ "$(_j '.holds["T20260101-000001"].cond')" = "file-changed dev/TODO/T20260101-000001-a.md" ]
  [ "$(_j '.holds["T20260101-000001"].reason')" = "needs an owner decision" ]
  [ "$(_j '.holds["T20260101-000002"].cond')" = "until 2026-10-28T12:00:00Z" ]
  cmp "$BATS_TEST_TMPDIR/q.before" "$AUTOPILOT_REPO_ROOT/dev/TODO/queue.md"     # no queue.md edit
  # the held tasks are passed over by the next pick
  run _ap top "$AUTOPILOT_REPO_ROOT"; [ -z "$output" ]
}

@test "hold-report: an advanced task and a merged report make no hold; a missing task file falls back to until +24h" {
  _tier_repo; _tier_task T20260101-000001 3 a
  _ap_on
  printf 'MERGED: T20260101-000001 (a) — PR #5\n' > "$BATS_TEST_TMPDIR/r.txt"
  run _ap hold-report "$BATS_TEST_TMPDIR/r.txt"; [ -z "$output" ]; [ "$(_j '.holds // {} | length')" -eq 0 ]
  printf 'NEEDS-ATTENTION: T20260101-000009 — gone\n' > "$BATS_TEST_TMPDIR/r.txt"
  run _ap hold-report "$BATS_TEST_TMPDIR/r.txt"
  [ "$(_j '.holds["T20260101-000009"].cond')" = "until 2026-10-29T10:00:00Z" ]
  run _ap hold-report; [ "$status" -eq 2 ]
}

@test "hold-report: WAITING holds the fallback task for 1h; a run of stuck cycles (outage) holds nothing" {
  _tier_repo; _tier_task T20260101-000001 3 a
  _ap_on
  printf 'WAITING: PR #7 needs a human approval\n' > "$BATS_TEST_TMPDIR/r.txt"
  run _ap hold-report "$BATS_TEST_TMPDIR/r.txt" --fallback T20260101-000001
  [ "$output" = "held T20260101-000001 waiting" ]
  [ "$(_j '.holds["T20260101-000001"].cond')" = "until 2026-10-28T11:00:00Z" ]
  _ap release T20260101-000001 >/dev/null
  jq '.stuck_count = 3' "$AUTOPILOT_STATE_FILE" > "$BATS_TEST_TMPDIR/o.json" && mv "$BATS_TEST_TMPDIR/o.json" "$AUTOPILOT_STATE_FILE"
  printf 'STUCK: dispatch failed — last task T20260101-000001 (a)\n' > "$BATS_TEST_TMPDIR/r.txt"
  run _ap hold-report "$BATS_TEST_TMPDIR/r.txt"; [ "$output" = "skip T20260101-000001" ]
  [ "$(_j '.holds // {} | length')" -eq 0 ]
}

# --- visits, max_visits and park-after-N are retired (T20261124-115593) ---------------------

@test "retired: an old state file with visits and parked loads, and both keys go on the next write" {
  printf '%s' '{"schema":2,"status":"on","started_at":"2026-10-28T09:00:00Z","cycle_count":1,"merged_count":0,"stuck_count":0,"waiting_count":0,"day":"2026-10-28","cycles_today":0,"merges_today":0,"notices":[],"next_wake_at":null,"visits":{"T20260101-000001":3},"parked":[{"id":"T20260101-000002","at":"2026-10-28T09:00:00Z","reason":"r","visits":4}]}' > "$AUTOPILOT_STATE_FILE"
  run _ap report; [ "$status" -eq 0 ]; [[ "$output" != *"parked by autopilot"* ]]; [[ "$output" != *"revisiting"* ]]
  run _ap start; [ "$output" = dispatch ]
  _ap hold-add T20260101-000001 stalled "pr:1" "r" >/dev/null     # any write drops the retired keys
  [ "$(_j 'has("visits") or has("parked")')" = false ]
  [ "$(_j '.holds | length')" -eq 1 ]
  # off then start does not bring them back, and a fresh state has neither
  _ap off >/dev/null; _ap start >/dev/null
  [ "$(_j 'has("visits") or has("parked")')" = false ]
}

@test "retired: max_visits is no longer a config key (an old override is ignored, config-set refuses it)" {
  printf '{"max_visits": 5, "daily_cycle_cap": 10}' > "$AUTOPILOT_CONFIG_FILE"
  run _ap config-show --json; [ "$status" -eq 0 ]; [ "$(jq -r '.settings | has("max_visits")' <<<"$output")" = false ]
  [ "$(jq -r .settings.daily_cycle_cap.value <<<"$output")" = 10 ]
  run _ap config-set max_visits 3; [ "$status" -eq 2 ]
  run _ap config-reset daily_cycle_cap; [ "$status" -eq 0 ]
  [ "$(jq -r .max_visits "$AUTOPILOT_CONFIG_FILE")" = 5 ]    # unknown keys stay, as before
}

@test "stats: old visit, advance and park history lines are not cycles" {
  _ap start >/dev/null
  printf '%s\n' '{"ts":"2026-10-28T09:00:00Z","outcome":"visit","merged":0,"task":"T20260101-000001","visits":1}' '{"ts":"2026-10-28T09:01:00Z","outcome":"park","merged":0,"task":"T20260101-000001","visits":4}' > "$(_hist)"
  [ "$(_stat .cycles_24h)" = 0 ]
  _ap record progress 1 T20260101-000002 >/dev/null
  [ "$(_stat .cycles_24h)" = 1 ]; [ "$(_stat .merged_24h)" = 1 ]
}

@test "report: lists each hold with its kind, reason and release condition" {
  _ap start >/dev/null
  _ap hold-add T20260101-000001 needs-human "pr:12" "waiting on HashData" >/dev/null
  run _ap report
  [[ "$output" == *"held: T20260101-000001 (needs-human) — waiting on HashData; releases on pr:12"* ]]
}

@test "final-report: holds and a stuck last task are listed once each, with slugs" {
  _final_fixture
  mkdir -p dev/TODO
  printf -- '---\nstatus: Open\n---\n' > dev/TODO/T20261001-555555-big-decision.md
  printf -- '---\nstatus: Open\n---\n' > dev/TODO/T20261001-666666-flaky.md
  _ap hold-add T20261001-555555 needs-human "file-changed dev/TODO/T20261001-555555-big-decision.md" "needs an owner decision" >/dev/null
  _ap record stuck 0 T20261001-666666 "CI keeps failing" >/dev/null
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap final-report
  [[ "$output" == *"- Held (needs-human): T20261001-555555 (big-decision) — needs an owner decision; releases on file-changed dev/TODO/T20261001-555555-big-decision.md"* ]]
  [[ "$output" == *"- Stuck: T20261001-666666 (flaky) — CI keeps failing"* ]]
  [[ "$output" != *"Nothing outstanding"* ]]
  # a stuck task that is also held is not listed twice
  _ap hold-add T20261001-666666 stalled "pr:3" "r" >/dev/null
  _ap record stuck 0 T20261001-555555 "again" >/dev/null
  AUTOPILOT_NOW="2026-10-28T09:00:00Z" run _ap final-report
  [ "$(grep -c 'T20261001-555555' <<<"$output")" = 1 ]
}
