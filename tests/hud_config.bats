#!/usr/bin/env bats
# Static checks for the /hud config rename and the always-on fill (the TS suites in hud/ need the
# claude-code test runner; these run anywhere with bats).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "/hud setup is gone from the hud mod and its docs" {
  # hud/README.md keeps one migration note naming the old command, so it is excluded.
  run grep -rnE --exclude=README.md '/hud setup|setupCi|withCi|SetupIo|args === .setup.' "$ROOT/hud" "$ROOT/types" "$ROOT/agent-pairing"
  [ "$status" -eq 1 ]
  run grep -nE '/hud setup' "$ROOT/README.md"
  [ "$status" -eq 1 ]
}

@test "the retired setup.ts files no longer exist; configure.ts does" {
  [ ! -e "$ROOT/hud/setup.ts" ]
  [ ! -e "$ROOT/hud/setup.test.ts" ]
  [ -f "$ROOT/hud/configure.ts" ]
}

@test "/hud fill on|off is gone: no subcommand, no withFill, no fill config key" {
  run grep -rnE 'fill on\|off|withFill|DEFAULTS\.fill\b|cfg\.fill\b' "$ROOT/hud/register.tsx" "$ROOT/hud/config.ts" "$ROOT/types/index.d.ts"
  [ "$status" -eq 1 ]
}

@test "register wires the config subcommand and always draws the fill with cfg.fillColor" {
  grep -q "arg === 'config'" "$ROOT/hud/register.tsx"
  grep -qF 'fillStyleFor(await themeOf($), cfg.fillColor)' "$ROOT/hud/register.tsx"
}

@test "fill colour defaults to gray and offers blue, green, yellow, purple" {
  grep -q "FILL_DEFAULT = 'gray'" "$ROOT/hud/fill.ts"
  grep -q "fillColor: FILL_DEFAULT" "$ROOT/hud/config.ts"
  for c in gray blue green yellow purple; do grep -qE "^  $c: \{ dark: '#[0-9a-f]{6}', light: '#[0-9a-f]{6}' \}" "$ROOT/hud/fill.ts"; done
}

@test "config wizard asks for the colour and persists fillColor with ci" {
  grep -q "header: 'Fill colour'" "$ROOT/hud/configure.ts"
  grep -qF 'withConfig(existing, { ci, fillColor, version })' "$ROOT/hud/configure.ts"
}

@test "config wizard asks whether to show the plugin version and persists version" {
  grep -q "header: 'Version'" "$ROOT/hud/configure.ts"
  grep -q "version: boolean" "$ROOT/types/index.d.ts"
  grep -qE "^  version: true," "$ROOT/hud/config.ts"
}
