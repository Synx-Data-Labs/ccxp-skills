#!/usr/bin/env bats
# slack-check-reply/scripts/{pending,fix-ref}.sh and the threads.sh commands they
# sit on (fix-ref, list --full). Offline: a temp state file, no Slack.

load test_helper
bats_require_minimum_version 1.5.0

PENDING="$REPO_ROOT/slack-check-reply/scripts/pending.sh"
FIXREF="$REPO_ROOT/slack-check-reply/scripts/fix-ref.sh"
THREADS="$REPO_ROOT/_threads/threads.sh"

setup() {
  export THREADS_FILE="$BATS_TEST_TMPDIR/state/drive-threads.json"
  mkdir -p "$(dirname "$THREADS_FILE")"
  cat > "$THREADS_FILE" <<'JSON'
{
  "T304536": {"channel_id":"C1","message_ts":"1.1","type":"design-decision","summary":"pick A or B","sent_at":"2026-10-29T10:00:00Z","resolved":false},
  "T304537-pr12": {"channel_id":"C2","message_ts":"2.2","type":"approval","summary":"merge it?","sent_at":"2026-10-28T10:00:00Z","resolved":false},
  "T304538": {"channel_id":"C3","message_ts":"3.3","type":"blocker","summary":"done thing","sent_at":"2026-10-20T10:00:00Z","resolved":true,"resolved_at":"2026-10-21T00:00:00Z"}
}
JSON
}

@test "pending: no argument and all list only unresolved entries, with channel and ts" {
  run bash "$PENDING"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [[ "$output" == *$'T304536\tfalse\tdesign-decision\t2026-10-29T10:00:00Z\tpick A or B\tC1\t1.1'* ]]
  [[ "$output" == *"T304537-pr12"* ]]
  [[ "$output" != *T304538* ]]
  run bash "$PENDING" all; [ "$status" -eq 0 ]; [[ "$output" == *T304536* ]]
}

@test "pending: a task id returns exactly that entry, resolved or not" {
  run bash "$PENDING" T304538
  [ "$status" -eq 0 ]
  [ "$output" = $'T304538\ttrue\tblocker\t2026-10-20T10:00:00Z\tdone thing\tC3\t3.3' ]
  run bash "$PENDING" T304537-pr12; [ "$status" -eq 0 ]; [[ "$output" == T304537-pr12* ]]
}

@test "pending: an unknown task id exits 3 with a message; a short id never matches a longer key" {
  run --separate-stderr bash "$PENDING" T9999
  [ "$status" -eq 3 ]; [ -z "$output" ]; [[ "$stderr" == *"T9999"* ]]
  run bash "$PENDING" T30453; [ "$status" -eq 3 ]
}

@test "pending: standup reads nothing, even from a malformed state file" {
  echo '[1,2' > "$THREADS_FILE"
  run bash "$PENDING" standup
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "pending: a missing state file is empty for all and not-found for an id" {
  rm -f "$THREADS_FILE"
  run bash "$PENDING"; [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash "$PENDING" T304536; [ "$status" -eq 3 ]
}

@test "pending: a zero-byte state file is empty, not malformed, and add still works on it" {
  : > "$THREADS_FILE"
  run bash "$PENDING"; [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash "$PENDING" T304536; [ "$status" -eq 3 ]
  run bash "$THREADS" add T5 --channel C --ts 1 --type t --summary s; [ "$status" -eq 0 ]
  [ "$(jq -r 'keys | join(",")' "$THREADS_FILE")" = T5 ]
}

@test "pending: a malformed state file exits 4 and is left untouched" {
  echo '{"T1": 5}' > "$THREADS_FILE"
  run bash "$PENDING"; [ "$status" -eq 4 ]
  run bash "$PENDING" T1; [ "$status" -eq 4 ]
  [ "$(cat "$THREADS_FILE")" = '{"T1": 5}' ]
}

@test "pending: usage errors exit 2" {
  run bash "$PENDING" a b; [ "$status" -eq 2 ]
  run bash "$PENDING" bogus; [ "$status" -eq 2 ]
  run bash "$PENDING" 'T1;rm'; [ "$status" -eq 2 ]
}

@test "fix-ref: only channel and ts change; the rest of the entry and the other entries are kept" {
  before="$(jq -S 'del(.T304536)' "$THREADS_FILE")"
  run bash "$FIXREF" T304536 C9 9.9
  [ "$status" -eq 0 ]
  [ "$(jq -r '.T304536 | [.channel_id,.message_ts,.type,.summary,.sent_at,(.resolved|tostring)] | join("|")' "$THREADS_FILE")" \
     = "C9|9.9|design-decision|pick A or B|2026-10-29T10:00:00Z|false" ]
  [ "$(jq -S 'del(.T304536)' "$THREADS_FILE")" = "$before" ]
  # and pending now reads the corrected reference
  run bash "$PENDING" T304536; [[ "$output" == *$'\tC9\t9.9' ]]
}

@test "fix-ref: absent key exits 3 and writes nothing; missing file exits 3 and creates nothing" {
  cp "$THREADS_FILE" "$BATS_TEST_TMPDIR/orig.json"
  run bash "$FIXREF" T1 C9 9.9; [ "$status" -eq 3 ]
  cmp "$THREADS_FILE" "$BATS_TEST_TMPDIR/orig.json"
  rm -f "$THREADS_FILE"
  run bash "$FIXREF" T304536 C9 9.9; [ "$status" -eq 3 ]
  [ ! -e "$THREADS_FILE" ]
}

@test "fix-ref: malformed file exits 4 untouched; usage and empty values exit 2" {
  echo 'nope' > "$THREADS_FILE"
  run bash "$FIXREF" T304536 C9 9.9; [ "$status" -eq 4 ]
  [ "$(cat "$THREADS_FILE")" = nope ]
  run bash "$FIXREF" T304536 C9; [ "$status" -eq 2 ]
  run bash "$FIXREF" T304536 "" 9.9; [ "$status" -eq 2 ]
}

@test "threads.sh list: --full adds channel and ts; an unknown flag is a usage error" {
  run bash "$THREADS" list --unresolved
  [ "$(printf '%s' "$output" | head -n1 | awk -F'\t' '{print NF}')" = 5 ]
  run bash "$THREADS" list --bogus; [ "$status" -eq 2 ]
}

@test "slack-check-reply SKILL.md calls the scripts and no longer hand-edits the state file" {
  grep -q 'slack-check-reply/scripts/pending.sh' "$REPO_ROOT/slack-check-reply/SKILL.md"
  grep -q 'slack-check-reply/scripts/fix-ref.sh' "$REPO_ROOT/slack-check-reply/SKILL.md"
  run grep -nE 'mkdir -p \.claude/state|Update the state file' "$REPO_ROOT/slack-check-reply/SKILL.md"
  [ "$status" -eq 1 ]
}
