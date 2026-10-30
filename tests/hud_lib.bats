#!/usr/bin/env bats
# Tests for hud/scripts/hud-lib.sh — the bash data layer behind the ccxp-hud
# mod (task claimed by this clone, branch, autopilot fields, last-input time).
# Carried over from the retired statusline-setup skill's suite; the text
# statusline segment tests (sl-autopilot-part, sl-join, the stdin entrypoint)
# went with it.
#
# Helper functions are sourced and tested directly.

load test_helper
SCRIPT="$REPO_ROOT/hud/scripts/hud-lib.sh"

setup() {
  # The machine-id/secret cache lives under ~/.claude/state by default; tests
  # must neither read the developer's real identity nor write to their home.
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  # Same isolation for the last-user-input timestamp dir.
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
}

# The clone-id for a path, computed exactly the way production computes it.
# Fixtures MUST go through this rather than hardcoding a format: hardcoding is
# what let the old suite stay green while the HUD silently matched nothing
# (T20260911-698434).
_clone_id() { bash -c "source '$SCRIPT'; sl-clone-id '$1'"; }

# Build a throwaway git repo with a dev/TODO dir under $BATS_TEST_TMPDIR and
# print its path. Args: $1 = subdir name.
_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/dev/TODO"
  git -C "$dir" init -q
  printf '%s' "$dir"
}

# sl-autopilot-fields record -> the compact "ap:[r] <elapsed>hr [⚠stuck]
# loops <cycle> ✓<merged>" line, so the happy-path assertions stay readable.
# Empty record -> empty output.
_ap_line() {
  local rec st prefix el req stuck cycle lo lt sr stop merged wake warn=""
  rec=$(bash -c "source '$SCRIPT'; sl-autopilot-fields '$1'")
  [ -n "$rec" ] || return 0
  IFS=$'\x1f' read -r st prefix el req stuck cycle lo lt sr stop merged wake <<<"$rec"
  [ "$stuck" -gt 0 ] && warn=" ⚠${stuck}"
  printf 'ap:%s %shr%s loops %s ✓%s' "$prefix" "$el" "$warn" "$cycle" "$merged"
}

# ---------------------------------------------------------------------------
# Sourceable / structure
# ---------------------------------------------------------------------------

@test "hud-lib.sh is sourceable and defines the sl-* helpers without running anything" {
  run bash -c "source '$SCRIPT'; type sl-claimed-task-label sl-autopilot-fields sl-ledger-json sl-last-input-epoch >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "hud-lib.sh no longer ships the retired statusline entrypoint or text segments" {
  run bash -c "source '$SCRIPT'; type statusline-command sl-autopilot-part sl-hud-active 2>&1"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sl-repo-root
# ---------------------------------------------------------------------------

@test "sl-repo-root resolves the git toplevel for a path inside a repo" {
  local repo
  repo=$(_make_repo repo1)
  mkdir -p "$repo/dev/TODO/nested"
  run bash -c "source '$SCRIPT'; sl-repo-root '$repo/dev/TODO/nested'"
  [ "$status" -eq 0 ]
  # Compare against git's own realpath-resolved toplevel, not $repo verbatim —
  # on macOS $BATS_TEST_TMPDIR lives under /var, a symlink to /private/var, so
  # raw $repo and git's resolved output legitimately differ textually.
  [ "$output" = "$(git -C "$repo" rev-parse --show-toplevel)" ]
}

@test "sl-repo-root falls back to the given cwd when not a git repo" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"
  run bash -c "source '$SCRIPT'; sl-repo-root '$dir'"
  [ "$status" -eq 0 ]
  [ "$output" = "$dir" ]
}

# ---------------------------------------------------------------------------
# sl-clone-id
# ---------------------------------------------------------------------------

@test "sl-clone-id EQUALS _tc_claimant_id for the same clone (cross-check)" {
  # The assertion the previous suite could not make: it pinned sl-clone-id
  # against its own hardcoded format, so a divergence from task_claim.sh stayed
  # green while the feature silently broke. Both now source one definition;
  # this fails loudly if that ever stops being true.
  local from_statusline from_claim
  from_statusline="$(bash -c "source '$SCRIPT'; sl-clone-id '/some/repo'")"
  from_claim="$(bash -c "
    source '$REPO_ROOT/_session/claimant-id.sh'
    claimant_clone_path() { printf '/some/repo'; }
    claimant_id \"\$(claimant_clone_path)\"")"
  [ -n "$from_statusline" ]
  [ "$from_statusline" = "$from_claim" ]
}

@test "sl-clone-id emits the cc1- shape and leaks no hostname or path" {
  local id; id="$(_clone_id /some/repo)"
  [[ "$id" =~ ^cc1-[0-9a-f]{8}:[0-9a-f]{16}$ ]]
  [[ "$id" != *"$(hostname)"* ]]
  [[ "$id" != *"/some/repo"* ]]
}

# ---------------------------------------------------------------------------
# sl-claimed-task-label
# ---------------------------------------------------------------------------

@test "sl-claimed-task-label prints nothing when the TODO dir does not exist" {
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$BATS_TEST_TMPDIR/missing' 'host:/repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-claimed-task-label prints nothing when no task is claimed by this clone" {
  local repo clone_id
  repo=$(_make_repo repo2)
  clone_id="$(_clone_id "$repo")"
  cat > "$repo/dev/TODO/T20260101-000001.md" <<EOF
---
claimed_by: otherhost:/other/repo
---
# T20260101-000001: Some task
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-claimed-task-label prints '<id>: <title>' when claimed_by matches and a heading exists" {
  local repo clone_id
  repo=$(_make_repo repo3)
  clone_id="$(_clone_id "$repo")"
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
# T20260427-242654: Fix the thing
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ "$output" = "T20260427-242654: Fix the thing" ]
}

@test "sl-claimed-task-label prints just the id when no '# T<id>' heading exists" {
  local repo clone_id
  repo=$(_make_repo repo4)
  clone_id="$(_clone_id "$repo")"
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
No heading here.
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ "$output" = "T20260427-242654" ]
}

@test "sl-claimed-task-label anchors the match so a longer sibling clone-id cannot match as a prefix" {
  local repo clone_id
  repo=$(_make_repo repo5)
  clone_id="$(_clone_id "$repo")"
  # A sibling clone whose id has this clone's id as a strict prefix.
  cat > "$repo/dev/TODO/T20260427-999999.md" <<EOF
---
claimed_by: ${clone_id}-sibling-suffix
---
# T20260427-999999: Wrong match
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-branch-name
# ---------------------------------------------------------------------------

@test "sl-branch-name prints the current branch name" {
  local repo
  repo=$(_make_repo repo-branch1)
  git -C "$repo" checkout -q -b some-feature-branch
  run bash -c "source '$SCRIPT'; sl-branch-name '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "some-feature-branch" ]
}

@test "sl-branch-name works pre-first-commit (unborn HEAD)" {
  local repo
  repo=$(_make_repo repo-branch2)
  run bash -c "source '$SCRIPT'; sl-branch-name '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$repo" symbolic-ref --short HEAD)" ]
}

@test "sl-branch-name prints nothing when not a git repo" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo-branch"
  mkdir -p "$dir"
  run bash -c "source '$SCRIPT'; sl-branch-name '$dir'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-last-input-epoch (timestamp only; the `last: <text>` part is retired)
# ---------------------------------------------------------------------------

@test "sl-last-input-epoch prints nothing for an empty session_id or a missing file" {
  run bash -c "source '$SCRIPT'; sl-last-input-epoch '$BATS_TEST_TMPDIR/li' ''; sl-last-input-epoch '$BATS_TEST_TMPDIR/li-missing' 'sess-1'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-last-input-epoch prints the file mtime as epoch seconds" {
  mkdir -p "$BATS_TEST_TMPDIR/li"
  : > "$BATS_TEST_TMPDIR/li/sess-1"
  touch -t 202601010000 "$BATS_TEST_TMPDIR/li/sess-1"
  run bash -c "source '$SCRIPT'; sl-last-input-epoch '$BATS_TEST_TMPDIR/li' 'sess-1'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 1700000000 ]
}

@test "sl-last-input-epoch rejects a path-traversal session_id instead of reading outside the state dir" {
  mkdir -p "$BATS_TEST_TMPDIR/li"
  : > "$BATS_TEST_TMPDIR/outside-marker"
  run bash -c "source '$SCRIPT'; sl-last-input-epoch '$BATS_TEST_TMPDIR/li' '../outside-marker'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-iso-to-epoch
# ---------------------------------------------------------------------------

@test "sl-iso-to-epoch round-trips a known ISO-8601 timestamp" {
  run bash -c "source '$SCRIPT'; sl-iso-to-epoch '2026-01-01T00:00:00Z'"
  [ "$status" -eq 0 ]
  [ "$output" = "1767225600" ]
}

# ---------------------------------------------------------------------------
# sl-autopilot-fields (schema 2: on / paused / off, no duration)
# ---------------------------------------------------------------------------

# $1 repo, $2 json body (written verbatim to the state file)
_ap_state() { mkdir -p "$1/dev"; printf '%s' "$2" > "$1/dev/.autopilot-state.json"; }
_ap_ago() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }

@test "sl-autopilot-fields prints nothing when the state file doesn't exist" {
  local repo
  repo=$(_make_repo repo-ap-absent)
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-fields prints nothing when off (AP off)" {
  local repo
  repo=$(_make_repo repo-ap-off)
  _ap_state "$repo" '{"schema": 2, "status": "off", "started_at": "2026-01-01T00:00:00Z", "stuck_count": 0, "cycle_count": 3}'
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-fields treats an old-format state file as off, whatever its status" {
  local repo status_word
  repo=$(_make_repo repo-ap-legacy)
  for status_word in running paused stopped; do
    _ap_state "$repo" "{\"status\": \"$status_word\", \"started_at\": \"$(_ap_ago 90)\", \"end_time\": \"2099-01-01T00:00:00Z\", \"paused_at\": \"$(_ap_ago 30)\", \"stuck_count\": 1, \"cycle_count\": 3}"
    run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "sl-autopilot-fields prints ap:[r] <elapsed>hr [⚠stuck] loops <cycle> ✓<merged> when on and working" {
  local repo
  repo=$(_make_repo repo-ap-running)
  # Real wall-clock offset: 90 minutes ago rounds to 2hr (awk %.0f rounds).
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", \"stuck_count\": 1, \"cycle_count\": 10, \"merged_count\": 4, \"last_outcome\": \"progress\"}"
  run _ap_line "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[r] 2hr ⚠1 loops 10 ✓4" ]
}

@test "sl-autopilot-fields prints ap:[b] when on and last_outcome is stuck" {
  local repo
  repo=$(_make_repo repo-ap-backing-off)
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", \"stuck_count\": 2, \"cycle_count\": 4, \"last_outcome\": \"stuck\"}"
  run _ap_line "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[b] 2hr ⚠2 loops 4 ✓0" ]
}

@test "sl-autopilot-fields prints ap:[i] when on and idle or capped" {
  local repo outcome
  repo=$(_make_repo repo-ap-idle)
  for outcome in idle capped; do
    _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", \"stuck_count\": 0, \"cycle_count\": 4, \"last_outcome\": \"$outcome\"}"
    run _ap_line "$repo"
    [ "$output" = "ap:[i] 2hr loops 4 ✓0" ]
  done
}

@test "sl-autopilot-fields prints ap:[p] frozen at paused_at when paused" {
  local repo
  repo=$(_make_repo repo-ap-paused)
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"paused\", \"started_at\": \"$(_ap_ago 240)\", \"paused_at\": \"$(_ap_ago 180)\", \"stuck_count\": 0, \"cycle_count\": 2}"
  run _ap_line "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[p] 1hr loops 2 ✓0" ]
}

@test "sl-autopilot-fields prints nothing for a paused file with no paused_at" {
  local repo
  repo=$(_make_repo repo-ap-paused-bad)
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"paused\", \"started_at\": \"$(_ap_ago 240)\", \"stuck_count\": 0, \"cycle_count\": 2}"
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ -z "$output" ]
}

@test "sl-iso-to-epoch returns empty for empty input (GNU date -d \"\" is midnight today)" {
  run bash -c "source '$SCRIPT'; sl-iso-to-epoch ''"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-fields prints nothing for paused with no paused_at, even right after UTC midnight" {
  local repo
  repo=$(_make_repo repo-ap-paused-bad-midnight)
  # started_at is always before today 00:00 UTC regardless of the wall clock.
  _ap_state "$repo" '{"schema": 2, "status": "paused", "started_at": "2000-01-01T00:00:00Z", "stuck_count": 0, "cycle_count": 2}'
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ -z "$output" ]
}

@test "sl-autopilot-fields prints nothing when the JSON is malformed" {
  local repo
  repo=$(_make_repo repo-ap-malformed)
  _ap_state "$repo" '{not valid json'
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-fields prints nothing when started_at is in the future (clock skew)" {
  local repo started_at
  repo=$(_make_repo repo-ap-future-start)
  started_at=$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes' +%Y-%m-%dT%H:%M:%SZ)
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$started_at\", \"stuck_count\": 0, \"cycle_count\": 1}"
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ -z "$output" ]
}

@test "sl-autopilot-fields prints nothing when a counter is missing, negative or non-numeric" {
  local repo body
  repo=$(_make_repo repo-ap-bad-counts)
  for body in '"stuck_count": 1' '"stuck_count": -5, "cycle_count": 3' '"stuck_count": 1, "cycle_count": "abc"'; do
    _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", $body}"
    run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "sl-autopilot-fields: 12th field is next_wake_at as epoch, empty when absent" {
  local repo; repo=$(_make_repo repo-ap-wake)
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", \"stuck_count\": 0, \"cycle_count\": 1, \"next_wake_at\": \"2026-10-28T12:12:00Z\"}"
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ "$(awk -F$'\x1f' '{print $12}' <<<"$output")" = "1793189520" ] || [ "$(awk -F$'\x1f' '{print $12}' <<<"$output")" = "$(date -u -d 2026-10-28T12:12:00Z +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-10-28T12:12:00Z +%s)" ]
  _ap_state "$repo" "{\"schema\": 2, \"status\": \"on\", \"started_at\": \"$(_ap_ago 90)\", \"stuck_count\": 0, \"cycle_count\": 1, \"next_wake_at\": null}"
  run bash -c "source '$SCRIPT'; sl-autopilot-fields '$repo'"
  [ -z "$(awk -F$'\x1f' '{print $12}' <<<"$output")" ]
}

# --- sl-queue-json: the queue breakdown (every queued task in exactly one bucket) ---

# _task <repo> <n> <status> [extra frontmatter line] [title]: dev/TODO/T20260101-00000<n>-t.md
_task() {
  local f="$1/dev/TODO/T20260101-$(printf %06d "$2")-t.md"
  { printf -- '---\nstatus: %s\nestimation: 1\n' "$3"; [ -z "${4:-}" ] || printf '%s\n' "$4"; printf -- '---\n\n# T20260101-%s: %s\n' "$(printf %06d "$2")" "${5:-Plain task}"; } > "$f"
}
_qline() { printf -- '- [T20260101-%06d](T20260101-%06d-t.md): task %s\n' "$1" "$1" "$1" >> "$2/dev/TODO/queue.md"; }

_queue_fixture() {
  local repo; repo=$(_make_repo "$1")
  printf '# TODO Queue\n\nprose line\n\n' > "$repo/dev/TODO/queue.md"
  _task "$repo" 1 Open                                   # ready
  _task "$repo" 2 "Blocked by T20260101-000003 — wait"   # blocked (blocker still open)
  _task "$repo" 3 Open                                   # ready
  _task "$repo" 4 "Blocked by T20260101-999999"          # blocker gone: ready
  _task "$repo" 5 "In Progress — SUPERVISED (needs VPN)" # blocked
  _task "$repo" 6 "Open — waiting on HashData review"    # external
  _task "$repo" 7 "Open — needs owner decision"          # decision
  _task "$repo" 8 Open "" "Umbrella: the big thing"      # epic
  _task "$repo" 9 Open "claimed_by: other-box:/x"        # claimed
  _task "$repo" 10 Open "claimed_by: $(_clone_id "$repo")"  # ours: ready
  _task "$repo" 11 Open                                  # skip kind external
  _task "$repo" 12 Open                                  # skip, no kind: decision
  _task "$repo" 14 "BLOCKED on infra" "" "Epic: tracking"  # epic beats blocked
  _task "$repo" 15 Open "children: [T20260101-000001]"   # epic by structure
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do _qline "$i" "$repo"; done   # 13 has no file
  printf -- '- ~~[T20260101-000020](T20260101-000020-t.md)~~: closed\n' >> "$repo/dev/TODO/queue.md"
  printf '%s' "$repo"
}

@test "sl-queue-json: no queue.md prints nothing" {
  local repo; repo=$(_make_repo q-none)
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "sl-queue-json: frontmatter rules, claim handling, struck lines ignored, buckets sum to total" {
  local repo; repo=$(_queue_fixture q-fm)
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"total":15,"ready":7,"blocked":2,"decision":1,"external":1,"epic":3,"claimed":1}' ] || { echo "$output"; false; }
  [ "$(jq '.ready + .blocked + .decision + .external + .epic + .claimed - .total' <<<"$output")" = 0 ]
}

@test "sl-queue-json: autopilot kind wins, a skip with no kind is a decision, off/legacy state is ignored" {
  local repo; repo=$(_queue_fixture q-ap)
  local own; own=$(_clone_id "$repo")
  printf '{"schema":2,"status":"on","skip_ids":["T20260101-000011","T20260101-000012","T20260101-000001"],"needs_attention":[{"id":"T20260101-000011","reason":"r","kind":"external"},{"id":"T20260101-000001","reason":"r","kind":"decision"}],"dispatch_clone_path":null}' > "$repo/dev/.autopilot-state.json"
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$(jq -c '[.total,.ready,.blocked,.decision,.external,.epic,.claimed]' <<<"$output")" = '[15,4,2,3,2,3,1]' ] || { echo "$output"; false; }
  printf '{"schema":2,"status":"off","skip_ids":["T20260101-000012"],"needs_attention":[]}' > "$repo/dev/.autopilot-state.json"
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$(jq -r .ready <<<"$output")" = 7 ]
  printf 'not json' > "$repo/dev/.autopilot-state.json"
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$(jq -r .total <<<"$output")" = 15 ]
}

@test "sl-queue-json: a released claim (null), UNBLOCKED and the dispatch clone's claim are not misfiled" {
  local repo; repo=$(_make_repo q-edge)
  local ap="$BATS_TEST_TMPDIR/ap-clone"; mkdir -p "$ap"; git -C "$ap" init -q
  printf '# Q\n' > "$repo/dev/TODO/queue.md"
  _task "$repo" 1 Open "claimed_by: null"
  _task "$repo" 2 "In Progress — UNBLOCKED now"
  _task "$repo" 3 Open "claimed_by: $(_clone_id "$ap")"
  _task "$repo" 4 Open
  local i; for i in 1 2 3 4; do _qline "$i" "$repo"; done
  printf '{"schema":2,"status":"paused","skip_ids":[],"needs_attention":[{"id":"T20260101-000004","reason":"r","kind":"blocked"}],"dispatch_clone_path":"%s"}' "$ap" > "$repo/dev/.autopilot-state.json"
  run bash -c "source '$SCRIPT'; sl-queue-json '$repo'"
  [ "$output" = '{"total":4,"ready":3,"blocked":1,"decision":0,"external":0,"epic":0,"claimed":0}' ] || { echo "$output"; false; }
}
