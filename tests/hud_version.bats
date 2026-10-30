#!/usr/bin/env bats
# Tests for the ccxp-skills version segment of the ccxp-hud data helper
# (hud/scripts/hud-version.sh, reached through hud-data.sh --json). The "remote" is a local
# git repo with ccxp-skills--v* tags; nothing here talks to the network or the developer's state.

load test_helper
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
VER="$REPO_ROOT/hud/scripts/hud-version.sh"

setup() {
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/remote"
  export CCXP_HUD_VERSION_SYNC=1
  export GIT_TERMINAL_PROMPT=0
}

# $@ = tag names to create in the fake remote (a fresh repo per test, BATS_TEST_TMPDIR is empty at start)
_remote() {
  mkdir -p "$HUD_VERSION_REMOTE"
  git -C "$HUD_VERSION_REMOTE" init -q -b main
  git -C "$HUD_VERSION_REMOTE" -c user.email=t@e.x -c user.name=t commit -q --allow-empty -m init
  local t; for t in "$@"; do git -C "$HUD_VERSION_REMOTE" tag "$t"; done
}

# $1 = installed version -> a fake plugin root
_plugin() {
  local d="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$d/.claude-plugin"
  printf '{"name":"ccxp-skills","version":"%s"}' "$1" > "$d/.claude-plugin/plugin.json"
  printf '%s' "$d"
}

_ver() { bash -c "source '$VER'; hud-version-json '$1' '${2:-1}'"; }

@test "semver compare is numeric, not a string compare" {
  source "$VER"
  hvr-semver-gt 5.10.0 5.9.0
  hvr-semver-gt 10.0.0 9.9.9
  hvr-semver-gt 5.0.1 5.0.0
  hvr-semver-gt 5.0.0 5.0.0-rc.1
  ! hvr-semver-gt 5.0.0 5.0.0
  ! hvr-semver-gt 5.9.0 5.10.0
  ! hvr-semver-gt 4.9.9 5.0.0
  ! hvr-semver-gt 5.0.0-rc.1 5.0.0
  ! hvr-semver-gt 5.0.0 x
  ! hvr-semver-gt "" 5.0.0
  ! hvr-semver-gt 5.0.0 ""
}

@test "installed version is read from the plugin's own plugin.json" {
  source "$VER"
  [ "$(hvr-installed "$(_plugin 5.0.0)")" = "5.0.0" ]
  [ -z "$(hvr-installed "$BATS_TEST_TMPDIR/nowhere")" ]
  [ -z "$(hvr-installed "$(_plugin 'x; echo pwned')")" ]
}

@test "the highest tag is reported whatever its relation to installed (the HUD decides the wording)" {
  _remote ccxp-skills--v4.1.1 ccxp-skills--v5.0.0 ccxp-skills--v5.1.0
  run _ver "$(_plugin 5.0.0)"
  [ "$output" = '{"installed":"5.0.0","latest":"5.1.0"}' ]
  run _ver "$(_plugin 5.1.0)"
  [ "$output" = '{"installed":"5.1.0","latest":"5.1.0"}' ]
  run _ver "$(_plugin 5.2.0)"
  [ "$output" = '{"installed":"5.2.0","latest":"5.1.0"}' ]
}

@test "no tag at all: latest stays null (never claimed)" {
  _remote other--v1.0.0
  run _ver "$(_plugin 5.1.0)"
  [ "$output" = '{"installed":"5.1.0","latest":null}' ]
}

@test "the highest tag wins by semver (5.10.0 beats 5.9.0); prerelease and foreign tags are ignored" {
  _remote ccxp-skills--v5.9.0 ccxp-skills--v5.10.0 ccxp-skills--v6.0.0-rc.1 other--v9.0.0 ccxp-skills--vjunk
  run _ver "$(_plugin 5.0.0)"
  [ "$(jq -r .latest <<<"$output")" = "5.10.0" ]
}

@test "disabled prints null and makes no lookup; a missing plugin.json prints null" {
  _remote ccxp-skills--v9.0.0
  run _ver "$(_plugin 5.0.0)" 0
  [ "$output" = "null" ]
  [ ! -e "$HUD_VERSION_STATE_DIR" ]
  run _ver "$BATS_TEST_TMPDIR/nowhere"
  [ "$output" = "null" ]
}

@test "offline: installed is still shown, an older cached latest is kept, retry is sooner than 6 h" {
  _remote ccxp-skills--v5.1.0
  run _ver "$(_plugin 5.0.0)"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
  # Expire the cache, then break the remote.
  jq '.fetched = 0' "$HUD_VERSION_STATE_DIR/latest.json" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$HUD_VERSION_STATE_DIR/latest.json"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/gone"
  run _ver "$(_plugin 5.0.0)"
  [ "$output" = '{"installed":"5.0.0","latest":"5.1.0"}' ]
  local fetched; fetched=$(jq -r .fetched "$HUD_VERSION_STATE_DIR/latest.json")
  [ $(( $(date +%s) - fetched )) -ge $((21600 - 900 - 5)) ]
}

@test "a fresh cache is used without any lookup (6 h poll)" {
  mkdir -p "$HUD_VERSION_STATE_DIR"
  printf '{"latest":"7.0.0","fetched":%s}\n' "$(date +%s)" > "$HUD_VERSION_STATE_DIR/latest.json"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/gone"
  run _ver "$(_plugin 5.0.0)"
  [ "$output" = '{"installed":"5.0.0","latest":"7.0.0"}' ]
  [ ! -d "$HUD_VERSION_STATE_DIR/latest.lock" ]
}

@test "garbage in the cache never reaches the output" {
  mkdir -p "$HUD_VERSION_STATE_DIR"
  printf '{"latest":"9.9.9; echo pwned","fetched":%s}\n' "$(date +%s)" > "$HUD_VERSION_STATE_DIR/latest.json"
  run _ver "$(_plugin 5.0.0)"
  [ "$output" = '{"installed":"5.0.0","latest":null}' ]
}

# $1 = repository value (raw JSON), $2 = homepage value (raw JSON or empty) -> a fake plugin root
_plugin_urls() {
  local d="$BATS_TEST_TMPDIR/plugin"; mkdir -p "$d/.claude-plugin"
  jq -n -c --argjson r "$1" --argjson h "${2:-null}" '{name:"ccxp-skills",version:"5.0.0"} + (if $r == null then {} else {repository:$r} end) + (if $h == null then {} else {homepage:$h} end)' > "$d/.claude-plugin/plugin.json"
  printf '%s' "$d"
}

@test "url: the plugin's GitHub location comes from plugin.json repository, else homepage" {
  _remote ccxp-skills--v5.0.0
  run _ver "$(_plugin_urls '"https://github.com/Acme/widgets"')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/widgets" ]
  run _ver "$(_plugin_urls '"git+https://github.com/Acme/w.git"' '"https://github.com/Acme/home#readme"')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/home" ]
  run _ver "$(_plugin_urls '{"type":"git","url":"https://github.com/Acme/obj.git"}')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/obj" ]
  run _ver "$(_plugin_urls '"https://github.com/Acme/w.git/"')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/w" ]
  run _ver "$(_plugin_urls '"https://github.com/Acme/w/"')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/w" ]
  run _ver "$(_plugin_urls 'null' '"https://github.com/Acme/home#readme"')"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Acme/home" ]
}

@test "url: anything but a plain github.com/<owner>/<repo> is left out (the mod falls back)" {
  _remote ccxp-skills--v5.0.0
  local bad
  for bad in '"http://github.com/a/b"' '"https://evil.example/a/b"' '"https://github.com/a/b/c"' '"https://github.com/a/b c"' '"https://github.com/a/b\u001b]8;;x"' '42'; do
    run _ver "$(_plugin_urls "$bad")"
    [ "$(jq -r 'has("url")' <<<"$output")" = "false" ]
  done
  run _ver "$(_plugin 5.0.0)"
  [ "$output" = '{"installed":"5.0.0","latest":"5.0.0"}' ]
}

@test "the real manifest yields the public ccxp-skills URL" {
  _remote ccxp-skills--v5.0.0
  run _ver "$REPO_ROOT"
  [ "$(jq -r .url <<<"$output")" = "https://github.com/Synx-Data-Labs/ccxp-skills" ]
}

@test "hud-data --json carries plugin; show_version false turns it to null" {
  _remote ccxp-skills--v99.0.0
  local repo="$BATS_TEST_TMPDIR/r"; mkdir -p "$repo"; git -C "$repo" init -q -b main
  run bash -c "printf '{\"cwd\":\"$repo\"}' | bash '$HUD' --json"
  [ "$(jq -r .plugin.installed <<<"$output")" = "$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")" ]
  [ "$(jq -r .plugin.latest <<<"$output")" = "99.0.0" ]
  [ "$(jq -r .plugin.url <<<"$output")" = "https://github.com/Synx-Data-Labs/ccxp-skills" ]
  run bash -c "printf '{\"cwd\":\"$repo\",\"show_version\":false}' | bash '$HUD' --json"
  [ "$(jq -r .plugin <<<"$output")" = "null" ]
}

@test "the lookup is git ls-remote only: no credential prompt, no token, no gh" {
  grep -q 'git ls-remote --tags' "$VER"
  grep -q 'GIT_TERMINAL_PROMPT=0' "$VER"
  ! grep -nE 'curl|wget|\bgh |token|TOKEN' "$VER"
}
