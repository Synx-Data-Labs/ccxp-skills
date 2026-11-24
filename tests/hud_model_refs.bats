#!/usr/bin/env bats
# Regression guard (T20261124-502781): hud/model.ts once called busVariants after a refactor deleted its definition, so the bus
# cell would have thrown at runtime. The TS suites need the claude-code test runner, so this checks statically, with bats only,
# that every `*Variants(` helper hud/model.ts calls is defined in hud/model.ts.

setup() {
  MODEL="$BATS_TEST_DIRNAME/../hud/model.ts"
}

@test "every xVariants helper called in hud/model.ts is defined there" {
  called=$(grep -v '^ *\(//\|\*\|/\*\)' "$MODEL" | grep -oE '\b[a-zA-Z]+Variants\(' | tr -d '(' | sort -u)
  [ -n "$called" ]
  for fn in $called; do
    grep -qE "^(export )?function $fn\(" "$MODEL" || { echo "undefined helper: $fn"; return 1; }
  done
}

@test "the guard catches an undefined helper" {
  tmp="$BATS_TEST_TMPDIR/model.ts"
  grep -v 'function busVariants' "$MODEL" > "$tmp"
  ! grep -qE "^(export )?function busVariants\(" "$tmp"
  grep -qE '\bbusVariants\(' "$tmp"
}
