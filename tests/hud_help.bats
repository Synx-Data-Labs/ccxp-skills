#!/usr/bin/env bats
# Guard for /hud help (T20261122-212315): every HUD cell has a section in hud/HELP.md, the one source of the help text.
# The TS suites in hud/ need the claude-code test runner; these run anywhere with bats.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HELP="$ROOT/hud/HELP.md"
}

# Topic names and aliases of HELP.md, one per line.
topics() {
  sed -n 's/^## //p' "$HELP" | tr '|,' '\n\n' | sed 's/^ *//; s/ *$//' | tr 'A-Z' 'a-z'
}

has_topic() { topics | grep -Fxq "$1"; }

@test "every field in hud/config.ts ALL_FIELDS has a help topic" {
  fields=$(sed -n "s/^export const ALL_FIELDS.*= \[\(.*\)\].*/\1/p" "$ROOT/hud/config.ts" | tr -d "' " | tr ',' '\n')
  [ -n "$fields" ]
  for f in $fields; do
    has_topic "$f" || { echo "no help topic for field: $f"; false; }
  done
}

@test "every case of itemFor in hud/model.ts has a help topic" {
  cases=$(awk '/^function itemFor/{on=1} on&&/^    case /{gsub(/.*case \x27|\x27.*/,""); print} on&&/^}/{exit}' "$ROOT/hud/model.ts")
  [ -n "$cases" ]
  for c in $cases; do
    has_topic "$c" || { echo "no help topic for model.ts cell: $c"; false; }
  done
}

@test "the other cells and meta topics have a section" {
  for t in overview ap24h stalled ci version colors details config; do
    has_topic "$t" || { echo "no help topic: $t"; false; }
  done
}

@test "README points at HELP.md and register.tsx reads it" {
  run grep -F '(HELP.md)' "$ROOT/hud/README.md"
  [ "$status" -eq 0 ]
  run grep -F 'hud/HELP.md' "$ROOT/hud/register.tsx"
  [ "$status" -eq 0 ]
}
