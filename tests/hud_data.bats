#!/usr/bin/env bats
# Tests for hud/scripts/hud-data.sh (the ccxp-hud mod's JSON data helper,
# T20261022-345549). Fixture repos only; never the developer's real state.

load test_helper
HUD="$REPO_ROOT/hud/scripts/hud-data.sh"
SCRIPT="$REPO_ROOT/hud/scripts/hud-lib.sh"

setup() {
  isolate_claimant_state
  export CCXP_LEDGER_FILE="$BATS_TEST_TMPDIR/ledger.json"
  export LAST_INPUT_STATE_DIR="$BATS_TEST_TMPDIR/last-input"
  # Repo-identity fields: never read the developer's real gh config, direnv or cache.
  export CCXP_HUD_CACHE_DIR="$BATS_TEST_TMPDIR/hud-cache"
  export CCXP_HUD_CACHE_TTL=60
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/no-xdg"
  unset GH_CONFIG_DIR
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/fakebin/direnv"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/direnv"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

# Resolve symlinks (macOS /var -> /private/var) the way the helper does, via
# git's toplevel, or the id would not match the helper's.
_clone_id() { bash -c "source '$SCRIPT'; sl-clone-id \"\$(git -C '$1' rev-parse --show-toplevel)\""; }

_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/dev/TODO"
  git -C "$dir" init -q -b main
  printf '%s' "$dir"
}

# $1 repo, $2 json state body (written verbatim)
_state() { printf '%s' "$2" > "$1/dev/.autopilot-state.json"; }

_iso_ago() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
_iso_ahead() { date -u -v+"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }

_hud() { # $1 repo, rest = helper args
  local repo="$1"; shift
  printf '{"cwd":"%s","session_id":"sess1"}' "$repo" | bash "$HUD" "$@"
}

@test "hud-data.sh is executable and sourceable without running main" {
  [ -x "$HUD" ]
  run bash -c "source '$HUD'; type hud-data >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "--json: no task, no autopilot, branch from the repo" {
  local repo; repo=$(_make_repo r-plain)
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .task_id <<<"$output")" = "" ]
  [ "$(jq -r .branch <<<"$output")" = "main" ]
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
}

@test "--json: claimed task id and title, never the claimed_by value" {
  local repo cid; repo=$(_make_repo r-claimed); cid=$(_clone_id "$repo")
  cat > "$repo/dev/TODO/T20260427-242654-x.md" <<EOT
---
claimed_by: ${cid}
---
# T20260427-242654: Fix the thing
EOT
  run _hud "$repo" --json
  [ "$(jq -r .task_id <<<"$output")" = "T20260427-242654" ]
  [ "$(jq -r .task_title <<<"$output")" = "Fix the thing" ]
  [[ "$output" != *"$cid"* ]]
}

@test "--json: a task claimed by another clone is not shown" {
  local repo; repo=$(_make_repo r-other)
  printf -- '---\nclaimed_by: otherhost:/other\n---\n# T20260427-242654: Not mine\n' > "$repo/dev/TODO/T20260427-242654-x.md"
  run _hud "$repo" --json
  [ "$(jq -r .task_id <<<"$output")" = "" ]
}

@test "--json: autopilot running normally" {
  local repo; repo=$(_make_repo r-run)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 90)\",\"end_time\":\"$(_iso_ahead 210)\",\"stuck_count\":3,\"cycle_count\":10,\"last_task\":{\"id\":\"T1-2\",\"slug\":\"s\"}}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.status <<<"$output")" = "running" ]
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[r]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "2" ]
  [ "$(jq -r .autopilot.requested_hr <<<"$output")" = "5" ]
  [ "$(jq -r .autopilot.stuck <<<"$output")" = "3" ]
  [ "$(jq -r .autopilot.cycle <<<"$output")" = "10" ]
  [ "$(jq -r .autopilot.last_task <<<"$output")" = "T1-2" ]
}

@test "--json: autopilot backing off is [b]" {
  local repo; repo=$(_make_repo r-backoff)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":2,\"cycle_count\":4,\"last_outcome\":\"stuck\",\"last_stuck_reason\":\"ci red\"}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[b]" ]
  [ "$(jq -r .autopilot.last_outcome <<<"$output")" = "stuck" ]
  [ "$(jq -r .autopilot.stuck_reason <<<"$output")" = "ci red" ]
}

@test "--json: autopilot stopped is [s] with the stop reason" {
  local repo; repo=$(_make_repo r-stop)
  _state "$repo" '{"status":"stopped","started_at":"2026-01-01T00:00:00Z","end_time":"2026-01-01T05:00:00Z","stuck_count":1,"cycle_count":3,"last_cycle_at":"2026-01-01T02:00:00Z","stop_reason":"window closed"}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[s]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "2" ]
  [ "$(jq -r .autopilot.stop_reason <<<"$output")" = "window closed" ]
}

@test "--json: autopilot paused is [p], frozen at paused_at" {
  local repo; repo=$(_make_repo r-pause)
  _state "$repo" '{"status":"paused","started_at":"2026-01-01T00:00:00Z","end_time":"2026-01-01T05:00:00Z","paused_at":"2026-01-01T01:00:00Z","stuck_count":0,"cycle_count":2}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.status <<<"$output")" = "paused" ]
  [ "$(jq -r .autopilot.prefix <<<"$output")" = "[p]" ]
  [ "$(jq -r .autopilot.elapsed_hr <<<"$output")" = "1" ]
}

@test "--json: missing, malformed or garbage state gives autopilot null, exit 0" {
  local repo; repo=$(_make_repo r-bad)
  _state "$repo" '{not json'
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
  _state "$repo" '{"status":"running","started_at":"not-a-date","end_time":"also-not","stuck_count":1,"cycle_count":1}'
  run _hud "$repo" --json
  [ "$(jq -r .autopilot <<<"$output")" = "null" ]
}

@test "--json: detached HEAD gives an empty branch" {
  local repo; repo=$(_make_repo r-detached)
  git_identity "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" checkout -q --detach
  run _hud "$repo" --json
  [ "$(jq -r .branch <<<"$output")" = "" ]
}

@test "--json: a git worktree reports its own branch" {
  local repo; repo=$(_make_repo r-wt)
  git_identity "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" worktree add -q -b wt-branch "$BATS_TEST_TMPDIR/wt"
  run _hud "$BATS_TEST_TMPDIR/wt" --json
  [ "$(jq -r .branch <<<"$output")" = "wt-branch" ]
  [ "$(jq -r .worktree <<<"$output")" = "wt" ]
}

@test "--json: the main checkout has an empty worktree name" {
  local repo; repo=$(_make_repo r-main-wt)
  run _hud "$repo" --json
  [ "$(jq -r .worktree <<<"$output")" = "" ]
}

@test "--json: has no last_input text key, and --with-last-input is ignored" {
  local repo; repo=$(_make_repo r-last)
  mkdir -p "$LAST_INPUT_STATE_DIR"
  printf 'hello there' > "$LAST_INPUT_STATE_DIR/sess1"
  run _hud "$repo" --json --with-last-input
  [ "$(jq -r 'has("last_input")' <<<"$output")" = "false" ]
  [[ "$output" != *"hello there"* ]]
}

@test "unparseable stdin or a non-repo cwd still prints valid JSON and exits 0" {
  run bash -c "echo garbage | bash '$HUD' --json"
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
  run bash -c "echo '{\"cwd\":\"/nonexistent/dir\"}' | bash '$HUD' --json"
  [ "$status" -eq 0 ]
  jq -e . <<<"$output" >/dev/null
}

@test "the helper makes no direct network call or home write (CI goes through hud-ci.sh, see hud_ci.bats)" {
  ! grep -nE 'curl|wget|https?://|> *"?\$HOME|~/\.claude' "$HUD"
}

@test "--json: merged_count is surfaced, a missing one is 0, ledger is null without a file" {
  local repo; repo=$(_make_repo r-merged)
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":0,\"cycle_count\":4,\"merged_count\":3}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.merged <<<"$output")" = "3" ]
  [ "$(jq -r .ledger <<<"$output")" = "null" ]
  _state "$repo" "{\"status\":\"running\",\"started_at\":\"$(_iso_ago 30)\",\"end_time\":\"$(_iso_ahead 270)\",\"stuck_count\":0,\"cycle_count\":4}"
  run _hud "$repo" --json
  [ "$(jq -r .autopilot.merged <<<"$output")" = "0" ]
}

@test "--json: ledger written by ledger.sh is passed through; corrupt ledger is null" {
  local repo; repo=$(_make_repo r-ledger)
  bash "$REPO_ROOT/hud/scripts/ledger.sh" start 230 "do it"
  bash "$REPO_ROOT/hud/scripts/ledger.sh" park k5
  run _hud "$repo" --json
  [ "$(jq -r .ledger.lifetime_jobs <<<"$output")" = "230" ]
  [ "$(jq -r '.ledger.running[0].title' <<<"$output")" = "do it" ]
  [ "$(jq -r .ledger.parked <<<"$output")" = "1" ]
  echo 'garbage' > "$CCXP_LEDGER_FILE"
  run _hud "$repo" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .ledger <<<"$output")" = "null" ]
}

@test "--json: last_input_at is the cache file mtime, 0 when there is none" {
  local repo; repo=$(_make_repo r-lastat)
  run _hud "$repo" --json
  [ "$(jq -r .last_input_at <<<"$output")" = "0" ]
  mkdir -p "$LAST_INPUT_STATE_DIR"; : > "$LAST_INPUT_STATE_DIR/sess1"
  touch -t 202601010000 "$LAST_INPUT_STATE_DIR/sess1"
  run _hud "$repo" --json
  [ "$(jq -r '.last_input_at > 1700000000' <<<"$output")" = "true" ]
}

# --- repo identity fields (repo_slug, repo_root, cwd, head, dirty, gh_account); `repo` keeps its name-only shape ---

# A gh config dir with a hosts.yml: $1 name, $2 user. Prints the dir. The token
# line proves the helper never prints it.
_gh_dir() {
  local d="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$d"
  printf 'github.com:\n    users:\n        %s:\n            oauth_token: SECRET-TOKEN\n    git_protocol: ssh\n    user: %s\n    oauth_token: SECRET-TOKEN\n' "$2" "$2" > "$d/hosts.yml"
  printf '%s' "$d"
}

# Stand-in for direnv. $1 = shell body. Default (see setup) is "direnv blocked".
_fake_direnv() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$BATS_TEST_TMPDIR/fakebin/direnv"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/direnv"
}

_commit() { git_identity "$1"; git -C "$1" commit -q --allow-empty -m init; }

@test "--json: a repo without a remote is named after its folder; repo_root and cwd are reported" {
  local repo; repo=$(_make_repo r-noremote)
  run _hud "$repo" --json
  [ "$(jq -r .repo <<<"$output")" = "r-noremote" ]
  [ "$(jq -r .repo_slug <<<"$output")" = "r-noremote" ]
  [ "$(jq -r .repo_root <<<"$output")" = "$(git -C "$repo" rev-parse --show-toplevel)" ]
  [ "$(jq -r .cwd <<<"$output")" = "$repo" ]
  [ "$(jq -r .head <<<"$output")" = "" ]
}

@test "--json: repo_slug is owner/name for https, scp-style, ssh-alias and ssh:// remotes (repo stays the name)" {
  local repo url; repo=$(_make_repo r-remotes)
  for url in https://example.com/acme/widgets.git git@example.com:acme/widgets.git git@github-alias:acme/widgets \
             ssh://git@example.com/acme/widgets.git https://example.com/acme/widgets/; do
    git -C "$repo" remote remove origin 2>/dev/null || true
    git -C "$repo" remote add origin "$url"
    run _hud "$repo" --json
    [ "$(jq -r .repo_slug <<<"$output")" = "acme/widgets" ]
    [ "$(jq -r .repo <<<"$output")" = "widgets" ]
  done
}

@test "--json: cwd in a subfolder still reports the repo root" {
  local repo; repo=$(_make_repo r-sub)
  mkdir -p "$repo/a/b"
  run _hud "$repo/a/b" --json
  [ "$(jq -r .repo_root <<<"$output")" = "$(git -C "$repo" rev-parse --show-toplevel)" ]
  [ "$(jq -r .cwd <<<"$output")" = "$repo/a/b" ]
}

@test "--json: dirty counts changed tracked files only, not untracked ones" {
  local repo; repo=$(_make_repo r-dirty)
  git_identity "$repo"
  echo one > "$repo/f1"; echo two > "$repo/f2"
  git -C "$repo" add f1 f2; git -C "$repo" commit -q -m init
  run _hud "$repo" --json
  [ "$(jq -r .dirty <<<"$output")" = "0" ]
  echo more >> "$repo/f1"
  echo new > "$repo/untracked"
  run _hud "$repo" --json
  [ "$(jq -r .dirty <<<"$output")" = "1" ]
  echo more >> "$repo/f2"
  run _hud "$repo" --json
  [ "$(jq -r .dirty <<<"$output")" = "2" ]
}

@test "--json: dirty is capped at 99" {
  local repo i; repo=$(_make_repo r-dirty-cap)
  git_identity "$repo"
  for i in $(seq 1 105); do echo x > "$repo/f$i"; done
  git -C "$repo" add . ; git -C "$repo" commit -q -m init
  for i in $(seq 1 105); do echo y >> "$repo/f$i"; done
  run _hud "$repo" --json
  [ "$(jq -r .dirty <<<"$output")" = "99" ]
}

@test "--json: the helper never writes to the repo (no index refresh)" {
  local repo; repo=$(_make_repo r-nowrite)
  git_identity "$repo"; echo a > "$repo/f"; git -C "$repo" add f; git -C "$repo" commit -q -m init
  touch -t 202001010000 "$repo/f"   # stat-dirty file: a plain `git status` would refresh the index
  local before; before=$(cksum < "$repo/.git/index")
  run _hud "$repo" --json
  [ ! -e "$repo/.git/index.lock" ]
  [ "$(cksum < "$repo/.git/index")" = "$before" ]
}

@test "--json: detached HEAD gives the short commit id in head and an empty branch" {
  local repo; repo=$(_make_repo r-detached-head)
  _commit "$repo"
  git -C "$repo" checkout -q --detach
  run _hud "$repo" --json
  [ "$(jq -r .branch <<<"$output")" = "" ]
  [ "$(jq -r .head <<<"$output")" = "$(git -C "$repo" rev-parse --short HEAD)" ]
  [ -n "$(jq -r .head <<<"$output")" ]
}

@test "--json: a linked worktree keeps the main repo's name and reports its own root" {
  local repo; repo=$(_make_repo r-wt-name)
  _commit "$repo"
  git -C "$repo" worktree add -q -b wt2 "$BATS_TEST_TMPDIR/wt2-dir"
  run _hud "$BATS_TEST_TMPDIR/wt2-dir" --json
  [ "$(jq -r .repo_slug <<<"$output")" = "r-wt-name" ]
  [ "$(jq -r .repo_root <<<"$output")" = "$(git -C "$BATS_TEST_TMPDIR/wt2-dir" rev-parse --show-toplevel)" ]
  [ "$(jq -r .worktree <<<"$output")" = "wt2-dir" ]
  [ "$(jq -r .branch <<<"$output")" = "wt2" ]
}

@test "--json: outside a git repo the repo identity fields are null, repo is the folder name, cwd is reported" {
  local d="$BATS_TEST_TMPDIR/not-a-repo"; mkdir -p "$d"
  run _hud "$d" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .repo <<<"$output")" = "not-a-repo" ]
  [ "$(jq -r .repo_slug <<<"$output")" = "null" ]
  [ "$(jq -r .repo_root <<<"$output")" = "null" ]
  [ "$(jq -r .dirty <<<"$output")" = "null" ]
  [ "$(jq -r .gh_account <<<"$output")" = "null" ]
  [ "$(jq -r .head <<<"$output")" = "" ]
  [ "$(jq -r .cwd <<<"$output")" = "$d" ]
  [ "$(jq -r .branch <<<"$output")" = "" ]
}

@test "--json: the fields follow the cwd the helper is given, not the process cwd" {
  local a b; a=$(_make_repo r-follow-a); b=$(_make_repo r-follow-b)
  git -C "$b" checkout -q -b other
  cd "$a"
  run _hud "$b" --json
  [ "$(jq -r .repo <<<"$output")" = "r-follow-b" ]
  [ "$(jq -r .branch <<<"$output")" = "other" ]
  run bash -c "cd '$b' && echo '{}' | bash '$HUD' --json"
  [ "$(jq -r .repo <<<"$output")" = "r-follow-b" ]
}

@test "--json: gh_account comes from the .envrc GH_CONFIG_DIR and its hosts.yml, never the token" {
  local repo gh; repo=$(_make_repo r-gh); gh=$(_gh_dir gh-work work-user)
  printf 'export GH_CONFIG_DIR="%s"\n' "$gh" > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "work-user" ]
  [[ "$output" != *SECRET-TOKEN* ]]
}

@test "--json: gh_account expands \$HOME and ~, and follows source_up_if_exists to a parent .envrc" {
  local gh; gh=$(_gh_dir home/.config/gh-up up-user)
  export HOME="$BATS_TEST_TMPDIR/home"
  local parent="$BATS_TEST_TMPDIR/ws"; mkdir -p "$parent"
  printf 'export GH_CONFIG_DIR=$HOME/.config/gh-up\n' > "$parent/.envrc"
  local repo="$parent/child"; mkdir -p "$repo/dev/TODO"; git -C "$repo" init -q -b main
  printf 'source_up_if_exists\n' > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "up-user" ]
  printf 'export GH_CONFIG_DIR=~/.config/gh-up # comment\n' > "$parent/.envrc"
  CCXP_HUD_CACHE_TTL=0 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "up-user" ]
  printf 'export GH_CONFIG_DIR=${HOME}/.config/gh-up\n' > "$parent/.envrc"
  CCXP_HUD_CACHE_TTL=0 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "up-user" ]
}

@test "--json: a child .envrc without source_up hides the parent's GH_CONFIG_DIR (direnv semantics)" {
  local gh def parent repo; gh=$(_gh_dir gh-parent parent-user); def=$(_gh_dir xdg/gh default-user)
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  parent="$BATS_TEST_TMPDIR/ws2"; mkdir -p "$parent"
  printf 'export GH_CONFIG_DIR=%s\n' "$gh" > "$parent/.envrc"
  repo="$parent/child"; mkdir -p "$repo/dev/TODO"; git -C "$repo" init -q -b main
  printf 'export FOO=1\n' > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "default-user" ]
}

@test "--json: unresolvable GH_CONFIG_DIR values (other variables, command substitution) fall back to the default config" {
  local repo def; repo=$(_make_repo r-gh-unknown); def=$(_gh_dir xdg/gh default-user)
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  printf 'export GH_CONFIG_DIR=$(pwd)/x\n' > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "default-user" ]
  printf 'export GH_CONFIG_DIR=$OTHER/x\n' > "$repo/.envrc"
  CCXP_HUD_CACHE_TTL=0 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "default-user" ]
}

@test "--json: no .envrc uses the default gh config; no hosts.yml at all gives null" {
  local repo; repo=$(_make_repo r-gh-default)
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "null" ]
  _gh_dir xdg/gh default-user >/dev/null
  CCXP_HUD_CACHE_TTL=0 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "default-user" ]
}

@test "--json: hosts.yml with several hosts prefers github.com" {
  local repo gh; repo=$(_make_repo r-gh-hosts); gh="$BATS_TEST_TMPDIR/gh-multi"; mkdir -p "$gh"
  printf 'ghe.example.com:\n    user: enterprise-user\ngithub.com:\n    git_protocol: ssh\n    user: "public-user"\n' > "$gh/hosts.yml"
  printf 'export GH_CONFIG_DIR=%s\n' "$gh" > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "public-user" ]
}

@test "--json: direnv's answer wins over the .envrc parse, and the launch GH_CONFIG_DIR does not leak into it" {
  local repo launch via envrc; repo=$(_make_repo r-gh-direnv)
  launch=$(_gh_dir gh-launch launch-user); via=$(_gh_dir gh-via-direnv direnv-user); envrc=$(_gh_dir gh-envrc envrc-user)
  printf 'export GH_CONFIG_DIR=%s\n' "$envrc" > "$repo/.envrc"
  _fake_direnv 'if [ -n "${GH_CONFIG_DIR:-}" ]; then echo "$GH_CONFIG_DIR"; else echo "'"$via"'"; fi'
  GH_CONFIG_DIR="$launch" run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "direnv-user" ]
}

@test "--json: a failing or blocked direnv falls back to the .envrc parse" {
  local repo envrc; repo=$(_make_repo r-gh-blocked); envrc=$(_gh_dir gh-envrc2 envrc-user)
  printf 'export GH_CONFIG_DIR=%s\n' "$envrc" > "$repo/.envrc"
  _fake_direnv 'echo "direnv: error blocked" >&2; exit 1'
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "envrc-user" ]
}

@test "--json: the gh account is cached per root for the TTL, and TTL 0 disables the cache" {
  local repo a b; repo=$(_make_repo r-gh-cache); a=$(_gh_dir gh-a user-a); b=$(_gh_dir gh-b user-b)
  printf 'export GH_CONFIG_DIR=%s\n' "$a" > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-a" ]
  [ -n "$(ls "$CCXP_HUD_CACHE_DIR")" ]
  printf 'export GH_CONFIG_DIR=%s\n' "$b" > "$repo/.envrc"
  run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-a" ]
  CCXP_HUD_CACHE_TTL=0 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-b" ]
  # An expired entry is recomputed.
  CCXP_HUD_CACHE_TTL=1 run _hud "$repo" --json
  sleep 2
  printf 'export GH_CONFIG_DIR=%s\n' "$a" > "$repo/.envrc"
  CCXP_HUD_CACHE_TTL=1 run _hud "$repo" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-a" ]
}

@test "--json: a different root never reads another root's cache entry" {
  local r1 r2 a b; r1=$(_make_repo r-gh-c1); r2=$(_make_repo r-gh-c2); a=$(_gh_dir gh-c-a user-a); b=$(_gh_dir gh-c-b user-b)
  printf 'export GH_CONFIG_DIR=%s\n' "$a" > "$r1/.envrc"
  printf 'export GH_CONFIG_DIR=%s\n' "$b" > "$r2/.envrc"
  run _hud "$r1" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-a" ]
  run _hud "$r2" --json
  [ "$(jq -r .gh_account <<<"$output")" = "user-b" ]
}

@test "hud-lib: sl-run-timeout kills a slow command and returns non-zero" {
  run bash -c "source '$SCRIPT'; PATH=/usr/bin:/bin; start=\$(date +%s); sl-run-timeout 1 sleep 5; rc=\$?; echo rc=\$rc t=\$(( \$(date +%s) - start ))"
  [[ "$output" == *"rc="* ]]
  [[ "$output" != *"rc=0"* ]]
  [[ "$output" =~ t=[0-3]$ ]]
}

# The mod shows green READY when ledger.running is empty and yellow WORKING (N) otherwise
# (jobState in hud/model.ts); this pins the count it reads: 1 job, 2 jobs, back to 0.
@test "--json: ledger.running length is 0 when all jobs finished, N while N run" {
  local repo; repo=$(_make_repo r-jobstate)
  bash "$REPO_ROOT/hud/scripts/ledger.sh" start 230 "first"
  run _hud "$repo" --json
  [ "$(jq -r '.ledger.running | length' <<<"$output")" = "1" ]
  bash "$REPO_ROOT/hud/scripts/ledger.sh" start 231 "second"
  run _hud "$repo" --json
  [ "$(jq -r '.ledger.running | length' <<<"$output")" = "2" ]
  bash "$REPO_ROOT/hud/scripts/ledger.sh" finish 230
  bash "$REPO_ROOT/hud/scripts/ledger.sh" finish 231
  run _hud "$repo" --json
  [ "$(jq -r '.ledger.running | length' <<<"$output")" = "0" ]
  [ "$(jq -r '.ledger.lifetime_jobs' <<<"$output")" = "231" ]
}
