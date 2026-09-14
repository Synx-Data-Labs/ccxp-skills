#!/usr/bin/env bats
# Tests for scripts/install.sh --wire-hooks (_ccxp_wire_session_hook) — merges
# the _gh/auto-switch.sh SessionStart hook into settings.json.
#
# Black-box via subprocess (`run bash scripts/install.sh ...`), not sourcing:
# install.sh has full `set -euo pipefail` (unlike _gh/gh.sh, it was never
# designed to be sourced), so exercising it as a real user would invoke it is
# both simpler and closer to what actually ships. Each test gets its own
# throwaway config dir (skills/ + settings.json) under $BATS_TEST_TMPDIR so
# runs never touch a real ~/.claude.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CFG="$BATS_TEST_TMPDIR/config"
  mkdir -p "$CFG/skills"
}

# --- fresh wire / dry-run -----------------------------------------------------

@test "fresh wire creates settings.json and adds the SessionStart hook" {
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks
  [ "$status" -eq 0 ]
  [ -f "$CFG/settings.json" ]
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$CFG/settings.json"
  [ "$output" = "bash $CFG/skills/_gh/auto-switch.sh" ]
}

@test "dry-run does not create settings.json" {
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$CFG/settings.json" ]
}

# --- idempotency ---------------------------------------------------------------

@test "re-running wire-hooks is idempotent (no duplicate hook entry)" {
  bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks >/dev/null
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"already wires"* ]]
  run jq '[.hooks.SessionStart[].hooks[]] | length' "$CFG/settings.json"
  [ "$output" = "1" ]
}

@test "a pre-existing ~-spelled hook (under \$HOME) is recognized, not duplicated" {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME/skills"
  printf '{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "bash ~/skills/_gh/auto-switch.sh" } ] } ] } }' \
    > "$FAKE_HOME/settings.json"
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/install.sh" --target "$FAKE_HOME/skills" --wire-hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"already wires"* ]]
}

# --- non-destructive merge ------------------------------------------------------

@test "wiring preserves an unrelated existing SessionStart hook" {
  printf '{ "model": "sonnet", "hooks": { "SessionStart": [ { "matcher": "resume", "hooks": [ { "type": "command", "command": "echo keep-me" } ] } ] } }' \
    > "$CFG/settings.json"
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks
  [ "$status" -eq 0 ]
  run jq -r '.model' "$CFG/settings.json"
  [ "$output" = "sonnet" ]
  run jq -r '.hooks.SessionStart[] | select(.matcher=="resume") | .hooks[0].command' "$CFG/settings.json"
  [ "$output" = "echo keep-me" ]
  run jq '[.hooks.SessionStart[].hooks[]] | length' "$CFG/settings.json"
  [ "$output" = "2" ]
}

# --- symlink safety --------------------------------------------------------------

@test "settings.json that is itself a symlink stays a symlink after write" {
  mkdir -p "$BATS_TEST_TMPDIR/dotfiles"
  printf '{}' > "$BATS_TEST_TMPDIR/dotfiles/settings.json"
  ln -s "$BATS_TEST_TMPDIR/dotfiles/settings.json" "$CFG/settings.json"
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks
  [ "$status" -eq 0 ]
  [ -L "$CFG/settings.json" ]
  [ "$(readlink "$CFG/settings.json")" = "$BATS_TEST_TMPDIR/dotfiles/settings.json" ]
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$BATS_TEST_TMPDIR/dotfiles/settings.json"
  [ "$output" = "bash $CFG/skills/_gh/auto-switch.sh" ]
}

# --- uninstall --------------------------------------------------------------------

@test "uninstall removes only the owned hook entry, leaves others" {
  printf '{ "hooks": { "SessionStart": [ { "matcher": "resume", "hooks": [ { "type": "command", "command": "echo keep-me" } ] } ] } }' \
    > "$CFG/settings.json"
  bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks >/dev/null
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks --uninstall
  [ "$status" -eq 0 ]
  run jq -c '.hooks.SessionStart' "$CFG/settings.json"
  [ "$output" = '[{"matcher":"resume","hooks":[{"type":"command","command":"echo keep-me"}]}]' ]
}

@test "uninstall on a settings.json with no matching hook is a no-op" {
  printf '{}' > "$CFG/settings.json"
  run bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to unwire"* ]]
}

@test "uninstall does not remove an unrelated hook with a literally-empty command" {
  # Regression for the cmd_tilde="" false-match: when $target isn't under
  # $HOME, cmd_tilde is "" — the uninstall filter must not treat an
  # unrelated hook's .command=="" as matching that empty sentinel.
  # settings.json resolves to dirname($target)/settings.json, so the fixture
  # must live in $target's own parent, not in the unrelated $CFG from setup().
  OUTSIDE="$BATS_TEST_TMPDIR/outside"
  OUTSIDE_TARGET="$OUTSIDE/skills"
  mkdir -p "$OUTSIDE_TARGET"
  printf '{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "" } ] }, { "hooks": [ { "type": "command", "command": "bash %s/_gh/auto-switch.sh" } ] } ] } }' \
    "$OUTSIDE_TARGET" > "$OUTSIDE/settings.json"
  run env HOME="$BATS_TEST_TMPDIR/unrelated-home" bash "$REPO_ROOT/scripts/install.sh" \
    --target "$OUTSIDE_TARGET" --wire-hooks --uninstall
  [ "$status" -eq 0 ]
  run jq '[.hooks.SessionStart[].hooks[]] | length' "$OUTSIDE/settings.json"
  [ "$output" = "1" ]
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$OUTSIDE/settings.json"
  [ "$output" = "" ]
}

# --- missing jq: fix-then-continue, never blocks the whole install --------------

@test "missing jq skips hook wiring but does not abort the rest of install.sh" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  for c in mkdir dirname basename ln readlink cat printf mktemp rm bash env grep sed awk; do
    real="$(command -v "$c" 2>/dev/null)" || continue
    ln -sf "$real" "$FAKEBIN/$c"
  done
  run env -i PATH="$FAKEBIN" HOME="$HOME" \
    bash "$REPO_ROOT/scripts/install.sh" --target "$CFG/skills" --wire-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires jq"* ]]
  [ -L "$CFG/skills/_gh" ]
  [ ! -e "$CFG/settings.json" ]
}
