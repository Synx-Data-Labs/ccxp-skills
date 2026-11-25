#!/usr/bin/env bats
# Regression guard (T20261124-502781): hud/model.ts once called busVariants after a refactor deleted its definition, so the bus
# cell would have thrown at runtime. The TS suites need the claude-code test runner, so this checks statically, with bats only,
# that every `*Variants(` helper hud/model.ts calls is defined in hud/model.ts.

setup() {
  MODEL="$BATS_TEST_DIRNAME/../hud/model.ts"
}

# Prints each undefined helper of the file given as $1; empty output means every called helper is defined.
undefined_helpers() {
  local f="$1" fn
  for fn in $(grep -v '^ *\(//\|\*\|/\*\)' "$f" | grep -oE '\b[a-zA-Z]+Variants\(' | tr -d '(' | sort -u); do
    grep -qE "^(export )?function $fn\(" "$f" || echo "$fn"
  done
}

@test "every xVariants helper called in hud/model.ts is defined there" {
  grep -qE '\bbusVariants\(' "$MODEL"
  [ -z "$(undefined_helpers "$MODEL")" ]
}

@test "the guard catches an undefined helper" {
  tmp="$BATS_TEST_TMPDIR/model.ts"
  grep -v 'function busVariants' "$MODEL" > "$tmp"
  [ "$(undefined_helpers "$tmp")" = "busVariants" ]
}

# T20261124-273213: the details view splits AUTOPILOT from WORK; the behavioural cases live in hud/pure.test.ts
# (they need the claude-code runner), so this pins the structure statically.
@test "details builds an AUTOPILOT section before WORK, and WORK filters out the autopilot-flagged ledger rows" {
  grep -qE "sectionRows\('AUTOPILOT', statusCells" "$MODEL"
  grep -qE "section\('WORK', jobCells\)" "$MODEL"
  [ "$(grep -n "sectionRows('AUTOPILOT'" "$MODEL" | head -1 | cut -d: -f1)" -lt "$(grep -n "section('WORK'" "$MODEL" | cut -d: -f1)" ]
  grep -qE "led\.running\.filter\(j => !isApJob\(j\)\)" "$MODEL"
}

# The AUTOPILOT section is two lines: status cells, then progress cells (the behavioural cases are in hud/pure.test.ts).
@test "details AUTOPILOT has a status line (state, dop, next loop) and a progress line (24h and average, holds)" {
  grep -qE "const statusCells = \[apItem, dopSegs .*wakeItem\]" "$MODEL"
  grep -qE "const progressCells = \[apStats .*holdsItem\]" "$MODEL"
}
