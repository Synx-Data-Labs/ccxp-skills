#!/usr/bin/env bats
# Tests for customer-support/scripts/format_links.sh (T20261021-332125).
# FAKE tokens/URLs only — nothing here is a real entitlement token.

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/format_links.sh"
  cd "$BATS_TEST_TMPDIR"
  B="https://dl.cloudsmith.io/FAKETOKEN/synx/synxdb"
  cat > render.txt <<EOF2
synxdb 4.1.0+build.7 — Hashdata.ai download links (all packages, entitlement-scoped, HTTP verified).
Promotion labrun: https://github.com/example/repo/actions/runs/1
\`\`\`
synxdb 4.1.0+build.7 — Hashdata.ai download links
====================================================================================

RPM
----
core (synxdb-4.1.0+build.7.el9.x86_64.rpm):
  ${B}/rpm/el9/x86_64/synxdb-4.1.0+build.7.el9.x86_64.rpm

tools (synxdb-tools-1.0-1.noarch.rpm):
  ${B}/rpm/el9/noarch/synxdb-tools-1.0-1.noarch.rpm

DEB
----
core (synxdb_4.1.0+build.7_amd64.deb):
  ${B}/deb/pool/synxdb_4.1.0+build.7_amd64.deb

RAW
----
  ⚠ docs (docs.tgz): HTTP 404
src (src.tar.gz):
  ${B}/raw/src.tar.gz

\`\`\`
EOF2
}

@test "fence removed and rule lines dropped" {
  run cs-fmt-main < render.txt
  [ "$status" -eq 0 ]
  [[ "$output" != *'```'* ]]
  [[ "$output" != *"===="* ]]
  [[ "$output" != *"----"* ]]
}

@test "headings and one bullet per package" {
  run cs-fmt-main < render.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"### RPM"* ]]
  [[ "$output" == *"### DEB"* ]]
  [[ "$output" == *"### RAW"* ]]
  [[ "$output" == *'- **core** (`synxdb-4.1.0+build.7.el9.x86_64.rpm`): https://dl.cloudsmith.io/FAKETOKEN/synx/synxdb/rpm/el9/x86_64/synxdb-4.1.0+build.7.el9.x86_64.rpm'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^- \*\*')" -eq 4 ]
}

@test "URL multiset identical incl + and intro URL" {
  out=$(cs-fmt-main < render.txt)
  [ "$(cs-fmt-urls < render.txt)" = "$(printf '%s\n' "$out" | cs-fmt-urls)" ]
  [ "$(cs-fmt-urls < render.txt | wc -l | tr -d ' ')" -eq 5 ]
  printf '%s\n' "$out" | grep -q 'build.7_amd64.deb$'
}

@test "every URL line is exactly the fixture URL (no glued punctuation)" {
  out=$(cs-fmt-main < render.txt)
  while IFS= read -r u; do
    printf '%s\n' "$out" | grep -qE "(: |^- )${u//+/\\+}\$"
  done < <(cs-fmt-urls < render.txt | grep -v actions/runs)
}

@test "warning lines kept as bullets without a URL" {
  run cs-fmt-main < render.txt
  [[ "$output" == *"- ⚠ docs (docs.tgz): HTTP 404"* ]]
}

@test "empty input is refused with empty stdout" {
  run cs-fmt-main < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no download URLs"* ]]
}

@test "partial output (header only, no URLs) is refused" {
  printf 'synxdb 1 — x download links\n```\ntitle\n====\n' > partial.txt
  run cs-fmt-main < partial.txt
  [ "$status" -eq 1 ]
}

@test "partial output with a truncated tail still keeps every URL" {
  head -14 render.txt > cut.txt
  out=$(cs-fmt-main < cut.txt)
  [ "$(cs-fmt-urls < cut.txt)" = "$(printf '%s\n' "$out" | cs-fmt-urls)" ]
  [[ "$out" != *'```'* ]]
}

@test "assert-urls refuses on mismatch and never prints a URL" {
  run cs-fmt-assert-urls "https://dl.cloudsmith.io/FAKETOKEN/a" "https://dl.cloudsmith.io/FAKETOKEN/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mismatch"* ]]
  [[ "$output" != *FAKETOKEN* ]]
}

@test "assert-no-fence rejects a body with a fence around URLs" {
  run cs-fmt-assert-no-fence <<< $'x\n```\nhttps://a.example/x\n```'
  [ "$status" -eq 1 ]
  run cs-fmt-assert-no-fence <<< $'- **a** (`f`): https://a.example/x'
  [ "$status" -eq 0 ]
}

@test "check subcommand guards a posted body" {
  run bash "$REPO_ROOT/customer-support/scripts/format_links.sh" check <<< $'```\nhttps://a.example/x\n```'
  [ "$status" -eq 1 ]
}

@test "refusal paths keep stdout empty of URLs" {
  run cs-fmt-assert-urls "$(cs-fmt-urls < render.txt)" ""
  [ "$status" -eq 1 ]
  [[ "$output" != *dl.cloudsmith.io* ]]
}

@test "formatter takes stdin only; a --token flag is rejected" {
  run bash "$REPO_ROOT/customer-support/scripts/format_links.sh" format --token=x < render.txt
  [ "$status" -eq 1 ]
}
