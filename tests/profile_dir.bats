#!/usr/bin/env bats
# Tests for _session/profile-dir.sh — the ONE definition of the active Claude
# Code profile dir (T20261108-315759) — and for the scripts that use it: with
# CLAUDE_CONFIG_DIR set to a temp dir and HOME another temp dir, nothing may
# create $HOME/.claude.

load test_helper

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home" "$T/prof"
  export HOME="$T/home"
  unset CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID CLAIMANT_STATE_DIR LAST_INPUT_STATE_DIR \
        CCXP_LEDGER_FILE CCXP_SECRET_GUARD_LOG CCXP_HUD_CACHE_DIR HUD_QUEUE_STATE_DIR
  HELPER="$REPO_ROOT/_session/profile-dir.sh"
}

# resolve [env...] -- print CCXP_PROFILE_DIR from a fresh shell sourcing $1
resolve() {
  local helper="$1"; shift
  env "$@" bash -c ". '$helper'; printf '%s' \"\$CCXP_PROFILE_DIR\""
}

# install_in_cache <profile-root> -> path of a copy of the helper inside a plugin cache layout
install_in_cache() {
  local d="$1/plugins/cache/ccxp-skills/ccxp-skills/9.9.9/_session"
  mkdir -p "$d" && cp "$HELPER" "$d/profile-dir.sh"
  printf '%s' "$d/profile-dir.sh"
}

# --- resolution order ------------------------------------------------------

@test "CLAUDE_CONFIG_DIR wins" {
  run resolve "$HELPER" CLAUDE_CONFIG_DIR="$T/prof"
  [ "$output" = "$T/prof" ]
}

@test "CLAUDE_CONFIG_DIR wins over the path derived from the cache" {
  h="$(install_in_cache "$T/other")"
  run resolve "$h" CLAUDE_CONFIG_DIR="$T/prof"
  [ "$output" = "$T/prof" ]
}

@test "a set but not yet existing CLAUDE_CONFIG_DIR is still used, never ~/.claude" {
  run resolve "$HELPER" CLAUDE_CONFIG_DIR="$T/not-yet"
  [ "$output" = "$T/not-yet" ]
}

@test "a trailing slash on CLAUDE_CONFIG_DIR is stripped" {
  run resolve "$HELPER" CLAUDE_CONFIG_DIR="$T/prof/"
  [ "$output" = "$T/prof" ]
}

@test "without CLAUDE_CONFIG_DIR the profile is derived from the plugin cache path" {
  h="$(install_in_cache "$T/prof")"
  run resolve "$h" -u CLAUDE_CONFIG_DIR
  [ "$output" = "$T/prof" ]
}

@test "derivation works for a profile path with spaces" {
  h="$(install_in_cache "$T/my profile")"
  run resolve "$h" -u CLAUDE_CONFIG_DIR
  [ "$output" = "$T/my profile" ]
}

@test "the LAST /plugins/cache/ segment splits the path" {
  h="$(install_in_cache "$T/a/plugins/cache/b")"
  run resolve "$h" -u CLAUDE_CONFIG_DIR
  [ "$output" = "$T/a/plugins/cache/b" ]
}

@test "a symlinked cache dir keeps its logical /plugins/cache/ path" {
  mkdir -p "$T/real/ccxp-skills/ccxp-skills/9.9.9/_session" "$T/linked/plugins"
  cp "$HELPER" "$T/real/ccxp-skills/ccxp-skills/9.9.9/_session/profile-dir.sh"
  ln -s "$T/real" "$T/linked/plugins/cache"
  run resolve "$T/linked/plugins/cache/ccxp-skills/ccxp-skills/9.9.9/_session/profile-dir.sh" -u CLAUDE_CONFIG_DIR
  [ "$output" = "$T/linked" ]
}

@test "outside a cache and without CLAUDE_CONFIG_DIR it falls back to HOME/.claude" {
  mkdir -p "$T/loose/_session" && cp "$HELPER" "$T/loose/_session/"
  run resolve "$T/loose/_session/profile-dir.sh" -u CLAUDE_CONFIG_DIR HOME="$T/home"
  [ "$output" = "$T/home/.claude" ]
}

@test "an unset HOME does not crash a set -u caller" {
  run env -u HOME -u CLAUDE_CONFIG_DIR bash -c "set -u; . '$HELPER'; [ -n \"\$CCXP_PROFILE_DIR\" ]"
  [ "$status" -eq 0 ]
}

@test "sourcing writes nothing, exports nothing and leaves shell options alone" {
  run env CLAUDE_CONFIG_DIR="$T/prof" bash -c "set +e +u; . '$HELPER'; [[ \$- != *e* && \$- != *u* ]] && ! env | grep -q '^CCXP_PROFILE_DIR='"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$T/prof")" ]
  [ ! -e "$T/home/.claude" ]
}

# --- .env candidates -------------------------------------------------------

@test "ccxp_env_files lists the profile .env then the legacy one" {
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$HELPER'; ccxp_env_files"
  [ "${lines[0]}" = "$T/prof/.env" ]
  [ "${lines[1]}" = "$T/home/.claude/.env" ]
}

@test "ccxp_env_files does not repeat the path when the profile is ~/.claude" {
  run env -u CLAUDE_CONFIG_DIR HOME="$T/home" bash -c ". '$HELPER'; ccxp_env_files"
  [ "${#lines[@]}" -eq 1 ]
}

@test "ccxp_first_env_file prefers the profile .env and falls back to the legacy one" {
  mkdir -p "$T/home/.claude"; : > "$T/home/.claude/.env"
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$HELPER'; ccxp_first_env_file"
  [ "$output" = "$T/home/.claude/.env" ]
  : > "$T/prof/.env"
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$HELPER'; ccxp_first_env_file"
  [ "$output" = "$T/prof/.env" ]
  mv "$T/prof/.env" "$T/prof/.env.gone"; mv "$T/home/.claude/.env" "$T/home/.claude/.env.gone"
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$HELPER'; ccxp_first_env_file"
  [ "$status" -eq 1 ]
}

# --- the three defaults named in the task ----------------------------------

@test "claimant-id.sh puts its state under the profile, not ~/.claude" {
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$REPO_ROOT/_session/claimant-id.sh'; claimant_id '$T/repo' >/dev/null; printf '%s' \"\$CLAIMANT_STATE_DIR\""
  [ "$output" = "$T/prof/state" ]
  [ ! -e "$T/home/.claude" ]
  [ -d "$T/prof/state" ]
}

@test "hud-lib.sh defaults LAST_INPUT_STATE_DIR under the profile" {
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$REPO_ROOT/hud/scripts/hud-lib.sh'; printf '%s' \"\$LAST_INPUT_STATE_DIR\""
  [ "$output" = "$T/prof/state/last-input" ]
  [ ! -e "$T/home/.claude" ]
}

@test "last-input-hook.sh records the prompt under the profile and never creates ~/.claude" {
  run bash -c "printf '%s' '{\"session_id\":\"sess-1\"}' | env CLAUDE_CONFIG_DIR='$T/prof' HOME='$T/home' '$REPO_ROOT/hud/scripts/last-input-hook.sh'"
  [ "$status" -eq 0 ]
  [ -f "$T/prof/state/last-input/sess-1" ]
  [ ! -e "$T/home/.claude" ]
}

# --- other writers ---------------------------------------------------------

@test "session_cc_session_id keeps its per-host id under the profile" {
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$REPO_ROOT/_session/_lib.sh'; session_cc_session_id"
  [ "$status" -eq 0 ]
  [ -f "$T/prof/state/session-id" ]
  [ ! -e "$T/home/.claude" ]
}

@test "ledger.sh writes its ledger under the profile" {
  run env CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c "bash '$REPO_ROOT/hud/scripts/ledger.sh' start 7 'profile dir test' --context '$T/ctx.md'"
  [ -f "$T/prof/ccxp-ledger.json" ]
  [ ! -e "$T/home/.claude" ]
}

@test "secret-guard override log lands under the profile" {
  run bash -c "jq -n --arg c 'tool --password=hunter22' '{tool_name:\"Bash\",tool_input:{command:\$c},cwd:\"$T\"}' | env CCXP_ALLOW_SECRETS=1 CLAUDE_CONFIG_DIR='$T/prof' HOME='$T/home' '$REPO_ROOT/hooks/secret-guard.sh'"
  [ "$status" -eq 0 ]
  grep -q 'rules=' "$T/prof/secret-guard-overrides.log"
  [ ! -e "$T/home/.claude" ]
}

@test "_slack/webapi.sh reads SLACK_BOT_TOKEN from the profile .env" {
  printf 'SLACK_BOT_TOKEN=dummy-token\n' > "$T/prof/.env"
  run env -u BATS_TEST_TMPDIR -u SLACK_BOT_TOKEN CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash -c ". '$REPO_ROOT/_slack/webapi.sh'; _slack_api_load_token && printf '%s' \"\$SLACK_BOT_TOKEN\""
  [ "$output" = "dummy-token" ]
}

@test "slack-send.sh finds the webhook in the profile .env (SLACK_ENV_FILE unset)" {
  printf 'SLACK_WEBHOOK_URL=http://127.0.0.1:9/none\n' > "$T/prof/.env"
  run env -u BATS_TEST_TMPDIR -u SLACK_WEBHOOK_URL CLAUDE_CONFIG_DIR="$T/prof" HOME="$T/home" bash "$REPO_ROOT/slack/scripts/slack-send.sh" --help
  # Not "SLACK_WEBHOOK_URL is not set": the profile .env was loaded.
  [[ "$output" != *"SLACK_WEBHOOK_URL is not set"* ]]
}

# --- backward compatibility ------------------------------------------------

@test "with CLAUDE_CONFIG_DIR unset the claimant state still lands in HOME/.claude/state" {
  run env -u CLAUDE_CONFIG_DIR HOME="$T/home" bash -c ". '$REPO_ROOT/_session/claimant-id.sh'; claimant_id '$T/repo' >/dev/null; printf '%s' \"\$CLAIMANT_STATE_DIR\""
  [ "$output" = "$T/home/.claude/state" ]
  [ -d "$T/home/.claude/state" ]
}

@test "explicit overrides still win over the profile" {
  run env CLAUDE_CONFIG_DIR="$T/prof" LAST_INPUT_STATE_DIR="$T/li" HOME="$T/home" bash -c ". '$REPO_ROOT/hud/scripts/hud-lib.sh'; printf '%s' \"\$LAST_INPUT_STATE_DIR\""
  [ "$output" = "$T/li" ]
}
