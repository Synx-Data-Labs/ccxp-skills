#!/usr/bin/env bats
# Tests for update/scripts/auto.sh and hooks/update-check.sh (`/update auto on|off|status`).
# `claude`, `git`, `gh` are fakes on PATH; the profile is a temp dir -- the real ~/.claude* is never touched.

load test_helper

setup() {
  AUTO="$REPO_ROOT/update/scripts/auto.sh"
  HOOK="$REPO_ROOT/hooks/update-check.sh"
  P="$BATS_TEST_TMPDIR/profile"
  BIN="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$BIN" "$STATE" "$WORK/dev" "$P/plugins/cache/ccxp-skills/ccxp-skills"
  export FAKE_STATE="$STATE" CLAUDE_CONFIG_DIR="$P"
  echo 5.7.0 > "$STATE/version"
  echo "refs/tags/ccxp-skills--v5.7.0 refs/tags/ccxp-skills--v5.8.0" > "$STATE/tags"
  export CLAUDE_PLUGIN_ROOT="$P/plugins/cache/ccxp-skills/ccxp-skills/5.7.0"
  mk_pairing 5.7.0
  printf '{"env":{"K":"v"},"extraKnownMarketplaces":{"ccxp-skills":{"source":{"source":"github","repo":"Synx-Data-Labs/ccxp-skills"}},"other":{"autoUpdate":true}}}\n' > "$P/settings.json"
  cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_STATE/calls"
case "$1 $2 $3" in
  "plugin list --json") printf '[{"id":"ccxp-skills@ccxp-skills","version":"%s"}]\n' "$(cat "$FAKE_STATE/version")" ;;
  "plugin marketplace update") ;;
  "plugin update ccxp-skills@ccxp-skills")
    n="$(sed -n 's/.*ccxp-skills--v\([0-9.]*\) *$/\1/p' <<<"$(tr ' ' '\n' < "$FAKE_STATE/tags" | sort -V | tail -1)")"
    echo "$n" > "$FAKE_STATE/version"
    d="$CLAUDE_CONFIG_DIR/plugins/cache/ccxp-skills/ccxp-skills/$n/agent-pairing/scripts"; mkdir -p "$d"
    printf '#!/usr/bin/env bash\necho "pairing-%s $*" >> "$FAKE_STATE/calls"\n' "$n" > "$d/agent-pairing.sh" ;;
  *) exit 9 ;;
esac
FAKE
  cat > "$BIN/git" <<'FAKE'
#!/usr/bin/env bash
echo "git $*" >> "$FAKE_STATE/gitcalls"
[ "$1" = ls-remote ] || exit 9
[ -z "${FAKE_NO_GIT:-}" ] || exit 128
for t in $(cat "$FAKE_STATE/tags"); do printf 'deadbeef\t%s\n' "$t"; done
FAKE
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
  chmod +x "$BIN/claude" "$BIN/git" "$BIN/gh"
  export PATH="$BIN:$PATH"
}

mk_pairing() {
  local d="$P/plugins/cache/ccxp-skills/ccxp-skills/$1/agent-pairing/scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "pairing-%s $*" >> "$FAKE_STATE/calls"\n' "$1" > "$d/agent-pairing.sh"
}

run_hook() { run bash -c "printf '{\"cwd\":\"$WORK\"}' | bash '$HOOK'"; }
sf() { echo "$P/ccxp-skills-auto-update.json"; }

@test "on: state file mode 600, native key set, settings backup, other keys kept" {
  run bash "$AUTO" on
  [ "$status" -eq 0 ]
  [ "$(jq -r .enabled "$(sf)")" = true ]
  perm="$(stat -c %a "$(sf)" 2>/dev/null || stat -f %Lp "$(sf)")"; [ "$perm" = 600 ]
  [ "$(jq -r '.extraKnownMarketplaces["ccxp-skills"].autoUpdate' "$P/settings.json")" = true ]
  [ "$(jq -r '.extraKnownMarketplaces["ccxp-skills"].source.repo' "$P/settings.json")" = Synx-Data-Labs/ccxp-skills ]
  [ "$(jq -r '.extraKnownMarketplaces.other.autoUpdate' "$P/settings.json")" = true ]
  [ "$(jq -r .env.K "$P/settings.json")" = v ]
  [ "$(ls "$P"/settings.json.bak-* | wc -l | tr -d ' ')" = 1 ]
  [[ "$output" == *"/reload-plugins"* ]]
}

@test "on twice is idempotent: no second backup, file unchanged" {
  bash "$AUTO" on >/dev/null
  cksum "$P/settings.json" "$(sf)" > "$BATS_TEST_TMPDIR/sum1"
  run bash "$AUTO" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on"* ]]
  cksum "$P/settings.json" "$(sf)" > "$BATS_TEST_TMPDIR/sum2"
  cmp "$BATS_TEST_TMPDIR/sum1" "$BATS_TEST_TMPDIR/sum2"
  [ "$(ls "$P"/settings.json.bak-* | wc -l | tr -d ' ')" = 1 ]
}

@test "off: state false, native key false; off twice and off from clean change nothing" {
  bash "$AUTO" on >/dev/null
  run bash "$AUTO" off
  [ "$status" -eq 0 ]
  [ "$(jq -r .enabled "$(sf)")" = false ]
  [ "$(jq -r '.extraKnownMarketplaces["ccxp-skills"].autoUpdate' "$P/settings.json")" = false ]
  n="$(ls "$P"/settings.json.bak-* | wc -l | tr -d ' ')"
  run bash "$AUTO" off
  [[ "$output" == *"already off"* ]]
  [ "$(ls "$P"/settings.json.bak-* | wc -l | tr -d ' ')" = "$n" ]
}

@test "off on a clean profile writes no backup and leaves settings byte-identical" {
  cksum "$P/settings.json" > "$BATS_TEST_TMPDIR/s1"
  run bash "$AUTO" off
  [ "$status" -eq 0 ]
  cksum "$P/settings.json" > "$BATS_TEST_TMPDIR/s2"; cmp "$BATS_TEST_TMPDIR/s1" "$BATS_TEST_TMPDIR/s2"
  [ ! -e "$(ls "$P"/settings.json.bak-* 2>/dev/null | head -1)" ] || false
}

@test "on without a marketplace entry or with invalid settings: state set, settings untouched" {
  echo '{"env":{}}' > "$P/settings.json"
  run bash "$AUTO" on
  [ "$status" -eq 0 ]; [ "$(jq -r .enabled "$(sf)")" = true ]
  [ "$(cat "$P/settings.json")" = '{"env":{}}' ]
  echo '{bad' > "$P/settings.json"
  run bash "$AUTO" on --claude-dir "$P"
  [ "$status" -eq 0 ]; [ "$(cat "$P/settings.json")" = '{bad' ]
}

@test "--dry-run writes nothing; --claude-dir honored; bad args exit 2" {
  run bash "$AUTO" on --dry-run
  [ "$status" -eq 0 ]; [ ! -e "$(sf)" ]
  other="$BATS_TEST_TMPDIR/other"; mkdir -p "$other"
  run bash "$AUTO" on --claude-dir "$other"
  [ -f "$other/ccxp-skills-auto-update.json" ]; [ ! -e "$(sf)" ]
  run bash "$AUTO" maybe; [ "$status" -eq 2 ]
  run bash "$AUTO"; [ "$status" -eq 2 ]
}

@test "status reports state, native flag and the disabling env var; writes nothing" {
  DISABLE_AUTOUPDATER=1 run bash "$AUTO" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-update    off"* ]]
  [[ "$output" == *"DISABLE_AUTOUPDATER"* ]]
  [ ! -e "$(sf)" ]
  bash "$AUTO" on >/dev/null
  run bash "$AUTO" status
  [[ "$output" == *"auto-update    ON"* ]]; [[ "$output" == *"native flag    true"* ]]
}

@test "hook is a no-op when off or when no state file exists: no output, no git/claude calls" {
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  bash "$AUTO" on >/dev/null; bash "$AUTO" off >/dev/null
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -e "$STATE/gitcalls" ]; [ ! -e "$STATE/calls" ]
}

@test "hook: newer minor release downloads, refreshes persona from the NEW dir, one systemMessage in n122 order" {
  bash "$AUTO" on >/dev/null
  run_hook
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.systemMessage and .hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  msg="$(echo "$output" | jq -r .systemMessage)"
  [[ "$msg" == *"5.8.0 is installed"* ]]
  [[ "$msg" == *"cannot load it by itself"* ]]
  a="${msg%%/reload-plugins*}"; b="${msg%%restart once*}"; c="${msg%%/autopilot on*}"
  [ "${#a}" -lt "${#b}" ]; [ "${#b}" -lt "${#c}" ]
  grep -q "claude plugin update ccxp-skills@ccxp-skills" "$STATE/calls"
  grep -q "pairing-5.8.0 update --claude-dir $P" "$STATE/calls"
  if grep -q "pairing-5.7.0" "$STATE/calls"; then false; fi
  [ "$(jq -r .personaFor "$(sf)")" = 5.8.0 ]
}

@test "hook: one message per version (second session start after the throttle is silent, persona not re-run)" {
  bash "$AUTO" on >/dev/null
  run_hook; [ -n "$output" ]
  jq '.lastCheck = 1' "$(sf)" > "$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$(sf)"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(grep -c 'pairing-5.8.0' "$STATE/calls")" = 1 ]
}

@test "hook: throttle skips the network inside the window, checks again after it" {
  bash "$AUTO" on >/dev/null
  run_hook
  n1="$(wc -l < "$STATE/gitcalls")"
  run_hook; [ -z "$output" ]
  [ "$(wc -l < "$STATE/gitcalls")" = "$n1" ]
  jq '.lastCheck = 1' "$(sf)" > "$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$(sf)"
  run_hook
  [ "$(wc -l < "$STATE/gitcalls")" -gt "$n1" ]
}

@test "hook: offline is silent, exit 0, and does not advance lastCheck" {
  bash "$AUTO" on >/dev/null
  FAKE_NO_GIT=1 run_hook
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(jq -r '.lastCheck // "none"' "$(sf)")" = none ]
  [ ! -e "$STATE/calls" ]
}

@test "hook: MAJOR bump is held (notice only, once), no plugin update" {
  echo "refs/tags/ccxp-skills--v5.7.0 refs/tags/ccxp-skills--v6.0.0" > "$STATE/tags"
  bash "$AUTO" on >/dev/null
  run_hook
  [[ "$(echo "$output" | jq -r .systemMessage)" == *"MAJOR release"* ]]
  if [ -e "$STATE/calls" ] && grep -q "plugin update\|pairing-" "$STATE/calls"; then false; fi
  jq '.lastCheck = 1' "$(sf)" > "$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$(sf)"
  run_hook; [ -z "$output" ]
}

@test "hook: autopilot busy in the cwd repo skips the update entirely" {
  printf '{"status":"on","busy_since":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}\n' > "$WORK/dev/.autopilot-state.json"
  bash "$AUTO" on >/dev/null
  run_hook
  [ "$status" -eq 0 ]; [ -z "$output" ]
  if [ -e "$STATE/calls" ] && grep -q "plugin update\|pairing-" "$STATE/calls"; then false; fi
}

@test "hook: a stale busy mark (over 3 h old) does not block the update" {
  printf '{"status":"on","busy_since":"2020-01-01T00:00:00Z"}\n' > "$WORK/dev/.autopilot-state.json"
  bash "$AUTO" on >/dev/null
  run_hook
  grep -q "claude plugin update" "$STATE/calls"
}

@test "hook: autopilot on but idle proceeds and the message says to turn it back on" {
  printf '{"status":"on","busy_since":null}\n' > "$WORK/dev/.autopilot-state.json"
  bash "$AUTO" on >/dev/null
  run_hook
  [[ "$(echo "$output" | jq -r .systemMessage)" == *"autopilot was on"* ]]
}

@test "hook: already running the newest version is silent" {
  echo 5.8.0 > "$STATE/version"; mk_pairing 5.8.0
  export CLAUDE_PLUGIN_ROOT="$P/plugins/cache/ccxp-skills/ccxp-skills/5.8.0"
  bash "$AUTO" on >/dev/null
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
  if grep -q "plugin update\|pairing-" "$STATE/calls"; then false; fi
}

@test "hook: no jq-free crash on garbage state file; exits 0 silently" {
  echo 'not json' > "$(sf)"
  run_hook; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "hooks.json registers update-check.sh on SessionStart(startup) and is valid" {
  jq -e '.hooks.SessionStart[0].matcher == "startup" and (.hooks.SessionStart[0].hooks[0].command | contains("update-check.sh"))' "$REPO_ROOT/hooks/hooks.json" >/dev/null
  [ -x "$HOOK" ]
}

@test "update.sh --quiet --no-agent: no stdout, plugin updated, agent not refreshed" {
  run bash "$REPO_ROOT/update/scripts/update.sh" --quiet --no-agent
  [ "$status" -eq 0 ]; [ -z "$output" ]
  grep -q "claude plugin update" "$STATE/calls"
  if grep -q "pairing-" "$STATE/calls"; then false; fi
}

@test "hook: busy skip and failed update do not advance lastCheck (retried next start)" {
  printf '{"status":"on","busy_since":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}\n' > "$WORK/dev/.autopilot-state.json"
  bash "$AUTO" on >/dev/null
  run_hook
  [ "$(jq -r '.lastCheck // "none"' "$(sf)")" = none ]
}

@test "on keeps a symlinked settings.json a symlink and preserves its mode" {
  mv "$P/settings.json" "$BATS_TEST_TMPDIR/real.json"; chmod 640 "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$P/settings.json"
  run bash "$AUTO" on
  [ "$status" -eq 0 ]; [ -L "$P/settings.json" ]
  [ "$(jq -r '.extraKnownMarketplaces["ccxp-skills"].autoUpdate' "$BATS_TEST_TMPDIR/real.json")" = true ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/real.json" 2>/dev/null || stat -f %Lp "$BATS_TEST_TMPDIR/real.json")" = 640 ]
}

@test "hook: a hung update is cut off by the time limit and session start still exits 0" {
  printf '#!/usr/bin/env bash\nif [ "$2" = update ]; then sleep 30; fi\ncase "$1 $2 $3" in "plugin list --json") printf "[{\\"id\\":\\"ccxp-skills@ccxp-skills\\",\\"version\\":\\"5.7.0\\"}]";; esac\n' > "$BIN/claude"
  bash "$AUTO" on >/dev/null
  start=$SECONDS
  CCXP_UPDATE_LIMIT_SECS=2 run_hook
  [ "$status" -eq 0 ]; [ $((SECONDS - start)) -lt 15 ]
}
