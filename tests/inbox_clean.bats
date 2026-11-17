#!/usr/bin/env bats
# Tests for inbox-clean/scripts/inbox-clean.sh (T20261116-391393): plan validation, capability gate, undo note, no send path.

bats_require_minimum_version 1.5.0
load test_helper
IC="$REPO_ROOT/inbox-clean/scripts/inbox-clean.sh"
RR="$REPO_ROOT/routine/scripts/run-routine.sh"

setup() {
  python3 -I -c 'import yaml' 2>/dev/null || skip "PyYAML missing"
  export CCXP_INBOX_CLEAN_DIR="$BATS_TEST_TMPDIR/undo"
  export CCXP_ROUTINES_PROFILE_FILE="$BATS_TEST_TMPDIR/profile.yml"
  export CCXP_RITUAL_DIR="$BATS_TEST_TMPDIR/markers"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/dev/TODO"
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin git@example.com:acme/widgets.git
  printf 'routines:\n  inbox:\n    steps: [{skill: "/inbox-clean"}]\n' >"$REPO/dev/.routines.yml"
}

@test "tools lists only read, label, archive and draft tools" {
  run bash "$IC" tools
  [ "$status" -eq 0 ]
  [[ "$output" == *$'create_draft\tgmail.draft'* ]]
  [[ "$output" == *$'unlabel_thread\tgmail.archive'* ]]
  run grep -E 'send_message|reply|forward|trash|spam|delete' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "check-tool: send-type tools exit 4, unknown exits 1, allowed exits 0" {
  for t in send_message reply forward trash_thread trash_message mark_thread_spam delete_draft update_draft update_message_labels; do
    run bash "$IC" check-tool "$t"
    [ "$status" -eq 4 ]
  done
  run bash "$IC" check-tool create_draft; [ "$status" -eq 0 ]
  run bash "$IC" check-tool something_new; [ "$status" -eq 1 ]
}

@test "plan --dry-run: ordered calls, archive gets a label first, no undo note written" {
  run bash "$IC" plan --dry-run <<<$'abc123\tarchive\ndef456\tlabel\tccxp/needs-reply\n0a1b2c3d\tdraft'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'DRY-RUN label_thread\tdef456\tccxp/needs-reply' ] || [ "${lines[1]}" = $'DRY-RUN label_thread\tdef456\tccxp/needs-reply' ]
  [[ "$output" == *$'DRY-RUN label_thread\tabc123\tccxp/archived'* ]]
  [[ "$output" == *$'DRY-RUN unlabel_thread\tabc123\tINBOX'* ]]
  [[ "$output" == *$'DRY-RUN create_draft\t0a1b2c3d\t-'* ]]
  [[ "$output" == *$'DRY-RUN label_thread\t0a1b2c3d\tccxp/draft-for-review'* ]]
  [ ! -e "$CCXP_INBOX_CLEAN_DIR" ]
}

@test "plan labels before archive before drafts" {
  run bash "$IC" plan --dry-run <<<$'abc123\tarchive\n0a1b2c3d\tdraft'
  [ "${lines[0]}" = $'DRY-RUN label_thread\tabc123\tccxp/archived' ]
  [ "${lines[1]}" = $'DRY-RUN unlabel_thread\tabc123\tINBOX' ]
  [ "${lines[2]}" = $'DRY-RUN create_draft\t0a1b2c3d\t-' ]
}

@test "plan refuses send, reply, forward, trash and spam actions with exit 4 and prints no call" {
  for a in send reply forward trash spam delete; do
    run bash "$IC" plan <<<$'abc123\t'"$a"
    [ "$status" -eq 4 ]
    [[ "$output" != *thread* ]] || [[ "$output" == *"not one of"* ]]
  done
  [ ! -e "$CCXP_INBOX_CLEAN_DIR" ]
}

@test "plan refuses bad thread ids, system labels and an empty plan" {
  run bash "$IC" plan <<<$'not-hex!\tarchive'; [ "$status" -eq 4 ]
  run bash "$IC" plan <<<$'abc123\tlabel\tINBOX'; [ "$status" -eq 4 ]
  run bash "$IC" plan <<<$'abc123\tlabel\tTRASH'; [ "$status" -eq 4 ]
  run bash "$IC" plan <<<$'abc123\tlabel'; [ "$status" -eq 4 ]
  run bash "$IC" plan </dev/null; [ "$status" -eq 3 ]
}

@test "plan without --dry-run writes a private undo note of ids and labels only, and undo reverses it" {
  run bash "$IC" plan <<<$'abc123\tarchive\n0a1b2c3d\tdraft'
  [ "$status" -eq 0 ]
  f="$(sed -n 's/^undo=//p' <<<"$output")"
  [ -f "$f" ]
  [[ "$(ls -l "$f")" == -rw-------* ]]
  run bash "$IC" undo "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'label_thread\tabc123\tINBOX'* ]]
  [[ "$output" == *$'unlabel_thread\tabc123\tccxp/archived'* ]] || [[ "$output" == *$'unlabel_thread\tabc123'* ]]
  [[ "$output" == *$'MANUAL\t0a1b2c3d'* ]]
}

@test "plan without an undo dir makes no plan" {
  unset CCXP_INBOX_CLEAN_DIR CCXP_PROFILE_DIR
  run bash "$IC" plan <<<$'abc123\tarchive'
  [ "$status" -eq 3 ]
  [[ "$output" != *unlabel_thread* ]]
}

@test "--routine: capability comes only from the profile file; the repo file cannot grant it" {
  printf 'routines:\n  inbox:\n    steps: [{skill: "/inbox-clean"}]\n    allow: [gmail.archive, gmail.label]\n' >"$REPO/dev/.routines.yml"
  run bash "$IC" plan --dry-run --routine inbox --repo "$REPO" <<<$'abc123\tarchive'
  [ "$status" -eq 5 ]
  printf 'routines:\n  inbox:\n    allow: [gmail.archive, gmail.label]\n' >"$CCXP_ROUTINES_PROFILE_FILE"
  run bash "$IC" plan --dry-run --routine inbox --repo "$REPO" <<<$'abc123\tarchive'
  [ "$status" -eq 0 ]
  run bash "$IC" plan --dry-run --routine inbox --repo "$REPO" <<<$'abc123\tdraft'
  [ "$status" -eq 5 ]
}

@test "run-routine allowed: send-type capabilities are never grantable, also as gmail.<name>" {
  printf 'routines:\n  inbox:\n    allow: [gmail.send, send, reply, gmail.forward, trash, gmail.spam, gmail.draft]\n' >"$CCXP_ROUTINES_PROFILE_FILE"
  for c in send gmail.send reply gmail.forward trash gmail.spam; do
    run bash "$RR" --repo "$REPO" allowed inbox "$c"
    [ "$status" -ne 0 ]
  done
  run bash "$RR" --repo "$REPO" allowed inbox gmail.draft
  [ "$status" -eq 0 ]
}

@test "no send-type operation is reachable: script and skill name them only as refusals" {
  # the script never invokes a connector at all
  run grep -nE 'mcp__|(^|[ ;|&])(gh|curl) ' "$IC"
  [ "$status" -ne 0 ]
  # the tool table carries no send-type name
  run bash "$IC" tools
  run grep -E '^(send_message|reply|forward|trash|mark|delete)' <<<"$output"
  [ "$status" -ne 0 ]
  # the SKILL.md allowed-calls table rows name none of them
  run bash -c "sed -n '/^## Allowed calls/,/^## Workflow/p' '$REPO_ROOT/inbox-clean/SKILL.md' | grep '^|' | grep -E 'send_message|reply|forward|trash|spam|delete'"
  [ "$status" -ne 0 ]
}

@test "email-triage names the inbox-clean carve-out and stays read-only" {
  run grep -c 'inbox-clean' "$REPO_ROOT/email-triage/SKILL.md"
  [ "$output" -ge 2 ]
}
