#!/usr/bin/env bats
# Tests for update/scripts/update.sh. `claude`, `git`, `gh` are fakes on PATH;
# the profile is a temp dir -- the real ~/.claude* is never touched.

load test_helper

setup() {
  SCRIPT="$REPO_ROOT/update/scripts/update.sh"
  CLAUDE_DIR="$BATS_TEST_TMPDIR/profile"
  BIN="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$STATE" "$CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills"
  export FAKE_STATE="$STATE" CLAUDE_CONFIG_DIR="$CLAUDE_DIR"
  echo 5.0.0 > "$STATE/version"
  echo "refs/tags/ccxp-skills--v5.0.0 refs/tags/ccxp-skills--v5.1.0 refs/tags/ccxp-skills--v5.10.0 refs/tags/ccxp-skills--v5.9.0 refs/tags/other-v9.9.9" > "$STATE/tags"
  mk_pairing 5.0.0
  # fake claude: list / marketplace update / update (update bumps to $FAKE_NEXT)
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_STATE/calls"
echo "cfg=$CLAUDE_CONFIG_DIR" >> "$FAKE_STATE/env"
case "$1 $2 $3" in
  "plugin list --json") printf '[{"id":"ccxp-skills@ccxp-skills","version":"%s"}]\n' "$(cat "$FAKE_STATE/version")" ;;
  "plugin marketplace update") [ -z "${FAKE_FAIL_MKT:-}" ] || { echo mkt-boom >&2; exit 1; } ;;
  "plugin update ccxp-skills@ccxp-skills")
    [ -z "${FAKE_FAIL_UPD:-}" ] || { echo upd-boom >&2; exit 1; }
    [ -n "${FAKE_NOOP_UPD:-}" ] && exit 0
    echo "$FAKE_NEXT" > "$FAKE_STATE/version"
    d="$CLAUDE_CONFIG_DIR/plugins/cache/ccxp-skills/ccxp-skills/$FAKE_NEXT/agent-pairing/scripts"
    mkdir -p "$d"
    printf '#!/usr/bin/env bash\necho "pairing-%s $*" >> "$FAKE_STATE/calls"\n' "$FAKE_NEXT" > "$d/agent-pairing.sh"
    [ -z "${FAKE_PAIRING_FAIL:-}" ] || echo 'exit 3' >> "$d/agent-pairing.sh" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
FAKE
  cat > "$BIN/git" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || exit 9
[ -z "${FAKE_NO_GIT:-}" ] || exit 128
for t in $(cat "$FAKE_STATE/tags"); do printf 'deadbeef\t%s\n' "$t"; printf 'deadbeef\t%s^{}\n' "$t"; done
FAKE
  cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_STATE/calls"
echo "ccxp-skills--v5.2.0"
FAKE
  chmod +x "$BIN/claude" "$BIN/git" "$BIN/gh"
  export PATH="$BIN:$PATH"
  export FAKE_NEXT=5.10.0
}

mk_pairing() {
  local d="$CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills/$1/agent-pairing/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "pairing-%s $*" >> "$FAKE_STATE/calls"\n' "$1" > "$d/agent-pairing.sh"
}

@test "latest is chosen by semver (5.10.0 beats 5.9.0), other tags ignored" {
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"latest available 5.10.0"* ]]
  [[ "$output" == *"releases/tag/ccxp-skills--v5.10.0"* ]]
}

@test "--check writes nothing: no marketplace/plugin update, agent preview via --dry-run" {
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  if grep -q "marketplace update\|plugin update" "$STATE/calls"; then false; fi
  grep -q "pairing-5.0.0 update --dry-run --claude-dir $CLAUDE_DIR" "$STATE/calls"
  [ "$(cat "$STATE/version")" = 5.0.0 ]
}

@test "--dry-run and -n are aliases of --check" {
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]; [[ "$output" == *"--check: writing nothing"* ]]
  run bash "$SCRIPT" -n
  [ "$status" -eq 0 ]; [[ "$output" == *"--check: writing nothing"* ]]
}

@test "update: marketplace, then plugin, then the NEW version's agent-pairing update" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "grep -v 'plugin list' '$STATE/calls' | tr '\n' '|'"
  [ "$output" = "claude plugin marketplace update ccxp-skills|claude plugin update ccxp-skills@ccxp-skills|pairing-5.10.0 update --claude-dir $CLAUDE_DIR|" ]
}

@test "update: reports before/after, manual steps and what will change" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin 5.0.0 -> 5.10.0"* ]]
  [[ "$output" == *"/reload-plugins"* ]]
  [[ "$output" == *"restart"* ]]
  [[ "$output" == *"WILL CHANGE under $CLAUDE_DIR"* ]]
  if grep -q "pairing-5.0.0" "$STATE/calls"; then false; fi
}

@test "claude is pointed at the chosen profile via CLAUDE_CONFIG_DIR" {
  run bash "$SCRIPT" --claude-dir "$CLAUDE_DIR"
  [ "$status" -eq 0 ]
  if grep -qv "cfg=$CLAUDE_DIR" "$STATE/env"; then false; fi
}

@test "marketplace failure: exit 1, no plugin update, no agent refresh, state described" {
  FAKE_FAIL_MKT=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  if grep -q "plugin update\|pairing-" "$STATE/calls"; then false; fi
  [[ "$output" == *"agent definition NOT refreshed"* ]]
}

@test "plugin update failure: exit 1 and the agent is not refreshed" {
  FAKE_FAIL_UPD=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  if grep -q "pairing-" "$STATE/calls"; then false; fi
  [[ "$output" == *"NOT refreshed"* ]]
}

@test "plugin update that does not advance the version: fail, no agent refresh" {
  FAKE_NOOP_UPD=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  if grep -q "pairing-" "$STATE/calls"; then false; fi
  [[ "$output" == *"still reports 5.0.0"* ]]
}

@test "already latest: no plugin update, agent refresh still runs with installed copy" {
  echo 5.10.0 > "$STATE/version"; mk_pairing 5.10.0
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  if grep -q "plugin update" "$STATE/calls"; then false; fi
  grep -q "pairing-5.10.0 update --claude-dir" "$STATE/calls"
  [[ "$output" == *"already at the latest"* ]]
}

@test "newest cache dir ignores non-semver siblings like 9.9.9.old" {
  mkdir -p "$CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills/9.9.9.old/agent-pairing/scripts"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "pairing-5.10.0" "$STATE/calls"
}

@test "latest lookup falls back to gh when git ls-remote fails" {
  FAKE_NO_GIT=1 run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"latest available 5.2.0"* ]]
}

@test "not installed: fails loudly, changes nothing" {
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "plugin list" ] && { echo '[]'; exit 0; }
echo "claude $*" >> "$FAKE_STATE/calls"
FAKE
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
  [ ! -f "$STATE/calls" ]
}

@test "agent refresh failure after plugin update: exit 1 and state described" {
  FAKE_PAIRING_FAIL=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin is now 5.10.0 but the agent refresh failed"* ]]
}

@test "non-semver installed version: fails loudly" {
  echo abc123 > "$STATE/version"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not x.y.z"* ]]
}

@test "bad flag: usage, exit 2" {
  run bash "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}
