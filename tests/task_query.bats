#!/usr/bin/env bats
# todo/scripts/task-query.sh and the dimension flags of todo-list.sh / todo-next.sh,
# plus the standup `dimensions` section (T20261114-380745). Offline, fixture dev/TODO.

load test_helper

Q="$REPO_ROOT/todo/scripts/task-query.sh"
LIST="$REPO_ROOT/todo/scripts/todo-list.sh"
NEXT="$REPO_ROOT/todo/scripts/todo-next.sh"

setup() {
  W="$BATS_TEST_TMPDIR/w"; mkdir -p "$W/dev/TODO"; cd "$W"
  export TODO_QUEUE_DIR="$W" SESSION_TODAY=2026-11-16 CCXP_PEER_MODE=0
  export CCXP_ROUTINES_PROFILE_FILE="$BATS_TEST_TMPDIR/profile.yml"
  printf '# TODO Queue\n\n' > dev/TODO/queue.md
}

# task <n> <status> [frontmatter lines...]
task() {
  local n="$1" st="$2"; shift 2
  local id="T20261116-00000$n"
  { echo "---"; echo "status: $st"; echo "estimation: 1"; for l in "$@"; do echo "$l"; done; echo "---"; echo; echo "# $id: title $n"; } \
    > "dev/TODO/$id-s.md"
  echo "- [$id]($id-s.md): title $n" >> dev/TODO/queue.md
}
ids() { grep -oE '^T[0-9]+-[0-9]+' <<<"$output" | sed 's/^T20261116-00000//' | paste -sd, -; }

@test "when: today, tomorrow, overdue, week and an exact date" {
  task 1 Open "when: 2026-11-16T09:00"
  task 2 Open "when: 2026-11-17"
  task 3 Open "when: 2026-11-10"
  task 4 Open "when: 2026-11-22"
  task 5 Open "when: 2026-11-23"
  task 6 Open
  run bash "$Q" --when today;    [ "$status" -eq 0 ]; [ "$(ids)" = "1" ]
  run bash "$Q" --when tomorrow; [ "$(ids)" = "2" ]
  run bash "$Q" --when overdue;  [ "$(ids)" = "3" ]
  run bash "$Q" --when week;     [ "$(ids)" = "1,2,4" ]
  run bash "$Q" --when 2026-11-23; [ "$(ids)" = "5" ]
  run bash "$Q" --when today,overdue; [ "$(ids)" = "1,3" ]
}

@test "when: a when..when-end window matches by overlap" {
  task 1 Open "when: 2026-11-14" "when-end: 2026-11-18"
  run bash "$Q" --when today; [ "$(ids)" = "1" ]
  run bash "$Q" --when overdue; [ -z "$(ids)" ]
}

@test "the clock honors CCXP_RITUAL_NOW with CCXP_RITUAL_TZ" {
  task 1 Open "when: 2026-11-17"
  unset SESSION_TODAY
  CCXP_RITUAL_NOW=2026-11-16T20:00:00Z CCXP_RITUAL_TZ=Asia/Shanghai run bash "$Q" --when today
  [ "$(ids)" = "1" ]
  CCXP_RITUAL_NOW=2026-11-16T20:00:00Z CCXP_RITUAL_TZ=UTC run bash "$Q" --when today
  [ -z "$(ids)" ]
}

@test "place and --here: here: list from the profile, absent place means anywhere" {
  task 1 Open "place: [office, vpn]"
  task 2 Open "place: [home]"
  task 3 Open
  run bash "$Q" --place vpn; [ "$(ids)" = "1" ]
  run bash "$Q" --here;      [ "$(ids)" = "3" ]          # no here: configured
  printf 'here: [office]\n' > "$CCXP_ROUTINES_PROFILE_FILE"
  run bash "$Q" --here;      [ "$(ids)" = "1,3" ]
  printf 'here:\n  - home   # block form\n' > "$CCXP_ROUTINES_PROFILE_FILE"
  run bash "$Q" --here;      [ "$(ids)" = "2,3" ]
}

@test "person is separate from waiting-on; any matches every person blocker" {
  task 1 Open "person: [alice]"
  task 2 "Blocked by person:alice — need the keys"
  task 3 "Blocked by person:bob"
  task 4 "Blocked by T20261116-000001"
  run bash "$Q" --person alice;     [ "$(ids)" = "1" ]
  run bash "$Q" --waiting-on alice; [ "$(ids)" = "2" ]
  run bash "$Q" --waiting-on any;   [ "$(ids)" = "2,3" ]
}

@test "type event lists events by date; closed and parked are excluded unless --all" {
  task 1 Open "type: event" "when: 2026-11-20"
  task 2 Open "type: event" "when: 2026-11-18"
  task 3 Done "type: event" "when: 2026-11-17"
  task 4 Open "type: chore"
  run bash "$Q" --type event; [ "$(ids)" = "2,1" ]
  run bash "$Q" --type event --all; [ "$(ids)" = "3,2,1" ]
  run bash "$Q" --type event --when week; [ "$(ids)" = "2,1" ]
}

@test "group-by: key order, queue order inside, multi-valued keys repeat, none last" {
  task 1 Open "place: [b]" "when: 2026-11-18"
  task 2 Open "place: [a, b]" "when: 2026-11-16"
  task 3 Open
  run bash "$Q" --group-by place
  [ "${lines[0]}" = "## a" ]
  [[ "${lines[1]}" == T20261116-000002* ]]
  [ "${lines[2]}" = "## b" ]
  [[ "${lines[3]}" == T20261116-000001* ]]
  [[ "${lines[4]}" == T20261116-000002* ]]
  [ "${lines[5]}" = "## (none)" ]
  run bash "$Q" --group-by when
  [ "${lines[0]}" = "## 2026-11-16" ]; [ "${lines[2]}" = "## 2026-11-18" ]; [ "${lines[4]}" = "## (none)" ]
}

@test "--json: schema, groups and age_days" {
  git init -q -b main . && git config user.email t@t && git config user.name t
  task 1 "Blocked by person:bob" "place: [office]"
  GIT_COMMITTER_DATE="2026-11-11T12:00:00Z" git add -A && GIT_COMMITTER_DATE="2026-11-11T12:00:00Z" git commit -qm x
  run bash "$Q" --waiting-on any --group-by place --json
  [ "$status" -eq 0 ]
  jq -e '.today=="2026-11-16" and .count==1 and .group_by=="place" and .groups[0].key=="office"
    and .tasks[0].id=="T20261116-000001" and .tasks[0].waiting_on==["bob"] and .tasks[0].age_days==5
    and (.tasks[0]|has("when") and has("when_end") and has("place") and has("person") and has("type"))' <<<"$output"
}

@test "an empty result is not an error" {
  run bash "$Q" --when today; [ "$status" -eq 0 ]; [ "$output" = "(no matching tasks)" ]
  run bash "$Q" --when today --json; jq -e '.count==0 and .tasks==[]' <<<"$output"
}

@test "bad usage exits 2" {
  run bash "$Q" --bogus; [ "$status" -eq 2 ]
  run bash "$Q" --type nope; [ "$status" -eq 2 ]
  run bash "$Q" --place; [ "$status" -eq 2 ]
  run bash "$Q" --when nonsense; [ "$status" -eq 2 ]
}

@test "todo-list: no flags is byte-identical to the pre-change table (golden)" {
  task 1 Open "deadline: 2026-11-10"
  task 2 "In Progress" "when: 2026-11-16" "place: [office]"
  run bash "$LIST"
  [ "$status" -eq 0 ]
  expected='| # | ID | Title | Status | Est | Deadline | Scheduled | Claimed |
|---|----|-------|--------|-----|----------|-----------|---------|
| 1 | T20261116-000001 | title 1 | Open | 1 | 2026-11-10 ⚠ |  |  |
| 2 | T20261116-000002 | title 2 | In Progress | 1 |  |  |  |
total: 2
status In Progress: 1
status Open: 1
0 committed to active iteration
0 claimed (0 mine, 0 by peers)
Parking lot: 0 parked'
  [ "$output" = "$expected" ]
}

@test "todo-list: dimension flags delegate; --type alone keeps the old table" {
  task 1 Open "type: event" "when: 2026-11-16"
  task 2 Open
  run bash "$LIST" --when today --group-by type
  [ "${lines[0]}" = "## event" ]
  run bash "$LIST" --type event
  [[ "${lines[0]}" == "| # | ID |"* ]]
}

@test "todo-next: events are never picked; filters narrow but keep queue order" {
  task 1 Open "type: event" "when: 2026-11-16"
  task 2 Open "place: [home]"
  task 3 Open "when: 2026-11-16"
  task 4 Open
  run bash "$NEXT" --nth 1
  [[ "$output" == "#2 of 4: T20261116-000002"* ]]
  run bash "$NEXT" --when today --nth 1
  [[ "$output" == "#3 of 4: T20261116-000003"* ]]
  run bash "$NEXT" --here --nth 1
  [[ "$output" == "#3 of 4: T20261116-000003"* ]]     # skips the home task, first anywhere task
  run bash "$NEXT"
  [ "${lines[0]}" = "Due today (informational, does not reorder the queue):" ]
  [[ "$output" == *"#2 of 4: T20261116-000002"* ]]
}

@test "todo-next: with nothing due today the output has no Due today line" {
  task 1 Open
  run bash "$NEXT"
  [[ "$output" != *"Due today"* ]]
  [[ "${lines[0]}" == "#1 of 1:"* ]]
}

# ---- standup sections ----------------------------------------------------------

@test "standup: Today, Waiting on and Events this week render from fixtures and vanish when empty" {
  local R="$BATS_TEST_TMPDIR/sr"; mkdir -p "$R/dev/TODO" "$R/dev/JOURNAL"
  git -C "$R" init -q -b main; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf '# TODO Queue\n\n' > "$R/dev/TODO/queue.md"
  cd "$R"
  task_in() { printf -- '---\nstatus: %s\nestimation: 1\n%s\n---\n\n# %s: %s\n' "$2" "$3" "$1" "$4" > "dev/TODO/$1-s.md"; }
  task_in T20261116-000001 Open "when: 2026-11-16" "due task"
  task_in T20261116-000002 "Blocked by person:bob" "" "waiting task"
  task_in T20261116-000003 Open $'type: event\nwhen: 2026-11-19' "the event"
  git add -A; GIT_COMMITTER_DATE="2026-11-11T12:00:00Z" git commit -qm fixtures
  export STANDUP_GH=false
  run bash "$REPO_ROOT/ccxp/scripts/standup-data.sh" --date 2026-11-16 --dir "$R"
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/d.json"
  jq -e '(.dimensions.today|length)==1 and .dimensions.waiting[0].age_days==5 and .dimensions.events[0].id=="T20261116-000003" and (.errors|has("dimensions")|not)' "$BATS_TEST_TMPDIR/d.json"
  echo '{"top5":[]}' > "$BATS_TEST_TMPDIR/j.json"
  run bash "$REPO_ROOT/ccxp/scripts/render-standup.sh" "$BATS_TEST_TMPDIR/d.json" "$BATS_TEST_TMPDIR/j.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"*📅 Today*"*"• T20261116-000001 — due task"* ]]
  [[ "$output" == *"*⏳ Waiting on*"*"• bob — T20261116-000002 waiting task (5d)"* ]]
  [[ "$output" == *"*🗓 Events this week*"*"• 2026-11-19 — T20261116-000003 the event"* ]]
  run bash "$REPO_ROOT/ccxp/scripts/render-standup.sh" "$BATS_TEST_TMPDIR/d.json" "$BATS_TEST_TMPDIR/j.json" --format journal
  [[ "$output" == *"## Today"* && "$output" == *"## Waiting on"* && "$output" == *"## Events this week"* ]]
  # empty fixture: all three omitted
  jq '.dimensions={today:[],waiting:[],events:[]}' "$BATS_TEST_TMPDIR/d.json" > "$BATS_TEST_TMPDIR/e.json"
  run bash "$REPO_ROOT/ccxp/scripts/render-standup.sh" "$BATS_TEST_TMPDIR/e.json" "$BATS_TEST_TMPDIR/j.json"
  [[ "$output" != *"Today*"* && "$output" != *"Waiting on"* && "$output" != *"Events this week"* ]]
}
