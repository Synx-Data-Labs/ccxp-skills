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

@test "asset: every job prompt starts with a repo context block that makes the job read the target CLAUDE.md" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '^## Repo context per job' "$f"
  grep -q 'Resolve the repo before dispatch' "$f"
  grep -q 'Repo: <owner/repo>' "$f"
  grep -q 'Path: <abs path>' "$f"
  grep -q 'Before anything else, Read <path>/CLAUDE.md' "$f"
  grep -q 'If the CLAUDE.md is missing, say so in your report' "$f"
  grep -q 'ask one question instead of guessing' "$f"
  grep -q 'gh auth status' "$f"
}

@test "asset: dispatcher stays light, other-repo jobs make their own worktree, multi-repo and skill jobs covered" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q 'Do not Read the CLAUDE.md into your own context' "$f"
  grep -q 'git -C <clone> worktree add' "$f"
  grep -q 'Never write in the shared clone' "$f"
  grep -q 'Skill-driven jobs' "$f"
  grep -q 'one job per repo' "$f"
  # the existing hard rule must survive the new section
  grep -q 'Repo-changing jobs MUST be dispatched with `isolation: "worktree"`' "$f"
}

@test "asset: ledger row records the repo and the job prompt section points at the block" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '#n \[HH:MM\] <repo>: <short title>' "$f"
  grep -q 'repo context block (see "Repo context per job")' "$f"
}

@test "asset: HUD job ledger section has the start/finish lines every job prompt must carry" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '^## HUD job ledger' "$f"
  grep -q 'hud/scripts/ledger.sh"; bash "\$L" start <n> "<title>"' "$f"
  grep -q 'bash "\$L" finish <n>' "$f"
  grep -q 'As your very first action, before reading CLAUDE.md' "$f"
  grep -q 'As your very last action' "$f"
  grep -q 'The two HUD ledger lines (see "HUD job ledger")' "$f"
  grep -q '`#<n> <title>`' "$f"
}

@test "asset: ledger carve-out is limited to the ledger.sh subcommands and Bash stays otherwise read-only" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q 'Job died early' "$f"
  grep -q 'no follow-up job' "$f"
  grep -q 'bash "\$L" park <n>' "$f"
  grep -q '`unpark <n>`' "$f"
  grep -q 'only `finish`, `park`, `unpark`, `next`, `ref` and `show`' "$f"
  grep -q 'Bash is read-only only' "$f"
}

@test "asset: reply format is one Next: section with n refs, no Needs input / Needs your action" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '^- \*\*Next:\*\*' "$f"
  grep -q 'Section order: Next, Running, Parked' "$f"
  grep -q '`n<n>` item under Next' "$f"
  grep -q 'bash "\$L" next add' "$f"
  grep -q 'ref bump n22' "$f"
  run grep -q 'Needs your action' "$f"; [ "$status" -ne 0 ]
  run grep -q '\*\*Needs input\*\*' "$f"; [ "$status" -ne 0 ]
}

@test "asset: the ledger lines in the asset actually work against ledger.sh" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  L="$REPO_ROOT/hud/scripts/ledger.sh"
  bash "$L" start 7 "Fix the thing"
  [ "$(jq -r '.running[0].job' "$CCXP_LEDGER_FILE")" = "7" ]
  bash "$L" park 2
  [ "$(jq -r '.parked' "$CCXP_LEDGER_FILE")" = "1" ]
  bash "$L" unpark k2
  bash "$L" finish 7
  bash "$L" finish 7
  [ "$(jq -r '.running | length' "$CCXP_LEDGER_FILE")" = "0" ]
  [ "$(jq -r '.lifetime_jobs' "$CCXP_LEDGER_FILE")" = "7" ]
  [ "$(jq -r '.parked' "$CCXP_LEDGER_FILE")" = "0" ]
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

# --- update: refresh the agent definition + managed settings ----------------

ASSET_FILE() { echo "$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"; }

install_outdated_agent() {
  # An older definition: the bundled asset minus its "Detached jobs" section,
  # plus a local edit marker so a diff has both removed and added lines.
  mkdir -p "$CLAUDE_DIR/agents"
  grep -v 'Detached jobs' "$(ASSET_FILE)" > "$CLAUDE_DIR/agents/ccxp-agent.md"
  echo "my local note" >> "$CLAUDE_DIR/agents/ccxp-agent.md"
}

@test "update: identical agent file is a no-op (reports up to date, no backups)" {
  mk_settings_with_agent ccxp-agent
  mkdir -p "$CLAUDE_DIR/agents"
  cp "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  before="$(cat "$CLAUDE_DIR/settings.json")"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "up to date"
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "$before" ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  [ -z "$(ls "$CLAUDE_DIR/agents" | grep '\.bak-' || true)" ]
  [ -z "$(ls "$CLAUDE_DIR" | grep '\.bak-' || true)" ]
}

@test "update: outdated file is backed up then replaced by default, with a summary" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  old="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  set -- "$CLAUDE_DIR"/agents/ccxp-agent.md.bak-*
  [ "$#" -eq 1 ]
  [[ "$1" =~ ccxp-agent\.md\.bak-[0-9]{8}-[0-9]{6}$ ]]
  [ "$(cat "$1")" = "$old" ]
  echo "$output" | grep -q "UPDATED"
  echo "$output" | grep -Eq '\+[0-9]+ -[0-9]+ lines'
  echo "$output" | grep -q "kept at $1"
  echo "$output" | grep -qi "next session"
}

@test "update --dry-run / -n: prints the diff, writes nothing" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  for flag in --dry-run -n; do
    run bash "$SCRIPT" update "$flag" --claude-dir "$CLAUDE_DIR"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OUTDATED"
    echo "$output" | grep -q "^+## Detached jobs"
    echo "$output" | grep -q "^-my local note"
    echo "$output" | grep -q "dry run"
    [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")" = "$before" ]
    [ -z "$(ls "$CLAUDE_DIR/agents" | grep '\.bak-' || true)" ]
  done
}

@test "update --dry-run: settings.json is not written or backed up either" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/settings.json")"
  run bash "$SCRIPT" update --dry-run --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "$before" ]
  [ -z "$(ls "$CLAUDE_DIR" | grep '\.bak-' || true)" ]
}

@test "update --yes: still accepted as a harmless no-op (same result as plain update)" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  set -- "$CLAUDE_DIR"/agents/ccxp-agent.md.bak-*
  [ "$#" -eq 1 ]
}

@test "update: a same-second backup collision gets a numeric suffix, earlier backup kept" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  # Pin `date` so both runs compute the same timestamp deterministically.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho 20261025-120000\n' > "$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
  old1="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  echo "second edit" >> "$CLAUDE_DIR/agents/ccxp-agent.md"
  old2="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md.bak-20261025-120000")" = "$old1" ]
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md.bak-20261025-120000-1")" = "$old2" ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
}

@test "update: no settings backup when settings.json needs no change" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/settings.json")"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "$before" ]
  [ -z "$(ls "$CLAUDE_DIR" | grep 'settings\.json\.bak-' || true)" ]
}

@test "update: settings re-assert is a no-op safety net (already ccxp-agent: nothing to change, no backup)" {
  # `.agent` is the only managed key and is only re-asserted when it already
  # equals ccxp-agent, so today the re-assert can never change the file; if it
  # ever did, update_settings backs up before writing (same backup_path code).
  mk_settings_with_agent ccxp-agent
  mkdir -p "$CLAUDE_DIR/agents"
  cp "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "settings.json: nothing to change (mode ON)"
  [ -z "$(ls "$CLAUDE_DIR" | grep 'settings\.json\.bak-' || true)" ]
}

@test "update: a hand-edited file is backed up before replacement (backup == previous file)" {
  mk_settings
  mkdir -p "$CLAUDE_DIR/agents"
  echo "custom hand-edited content" > "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  set -- "$CLAUDE_DIR"/agents/ccxp-agent.md.bak-*
  [ "$#" -eq 1 ]
  [ "$(cat "$1")" = "custom hand-edited content" ]
  # ...but `on` still never overwrites a hand-edited file.
  echo "custom again" > "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" on --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")" = "custom again" ]
}

@test "update: a profile that is OFF stays OFF (settings byte-identical, def refreshed)" {
  mk_settings
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/settings.json")"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_DIR/settings.json")" = "$before" ]
  [ "$(jq -r 'has("agent")' "$CLAUDE_DIR/settings.json")" = "false" ]
  cmp -s "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
}

@test "update: a different custom agent default is left alone" {
  mk_settings_with_agent "some-other-agent"
  install_outdated_agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "some-other-agent" ]
}

@test "update: a stale agent=dispatcher is reported, not migrated (update never changes on/off)" {
  mk_settings_with_agent dispatcher
  install_outdated_agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "dispatcher" ]
  echo "$output" | grep -q "stale agent"
}

@test "update: a profile that is ON stays ON" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agent' "$CLAUDE_DIR/settings.json")" = "ccxp-agent" ]
}

@test "update: unrelated settings keys are preserved exactly (jq -S comparison)" {
  mk_settings
  jq '. + {agent: "ccxp-agent"}' "$CLAUDE_DIR/settings.json" > "$BATS_TEST_TMPDIR/s.json"
  mv "$BATS_TEST_TMPDIR/s.json" "$CLAUDE_DIR/settings.json"
  jq -S . "$CLAUDE_DIR/settings.json" > "$BATS_TEST_TMPDIR/before.json"
  install_outdated_agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  jq -S . "$CLAUDE_DIR/settings.json" > "$BATS_TEST_TMPDIR/after.json"
  cmp -s "$BATS_TEST_TMPDIR/before.json" "$BATS_TEST_TMPDIR/after.json"
}

@test "update: missing agent definition is reported and not installed (that is 'on')" {
  mk_settings_with_agent ccxp-agent
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "not installed"
  [ ! -e "$CLAUDE_DIR/agents/ccxp-agent.md" ]
}

@test "update: reports unmanaged dependencies instead of editing them" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  echo "old dispatcher" > "$CLAUDE_DIR/agents/dispatcher.md"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no ccxp-skills plugin install"
  echo "$output" | grep -q "dispatcher.md"
  [ "$(cat "$CLAUDE_DIR/agents/dispatcher.md")" = "old dispatcher" ]
}

@test "update: --yes / --dry-run are rejected for the other actions" {
  mk_settings
  for flag in --yes --dry-run -n; do
    run bash "$SCRIPT" on "$flag" --claude-dir "$CLAUDE_DIR"
    [ "$status" -eq 64 ]
    [ ! -e "$CLAUDE_DIR/agents/ccxp-agent.md" ]
  done
}

@test "update: invalid settings.json is a hard error, nothing touched" {
  echo "not valid json" > "$CLAUDE_DIR/settings.json"
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  run bash "$SCRIPT" update --claude-dir "$CLAUDE_DIR"
  [ "$status" -ne 0 ]
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")" = "$before" ]
}

@test "status: reports the agent definition as up to date when identical to the bundled one" {
  mk_settings_with_agent ccxp-agent
  mkdir -p "$CLAUDE_DIR/agents"
  cp "$(ASSET_FILE)" "$CLAUDE_DIR/agents/ccxp-agent.md"
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "agent definition: up to date"
}

@test "status: reports OUTDATED when the installed definition differs, and changes nothing" {
  mk_settings_with_agent ccxp-agent
  install_outdated_agent
  before="$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")"
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "OUTDATED -- run update"
  [ "$(cat "$CLAUDE_DIR/agents/ccxp-agent.md")" = "$before" ]
}

@test "status: reports the definition as not installed when absent" {
  mk_settings
  run bash "$SCRIPT" status --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "agent definition: not installed"
}
