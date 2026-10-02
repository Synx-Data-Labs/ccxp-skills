#!/usr/bin/env bats
# Tests for statusline-setup/scripts/statusline-command.sh — the Claude Code
# statusLine command that surfaces the task claimed by the calling clone plus
# the remaining context-window percentage.
#
# Helper functions are sourced and tested directly (function-wrapped, see the
# BASH_SOURCE guard at the bottom of the script — same pattern as
# quality-probe/scripts/probe.sh). The stdin entrypoint statusline-command is
# tested end-to-end by piping a synthetic hook-input JSON payload.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/statusline-setup/scripts/statusline-command.sh"

setup() {
  # The machine-id/secret cache lives under ~/.claude/state by default; tests
  # must neither read the developer's real identity nor write to their home.
  export CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/claimant-state"
  # Same isolation for the last-user-input cache (T20260924-366770).
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
}

_load() { source "$SCRIPT"; }

# The clone-id for a path, computed exactly the way production computes it.
# Fixtures MUST go through this rather than hardcoding a format: hardcoding is
# what let the old suite stay green while the statusline silently matched
# nothing (T20260911-698434).
_clone_id() { bash -c "source '$SCRIPT'; sl-clone-id '$1'"; }

# Build a throwaway git repo with a dev/TODO dir under $BATS_TEST_TMPDIR and
# print its path. Args: $1 = subdir name.
_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/dev/TODO"
  git -C "$dir" init -q
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Sourceable / structure
# ---------------------------------------------------------------------------

@test "statusline-command.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "statusline-command.sh is sourceable without executing its main (function-wrapped)" {
  run bash -c "source '$SCRIPT'; type statusline-command >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
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
# sl-join
# ---------------------------------------------------------------------------

@test "sl-join joins non-empty parts with ' | '" {
  run bash -c "source '$SCRIPT'; sl-join 'a' 'b'"
  [ "$status" -eq 0 ]
  [ "$output" = "a | b" ]
}

@test "sl-join skips empty parts" {
  run bash -c "source '$SCRIPT'; sl-join '' 'b' ''"
  [ "$status" -eq 0 ]
  [ "$output" = "b" ]
}

@test "sl-join returns empty string when all parts are empty" {
  run bash -c "source '$SCRIPT'; sl-join '' ''"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-last-input-part
# ---------------------------------------------------------------------------

@test "sl-last-input-part prints nothing when session_id is empty" {
  run bash -c "source '$SCRIPT'; sl-last-input-part '$BATS_TEST_TMPDIR/li' ''"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-last-input-part prints nothing when no cache file exists for this session" {
  run bash -c "source '$SCRIPT'; sl-last-input-part '$BATS_TEST_TMPDIR/li-missing' 'sess-1'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-last-input-part prints 'last: <text>' when a cache file exists" {
  mkdir -p "$BATS_TEST_TMPDIR/li"
  printf '%s' 'fix the thing' > "$BATS_TEST_TMPDIR/li/sess-1"
  run bash -c "source '$SCRIPT'; sl-last-input-part '$BATS_TEST_TMPDIR/li' 'sess-1'"
  [ "$status" -eq 0 ]
  [ "$output" = "last: fix the thing" ]
}

@test "sl-last-input-part prints nothing when the cache file is empty" {
  mkdir -p "$BATS_TEST_TMPDIR/li"
  : > "$BATS_TEST_TMPDIR/li/sess-1"
  run bash -c "source '$SCRIPT'; sl-last-input-part '$BATS_TEST_TMPDIR/li' 'sess-1'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# statusline-command (full stdin -> stdout pipeline)
# ---------------------------------------------------------------------------

@test "statusline-command reports no claimed task and the given context percentage" {
  local repo branch
  repo=$(_make_repo repo6)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":42}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 42% left | branch: $branch | no claimed task" ]
}

@test "statusline-command reports the claimed task label when claimed_by matches" {
  local repo clone_id branch
  repo=$(_make_repo repo7)
  # statusline-command resolves cwd to git's realpath toplevel internally
  # (see the macOS /var->/private/var note above), so build clone_id from
  # that same resolved path rather than the raw $repo.
  clone_id="$(_clone_id "$(git -C "$repo" rev-parse --show-toplevel)")"
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
# T20260427-242654: Fix the thing
EOF
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":80}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 80% left | branch: $branch | TASK: T20260427-242654: Fix the thing" ]
}

@test "statusline-command defaults remaining_percentage to 100 when absent" {
  local repo branch
  repo=$(_make_repo repo8)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\"}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 100% left | branch: $branch | no claimed task" ]
}

@test "statusline-command falls back to PWD when cwd is absent from the payload" {
  local repo branch
  repo=$(_make_repo repo9)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "cd '$repo' && echo '{}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 100% left | branch: $branch | no claimed task" ]
}

@test "statusline-command appends the last-input segment when a cache file exists for session_id" {
  local repo branch
  repo=$(_make_repo repo10)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf '%s' 'fix the thing' > "$LAST_INPUT_STATE_DIR/sess-xyz"
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":55},\"session_id\":\"sess-xyz\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 55% left | branch: $branch | no claimed task | last: fix the thing" ]
}

@test "statusline-command omits the last-input segment when no cache file exists for session_id" {
  local repo branch
  repo=$(_make_repo repo11)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":55},\"session_id\":\"sess-never-wrote\"}' | LAST_INPUT_STATE_DIR='$LAST_INPUT_STATE_DIR' '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 55% left | branch: $branch | no claimed task" ]
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
# sl-autopilot-part
# ---------------------------------------------------------------------------

@test "sl-autopilot-part prints nothing when the state file doesn't exist" {
  local repo
  repo=$(_make_repo repo-ap-absent)
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints ap:[s] with elapsed from last_cycle_at when stopped" {
  local repo
  repo=$(_make_repo repo-ap-stopped)
  mkdir -p "$repo/dev"
  # last_cycle_at is 2hr after started_at — elapsed must come from that, not
  # from "now" (the run is long over; "now" would give a bogus huge elapsed).
  cat > "$repo/dev/.autopilot-state.json" <<'EOF'
{"status": "stopped", "started_at": "2026-01-01T00:00:00Z", "end_time": "2026-01-01T05:00:00Z", "stuck_count": 1, "cycle_count": 3, "last_outcome": "stuck", "last_cycle_at": "2026-01-01T02:00:00Z"}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[s] 2/5hr 1/3" ]
}

@test "sl-autopilot-part prints ap:[s] with elapsed 0 when stopped and last_cycle_at is null" {
  local repo
  repo=$(_make_repo repo-ap-stopped-no-cycle)
  mkdir -p "$repo/dev"
  cat > "$repo/dev/.autopilot-state.json" <<'EOF'
{"status": "stopped", "started_at": "2026-01-01T00:00:00Z", "end_time": "2026-01-01T05:00:00Z", "stuck_count": 0, "cycle_count": 0, "last_outcome": null, "last_cycle_at": null}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[s] 0/5hr 0/0" ]
}

@test "sl-autopilot-part prints ap:[r] <elapsed>/<requested>hr <stuck>/<cycle> when running normally" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-running)
  mkdir -p "$repo/dev"
  # Real wall-clock offsets, not mocked time — 90 minutes ago rounds to 2hr
  # elapsed (awk %.0f rounds, doesn't truncate); requested window is a fixed
  # 5 real hours from started_at.
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": 3, "cycle_count": 10}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[r] 2/5hr 3/10" ]
}

@test "sl-autopilot-part prints ap:[b] when running and last_outcome is stuck" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-backing-off)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": 2, "cycle_count": 4, "last_outcome": "stuck"}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[b] 2/5hr 2/4" ]
}

@test "sl-autopilot-part prints nothing when the JSON is malformed" {
  local repo
  repo=$(_make_repo repo-ap-malformed)
  mkdir -p "$repo/dev"
  printf '{not valid json' > "$repo/dev/.autopilot-state.json"
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints nothing when end_time is before started_at" {
  local repo
  repo=$(_make_repo repo-ap-backwards)
  mkdir -p "$repo/dev"
  cat > "$repo/dev/.autopilot-state.json" <<'EOF'
{"status": "running", "started_at": "2026-01-01T05:00:00Z", "end_time": "2026-01-01T00:00:00Z", "stuck_count": 0, "cycle_count": 1}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# statusline-command wiring (ap_part first)
# ---------------------------------------------------------------------------

@test "statusline-command prepends ap: before ctx: when autopilot is running" {
  local repo branch started_at end_time
  repo=$(_make_repo repo-ap-e2e-running)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": 3, "cycle_count": 10}
EOF
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":42}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ap:[r] 2/5hr 3/10 | ctx: 42% left | branch: $branch | no claimed task" ]
}

@test "statusline-command output is unchanged when autopilot state file is absent" {
  local repo branch
  repo=$(_make_repo repo-ap-e2e-absent)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":42}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 42% left | branch: $branch | no claimed task" ]
}

@test "sl-autopilot-part prints nothing when started_at is in the future (clock skew)" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-future-start)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": 0, "cycle_count": 1}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints nothing when stuck_count/cycle_count are missing" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-null-counts)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time"}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints nothing when stuck_count is negative" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-negative-count)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": -5, "cycle_count": 3}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints nothing when stuck_count is negative and status is stopped" {
  local repo
  repo=$(_make_repo repo-ap-negative-count-stopped)
  mkdir -p "$repo/dev"
  cat > "$repo/dev/.autopilot-state.json" <<'EOF'
{"status": "stopped", "started_at": "2026-01-01T00:00:00Z", "end_time": "2026-01-01T05:00:00Z", "stuck_count": -5, "cycle_count": 3}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-autopilot-part prints nothing when cycle_count is non-numeric" {
  local repo started_at end_time
  repo=$(_make_repo repo-ap-nonnumeric-count)
  mkdir -p "$repo/dev"
  started_at=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -v-90M -v+5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago + 5 hours' +%Y-%m-%dT%H:%M:%SZ)
  cat > "$repo/dev/.autopilot-state.json" <<EOF
{"status": "running", "started_at": "$started_at", "end_time": "$end_time", "stuck_count": 1, "cycle_count": "abc"}
EOF
  run bash -c "source '$SCRIPT'; sl-autopilot-part '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
