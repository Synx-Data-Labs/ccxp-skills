#!/usr/bin/env bats
# Tests for the ccxp-skills version segment of the ccxp-hud data helper
# (hud/scripts/hud-version.sh, reached through hud-data.sh --json). The "remote" is a local
# git repo with ccxp-skills--v* tags; nothing here talks to the network or the developer's state.

load test_helper
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
VER="$REPO_ROOT/hud/scripts/hud-version.sh"

setup() {
  export HUD_BEHIND_STATE_DIR="$BATS_TEST_TMPDIR/hud-behind" # the behind fetch never touches ~/.claude
  export HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_HWM_SYNC=1 HUD_NIGHTLY_OFF=1 # fetch stamps and the queue watermark never touch ~/.claude
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  export HUD_CI_STATE_DIR="$BATS_TEST_TMPDIR/hud-ci"
  export HUD_VERSION_STATE_DIR="$BATS_TEST_TMPDIR/hud-version"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/remote"
  export CCXP_HUD_VERSION_SYNC=1
  export HUD_UNRELEASED_URL="file://$BATS_TEST_TMPDIR/no-compare.json" # the unreleased lookup never reaches api.github.com (a missing file = unreachable)
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

# $1 = plugin root -> its plugin.json mtime, the way the cache records it ("pm")
_pm() { ( source "$VER"; hvr-plugin-mtime "$1" ); }

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
  local root; root=$(_plugin 5.0.0)
  mkdir -p "$HUD_VERSION_STATE_DIR"
  printf '{"latest":"7.0.0","fetched":%s,"pm":%s}\n' "$(date +%s)" "$(_pm "$root")" > "$HUD_VERSION_STATE_DIR/latest.json"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/gone"
  run _ver "$root"
  [ "$output" = '{"installed":"5.0.0","latest":"7.0.0"}' ]
  [ ! -d "$HUD_VERSION_STATE_DIR/latest.lock" ]
  [ "$(jq -r .fetched "$HUD_VERSION_STATE_DIR/latest.json")" -ge $(( $(date +%s) - 5 )) ] # and the cache was not rewritten into a retry state
}

@test "a changed plugin.json re-checks once, inside the TTL; an unchanged one does not (and refreshes record its mtime)" {
  _remote ccxp-skills--v5.1.0
  local root; root=$(_plugin 5.0.0)
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
  [ "$(jq -r .pm "$HUD_VERSION_STATE_DIR/latest.json")" = "$(_pm "$root")" ]
  # A new release appears; the cache is fresh and plugin.json is untouched: still the old answer, no lookup.
  git -C "$HUD_VERSION_REMOTE" tag ccxp-skills--v5.2.0
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
  # The plugin is updated in place (plugin.json mtime moves): ONE re-check, well inside the 6 h TTL
  # (the cache is a couple of minutes old by then; a change inside the first minute waits for it).
  jq -c '.fetched -= 120' "$HUD_VERSION_STATE_DIR/latest.json" > "$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$HUD_VERSION_STATE_DIR/latest.json"
  touch -t 203001010000 "$root/.claude-plugin/plugin.json"
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.2.0" ]
  [ "$(jq -r .pm "$HUD_VERSION_STATE_DIR/latest.json")" = "$(_pm "$root")" ]
  # ... and not again: the next tag is not seen until the TTL (or another change).
  git -C "$HUD_VERSION_REMOTE" tag ccxp-skills--v5.3.0
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.2.0" ]
}

@test "a cache written before the mtime was recorded (no pm) re-checks once; a failed re-check keeps the old answer and records the mtime (no retry storm)" {
  local root; root=$(_plugin 5.0.0)
  mkdir -p "$HUD_VERSION_STATE_DIR"
  printf '{"latest":"5.1.0","fetched":%s}\n' "$(( $(date +%s) - 120 ))" > "$HUD_VERSION_STATE_DIR/latest.json"
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/gone"
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
  [ "$(jq -r .pm "$HUD_VERSION_STATE_DIR/latest.json")" = "$(_pm "$root")" ]
  _remote ccxp-skills--v5.9.0
  export HUD_VERSION_REMOTE="$BATS_TEST_TMPDIR/remote"
  run _ver "$root"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ] # retry is ~15 min away, not on every redraw
}

@test "a garbage pm in the cache counts as changed; it never reaches the output" {
  local root; root=$(_plugin 5.0.0)
  _remote ccxp-skills--v5.1.0
  mkdir -p "$HUD_VERSION_STATE_DIR"
  printf '{"latest":"5.0.0","fetched":%s,"pm":"1; echo pwned"}\n' "$(( $(date +%s) - 120 ))" > "$HUD_VERSION_STATE_DIR/latest.json"
  run _ver "$root"
  [ "$output" = '{"installed":"5.0.0","latest":"5.1.0"}' ]
}

@test "garbage in the cache never reaches the output" {
  mkdir -p "$HUD_VERSION_STATE_DIR"
  local root; root=$(_plugin 5.0.0)
  printf '{"latest":"9.9.9; echo pwned","fetched":%s,"pm":%s}\n' "$(date +%s)" "$(_pm "$root")" > "$HUD_VERSION_STATE_DIR/latest.json"
  run _ver "$root"
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

@test "the lookups use no credentials: git ls-remote for tags, anonymous curl for the compare, no token, no gh" {
  grep -q 'git ls-remote --tags' "$VER"
  grep -q 'GIT_TERMINAL_PROMPT=0' "$VER"
  grep -q 'curl -fsS --max-time' "$VER"
  ! grep -nE 'wget|\bgh |token|TOKEN|[Aa]uthorization|curl .*(-u |--user|-n )' "$VER"
}

@test "two plugin roots sharing one cache do not ping-pong: a pm mismatch re-checks at most once a minute" {
  _remote ccxp-skills--v5.1.0
  local a b; a=$(_plugin 5.0.0)
  run _ver "$a"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
  # another session's plugin root (different mtime) reads the same cache: fetched is seconds old, so no lookup
  b="$BATS_TEST_TMPDIR/plugin-b"; mkdir -p "$b/.claude-plugin"; cp "$a/.claude-plugin/plugin.json" "$b/.claude-plugin/"; touch -t 203001010000 "$b/.claude-plugin/plugin.json"
  git -C "$HUD_VERSION_REMOTE" tag ccxp-skills--v5.2.0
  run _ver "$b"
  [ "$(jq -r .latest <<<"$output")" = "5.1.0" ]
}

# --- unreleased commits (commits on main after the installed version's tag) ---

# $1 = ahead_by, then the commit messages oldest first -> a GitHub compare answer in $BATS_TEST_TMPDIR/compare.json
_compare() {
  local n="$1"; shift
  jq -n -c --argjson n "$n" '{ahead_by: $n, commits: ($ARGS.positional | map({commit: {message: .}}))}' --args "$@" > "$BATS_TEST_TMPDIR/compare.json"
  export HUD_UNRELEASED_URL="file://$BATS_TEST_TMPDIR/compare.json"
}

@test "unreleased: the count only, never any commit subject" {
  _remote ccxp-skills--v5.0.0
  _compare 4 "chore: one" "fix: two"$'\n\n'"body text" "feat(hud): three" "docs: four"
  run _ver "$(_plugin 5.0.0)"
  [ "$status" -eq 0 ]
  [ "$(jq -c .unreleased <<<"$output")" = '{"count":4}' ]
  [[ "$output" != *"docs: four"* ]]
}

@test "unreleased: the key is absent for zero commits, an unreadable answer and an unreachable API" {
  _remote ccxp-skills--v5.0.0
  _compare 0
  run _ver "$(_plugin 5.0.0)"
  [ "$(jq 'has("unreleased")' <<<"$output")" = false ]
  rm -rf "$HUD_VERSION_STATE_DIR"
  echo 'not json' > "$BATS_TEST_TMPDIR/compare.json"
  run _ver "$(_plugin 5.0.0)"
  [ "$(jq 'has("unreleased")' <<<"$output")" = false ]
  rm -rf "$HUD_VERSION_STATE_DIR"
  export HUD_UNRELEASED_URL="file://$BATS_TEST_TMPDIR/missing.json"
  run _ver "$(_plugin 5.0.0)"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("unreleased")' <<<"$output")" = false ]
  [ "$(jq -r .installed <<<"$output")" = 5.0.0 ]
}

@test "unreleased: cached for an hour (no second request), refreshed after, old answer kept when the refresh fails" {
  _remote ccxp-skills--v5.0.0
  local p; p="$(_plugin 5.0.0)"
  _compare 2 "a" "b"
  run _ver "$p"; [ "$(jq .unreleased.count <<<"$output")" = 2 ]
  _compare 9 "x"
  run _ver "$p"; [ "$(jq .unreleased.count <<<"$output")" = 2 ]   # still the cached answer
  local f="$HUD_VERSION_STATE_DIR/unreleased.json"
  jq -c '.fetched -= 4000' "$f" > "$f.t" && mv "$f.t" "$f"
  run _ver "$p"; [ "$(jq .unreleased.count <<<"$output")" = 9 ]   # TTL passed: refreshed
  export HUD_UNRELEASED_URL="file://$BATS_TEST_TMPDIR/missing.json"
  jq -c '.fetched -= 4000' "$f" > "$f.t" && mv "$f.t" "$f"
  run _ver "$p"; [ "$(jq .unreleased.count <<<"$output")" = 9 ]   # offline: last answer kept
}

@test "unreleased: another installed version or repo never shows the old answer" {
  _remote ccxp-skills--v5.0.0 ccxp-skills--v5.1.0
  _compare 3 "a" "b" "c"
  run _ver "$(_plugin 5.0.0)"; [ "$(jq .unreleased.count <<<"$output")" = 3 ]
  export HUD_UNRELEASED_URL="file://$BATS_TEST_TMPDIR/missing.json"
  local f="$HUD_VERSION_STATE_DIR/unreleased.json"
  jq -c '.fetched -= 100' "$f" > "$f.t" && mv "$f.t" "$f"
  run _ver "$(_plugin 5.1.0)"   # the cache was written for 5.0.0
  [ "$(jq 'has("unreleased")' <<<"$output")" = false ]
}

@test "unreleased: the compare URL names the installed tag and the repo from plugin.json" {
  source "$VER"
  [ "$(hvu-api-url https://github.com/Acme/fork 5.2.0)" = "https://api.github.com/repos/Acme/fork/compare/ccxp-skills--v5.2.0...main" ]
}

@test "unreleased: never blocks (no sync): first call answers at once without the key, version off prints null" {
  _remote ccxp-skills--v5.0.0
  _compare 2 "a" "b"
  unset CCXP_HUD_VERSION_SYNC
  run _ver "$(_plugin 5.0.0)"
  [ "$status" -eq 0 ]
  [ "$(jq 'has("unreleased")' <<<"$output")" = false ]
  [ "$(_ver "$(_plugin 5.0.0)" 0)" = null ]
}

@test "unreleased: a capped answer (fewer commits listed than ahead_by) still gives the count" {
  _remote ccxp-skills--v5.0.0
  _compare 300 "a" "b"
  run _ver "$(_plugin 5.0.0)"
  [ "$(jq -c .unreleased <<<"$output")" = '{"count":300}' ]
}

@test "unreleased: an old cache file that still holds subjects never leaks them" {
  _remote ccxp-skills--v5.0.0
  local p; p="$(_plugin 5.0.0)"
  _compare 2 "a" "b"
  run _ver "$p"
  local f="$HUD_VERSION_STATE_DIR/unreleased.json"
  jq -c '. + {subjects: ["secret subject"]}' "$f" > "$f.t" && mv "$f.t" "$f"
  run _ver "$p"
  [ "$(jq -c .unreleased <<<"$output")" = '{"count":2}' ]
  [[ "$output" != *"secret subject"* ]]
}
