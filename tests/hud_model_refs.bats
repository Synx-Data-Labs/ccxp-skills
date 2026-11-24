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
