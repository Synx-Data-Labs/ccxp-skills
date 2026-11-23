#!/usr/bin/env bats
# HUD bus cell data (T20261123-244661): hud-bus.sh and the `bus` key of hud-data.sh --json. Local files only.

load test_helper

BUSH="$REPO_ROOT/hud/scripts/hud-bus.sh"
BUS="$REPO_ROOT/_bus/bus.sh"

setup() {
  umask 077
  export CCXP_BUS_ROOT="$BATS_TEST_TMPDIR/bus" HOME="$BATS_TEST_TMPDIR/h" CCXP_BUS_SESSION_PID="$$"
  P="$BATS_TEST_TMPDIR/profiles"; mkdir -p "$HOME" "$P/prof-home" "$P/prof-work"
  unset CCXP_BUS_NAME
  as home init --name home >/dev/null; as work init --name work >/dev/null
  as work deliver --register </dev/null
}

as() { local a="$1"; shift; CLAUDE_CONFIG_DIR="$P/prof-$a" bash "$BUS" "$@"; }
cell() { ( CLAUDE_CONFIG_DIR="$P/prof-work"; source "$BUSH"; hud-bus-json "${1:-$REPO_ROOT}" "${2:-1}" ); }

@test "status --json: nothing while nothing is unread, count and newest sender after" {
  run as work status --json; [ -z "$output" ]
  as home send --to work a >/dev/null; as home send --to work b >/dev/null
  run as work status --json
  [ "$output" = '{"unread":2,"from":"home"}' ]
  as work deliver </dev/null >/dev/null
  run as work status --json; [ -z "$output" ]
}

@test "cell: unread notes give {unread, from}; read, none, off and a missing script give null" {
  run cell; [ "$output" = null ]
  as home send --to work hi >/dev/null
  run cell; [ "$output" = '{"unread":1,"from":"home"}' ]
  run cell "$REPO_ROOT" 0; [ "$output" = null ]
  run cell "$BATS_TEST_TMPDIR/old-plugin"; [ "$output" = null ]
  as work deliver </dev/null >/dev/null
  run cell; [ "$output" = null ]
}

@test "cell: a profile without bus config gets null and nothing is created" {
  mkdir -p "$P/prof-plain"
  run bash -c "CLAUDE_CONFIG_DIR='$P/prof-plain'; source '$BUSH'; hud-bus-json '$REPO_ROOT' 1"
  [ "$output" = null ]
}

@test "cell: the helper never writes the cursor or takes a lock" {
  as home send --to work hi >/dev/null
  before="$(find "$CCXP_BUS_ROOT" -type f | sort | xargs ls -l | awk '{print $5, $9}')"
  cell >/dev/null
  [ "$(find "$CCXP_BUS_ROOT" -type f | sort | xargs ls -l | awk '{print $5, $9}')" = "$before" ]
  [ -z "$(find "$CCXP_BUS_ROOT/lock" -type f)" ]
}

@test "hud-data.sh --json carries bus; show_bus false turns it to null" {
  as home send --to work hi >/dev/null
  run bash -c "echo '{\"cwd\":\"$BATS_TEST_TMPDIR\"}' | CLAUDE_CONFIG_DIR='$P/prof-work' bash '$REPO_ROOT/hud/scripts/hud-data.sh'"
  [ "$(jq -c .bus <<<"$output")" = '{"unread":1,"from":"home"}' ]
  run bash -c "echo '{\"cwd\":\"$BATS_TEST_TMPDIR\",\"show_bus\":false}' | CLAUDE_CONFIG_DIR='$P/prof-work' bash '$REPO_ROOT/hud/scripts/hud-data.sh'"
  [ "$(jq -c .bus <<<"$output")" = null ]
}

@test "hostile status output never reaches the cell: only a count and a plain name survive" {
  fake="$BATS_TEST_TMPDIR/plug"; mkdir -p "$fake/_bus"
  printf '#!/bin/sh\nprintf %%s '"'"'{"unread":3,"from":"Home\\u001b[31m x"}'"'"'\n' > "$fake/_bus/bus.sh"
  run cell "$fake"
  [ "$output" = '{"unread":3,"from":""}' ]
}
