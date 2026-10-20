#!/usr/bin/env bats
# Tests for agent-pairing/scripts/agent-pairing.sh -- toggles the "ccxp-agent"
# main-session agent persona as a Claude Code profile's default, via a
# key-level jq edit of settings.json (never a text replace -- that file also
# carries hooks/permissions/plugin config that must survive untouched).

load test_helper
setup() {
  SCRIPT="$REPO_ROOT/agent-pairing/scripts/agent-pairing.sh"
  CLAUDE_DIR="$BATS_TEST_TMPDIR/claude-home"
  mkdir -p "$CLAUDE_DIR"
}

mk_settings() {
  # Mirrors a real settings.json's shape: nested objects, an array, unrelated
  # top-level keys -- proves the jq edit preserves everything but `.agent`.
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "model": "sonnet",
  "theme": "dark",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "command": "/some/hook", "type": "command" } ] }
    ]
  },
  "permissions": {
    "allow": ["Read(~/.claude/**)"],
    "defaultMode": "auto"
  }
}
EOF
}

mk_settings_with_agent() {
  local agent="$1"
  cat > "$CLAUDE_DIR/settings.json" <<EOF
{
  "model": "sonnet",
  "agent": "$agent",
  "theme": "dark"
}
EOF
}

@test "on: installs ccxp-agent.md and sets agent=ccxp-agent, preserving unrelated keys" {
  mk_settings
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_DIR/agents/ccxp-agent.md" ]
  cmp -s "$CLAUDE_DIR/agents/ccxp-agent.md" "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "ccxp-agent" ]
  [ "$(jq -r '.model' "$CLAUDE_DIR/settings.json")" = "sonnet" ]
  [ "$(jq -r '.theme' "$CLAUDE_DIR/settings.json")" = "dark" ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_DIR/settings.json")" = "/some/hook" ]
  [ "$(jq -r '.permissions.defaultMode' "$CLAUDE_DIR/settings.json")" = "auto" ]
}

@test "on: reports takes-effect-next-session wording, not an immediate-effect claim" {
  mk_settings
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "next session"
}

@test "on: idempotent re-entry when already on reports already-ON, settings unchanged" {
  mk_settings_with_agent ccxp-agent
  mkdir -p "$CLAUDE_DIR/agents"
  cp "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md" "$CLAUDE_DIR/agents/ccxp-agent.md"
  before="$(cat "$CLAUDE_DIR/settings.json")"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already"
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "$before" ]
}

@test "on: a pre-existing hand-edited ccxp-agent.md is never overwritten, but agent still flips" {
  mk_settings
  mkdir -p "$CLAUDE_DIR/agents"
  echo "custom hand-edited content" > "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")" = "custom hand-edited content" ]
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "ccxp-agent" ]
}

@test "off: removes the agent key, preserves unrelated keys, leaves ccxp-agent.md installed" {
  mk_settings_with_agent ccxp-agent
  mkdir -p "$CLAUDE_DIR/agents"
  cp "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md" "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" off --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("agent")' "$CLAUDE_DIR/settings.json")" = "false" ]
  [ "$(jq -r '.model' "$CLAUDE_DIR/settings.json")" = "sonnet" ]
  [ -f "$CLAUDE_DIR/agents/ccxp-agent.md" ]
}

@test "off: idempotent re-entry when already off (no agent key) reports already-OFF" {
  mk_settings
  run bash "$SCRIPT" off --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "already"
  [ "$(jq -r 'has("agent")' "$CLAUDE_DIR/settings.json")" = "false" ]
}

@test "off: a different custom agent is left alone, not deleted" {
  mk_settings_with_agent "some-other-agent"
  run bash "$SCRIPT" off --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "some-other-agent" ]
}

@test "status: reports ON when agent=ccxp-agent" {
  mk_settings_with_agent ccxp-agent
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ON"
}

@test "status: reports OFF when no agent key set" {
  mk_settings
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OFF"
}

@test "status: reports OFF and names the other agent when a different one is set" {
  mk_settings_with_agent "some-other-agent"
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OFF"
  echo "$output" | grep -q "some-other-agent"
}

@test "on: preserves settings.json's original permission bits across the rewrite" {
  mk_settings
  chmod 644 "$CLAUDE_DIR/settings.json"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  perm="$(stat -c '%a' "$CLAUDE_DIR/settings.json" 2>/dev/null || stat -f '%Lp' "$CLAUDE_DIR/settings.json")"
  [ "$perm" = "644" ]
}

@test "invalid JSON in settings.json is a hard error, nothing is touched" {
  echo "not valid json" > "$CLAUDE_DIR/settings.json"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -ne 0 ]
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "not valid json" ]
}

@test "on: a write failure is reported as an error, never printed as ON" {
  mk_settings
  # Make the directory read-only so mktemp inside it fails -- simulates any
  # write-time failure without depending on jq's own exit-code behavior.
  chmod 555 "$CLAUDE_DIR"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  chmod 755 "$CLAUDE_DIR"
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q "ON --"
}

@test "missing settings.json is a hard error for on/off/status" {
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -ne 0 ]
}

@test "missing action argument is a usage error" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "invalid action argument is a usage error" {
  run bash "$SCRIPT" bogus --claude-dir "$CLAUDE_DIR"
  [ "$status" -ne 0 ]
}

@test "asset: ccxp-agent tools include Skill and ScheduleWakeup, and the /autopilot exception exists" {
  grep -E '^tools:.*\bSkill\b.*\bScheduleWakeup\b' "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q 'Exception: `/autopilot`' "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
}

@test "asset: name frontmatter is ccxp-agent, not the old dispatcher name" {
  [ "$(grep -m1 '^name:' "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md")" = "name: ccxp-agent" ]
}

@test "asset: mandates worktree isolation for repo-changing jobs as a hard rule" {
  grep -q 'Repo-changing jobs MUST be dispatched with `isolation: "worktree"`' "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -qi 'never a per-job judgment call' "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
}

@test "status: calls out a stale pre-rename agent=dispatcher distinctly from an unrelated custom agent" {
  mk_settings_with_agent dispatcher
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "stale"
  echo "$output" | grep -qi "ccxp-agent"
}

@test "on: a pre-existing legacy dispatcher.md is reported as stale, never touched or auto-migrated" {
  mk_settings_with_agent dispatcher
  mkdir -p "$CLAUDE_DIR/agents"
  echo "old dispatcher content" > "$CLAUDE_DIR/agents/dispatcher.md"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/agents/dispatcher.md")" = "old dispatcher content" ]
  [ -f "$CLAUDE_DIR/agents/ccxp-agent.md" ]
  echo "$output" | grep -qi "dispatcher.*stale\|stale.*dispatcher\|unused"
  # The old "dispatcher" value no longer matches the managed name, so `on`
  # flips it forward to ccxp-agent rather than treating it as already-on.
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "ccxp-agent" ]
}
