#!/usr/bin/env bats
# nightly-rca/scripts/nightly-rca.sh: classify, last-green, pin-diff, sha-reachable, briefing.
# Fixtures only; gh is a shim (GH_BIN), nothing touches the network.

load test_helper

NR="$REPO_ROOT/nightly-rca/scripts/nightly-rca.sh"

setup() {
  export NR_NOW=1800000000
  GH_SHIM="$BATS_TEST_TMPDIR/gh"
  cat > "$GH_SHIM" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r/branches/main --jq .name") echo main ;;
  "api repos/o/r/branches/gone --jq .name") echo "Not Found (HTTP 404)" >&2; exit 1 ;;
  "api repos/o/r/branches/flaky --jq .name") echo "HTTP 503" >&2; exit 1 ;;
  "api repos/o/r/compare/main...aaaaaaa --jq .status") echo behind ;;
  "api repos/o/r/compare/main...bbbbbbb --jq .status") echo ahead ;;
  "api repos/o/r/compare/main...ccccccc --jq .status") echo "No commit found for SHA: ccccccc (HTTP 422)" >&2; exit 1 ;;
  "api repos/o/r/compare/main...ddddddd --jq .status") echo "HTTP 500" >&2; exit 1 ;;
  run\ list*) cat "$GH_FIXTURE" ;;
  *) echo "UNMAPPED $*" >&2; exit 97 ;;
esac
EOS
  chmod +x "$GH_SHIM"
  export GH_BIN="$GH_SHIM"
}

# iso <epoch>: UTC stamp (GNU date, then BSD date)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

@test "classify: concluded failure reports job, step and zero queue" {
  cat > "$BATS_TEST_TMPDIR/r.json" <<'EOF'
{"conclusion":"failure","createdAt":"2026-11-05T06:43:55Z","startedAt":"2026-11-05T06:43:55Z","updatedAt":"2026-11-05T07:08:52Z",
 "jobs":[{"name":"ok","conclusion":"success","steps":[]},{"name":"Prepare m","conclusion":"failure","steps":[{"name":"Phase 1.5: Commit","conclusion":"failure"}]}]}
EOF
  run bash "$NR" classify "$BATS_TEST_TMPDIR/r.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=failed"* ]]
  [[ "$output" == *"queue_min=0"* ]]
  [[ "$output" == *"run_min=24"* ]]
  [[ "$output" == *"job=Prepare m"* ]]
  [[ "$output" == *"step=Phase 1.5: Commit"* ]]
}

@test "classify: long queue with no conclusion is queued, not hung" {
  c="$(iso $((NR_NOW - 9*3600)))"; s="$(iso $((NR_NOW - 3600)))"; u="$(iso $((NR_NOW - 600)))"
  printf '{"conclusion":null,"createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[]}' "$c" "$s" "$u" > "$BATS_TEST_TMPDIR/r.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/r.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=queued"* ]]
  [[ "$output" == *"queue_min=480"* ]]
}

@test "classify: no update for 6+ hours is hung; success is green" {
  c="$(iso $((NR_NOW - 12*3600)))"; u="$(iso $((NR_NOW - 8*3600)))"
  printf '{"conclusion":null,"createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[]}' "$c" "$c" "$u" > "$BATS_TEST_TMPDIR/r.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/r.json"
  [[ "$output" == *"verdict=hung"* ]]
  printf '{"conclusion":"success","createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[]}' "$c" "$c" "$u" > "$BATS_TEST_TMPDIR/g.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/g.json"
  [[ "$output" == *"verdict=green"* ]]
}

@test "classify: unreadable input exits 3, missing arg exits 2" {
  run bash "$NR" classify "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 3 ]
  run bash "$NR" classify
  [ "$status" -eq 2 ]
}

@test "last-green: newest success older than the given run" {
  echo '[{"databaseId":50,"headSha":"s50"},{"databaseId":90,"headSha":"s90"},{"databaseId":70,"headSha":"s70"}]' > "$BATS_TEST_TMPDIR/l.json"
  GH_FIXTURE="$BATS_TEST_TMPDIR/l.json" run bash "$NR" last-green o/r wf.yml 80
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '70\ts70')" ]
}

@test "last-green: nothing older prints nothing; non-numeric id is a usage error" {
  echo '[{"databaseId":90,"headSha":"s90"}]' > "$BATS_TEST_TMPDIR/l.json"
  GH_FIXTURE="$BATS_TEST_TMPDIR/l.json" run bash "$NR" last-green o/r wf.yml 80
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$NR" last-green o/r wf.yml abc
  [ "$status" -eq 2 ]
}

@test "pin-diff: changed, added and removed components; unchanged stay out" {
  cat > "$BATS_TEST_TMPDIR/old.yml" <<'EOF'
version: "x"
components:
  - name: lightning-umbrella
    prepared_commit: prepared/upstream
  - name: database
    prepared_commit: abc1234
  - name: gone
    prepared_commit: dead000
artifacts:
  - type: rpm
EOF
  cat > "$BATS_TEST_TMPDIR/new.yml" <<'EOF'
components:
  - name: lightning-umbrella
    prepared_commit: prepared/upstream
  - name: database
    prepared_commit: "def5678"
  - name: fresh
    prepared_commit: beef111
EOF
  run bash "$NR" pin-diff "$BATS_TEST_TMPDIR/old.yml" "$BATS_TEST_TMPDIR/new.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'database\tabc1234\tdef5678\nfresh\t-\tbeef111\ngone\tdead000\t-')" ]
}

@test "sha-reachable: reachable, unreachable, missing" {
  run bash "$NR" sha-reachable o/r main aaaaaaa
  [ "$output" = reachable ]
  run bash "$NR" sha-reachable o/r main bbbbbbb
  [ "$output" = unreachable ]
  run bash "$NR" sha-reachable o/r main ccccccc
  [ "$status" -eq 0 ]
  [ "$output" = missing ]
}

@test "sha-reachable: unknown branch exits 3, other gh failure exits 4, bad sha exits 2" {
  run bash "$NR" sha-reachable o/r gone aaaaaaa
  [ "$status" -eq 3 ]
  run bash "$NR" sha-reachable o/r main ddddddd
  [ "$status" -eq 4 ]
  run bash "$NR" sha-reachable o/r main 'zz;rm'
  [ "$status" -eq 2 ]
}

@test "briefing: writes the fixed sections with mode 600 and refuses to overwrite" {
  run bash "$NR" briefing 123456 "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  f="$BATS_TEST_TMPDIR/nightly-rca-123456.md"
  [ "$output" = "$f" ]
  for h in '## Verdict' '## Timeline' '## Flow' '## Options' '## Who to ask'; do grep -q "^$h" "$f"; done
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ]
  run bash "$NR" briefing 123456 "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "sourceable without side effects; unknown subcommand exits 2" {
  run bash -c 'source "$1" && declare -F nightly-rca >/dev/null' _ "$NR"
  [ "$status" -eq 0 ]
  run bash "$NR" bogus
  [ "$status" -eq 2 ]
}

@test "classify: unusual conclusion is other; fresh in-progress run is running" {
  c="$(iso $((NR_NOW - 1200)))"; u="$(iso $((NR_NOW - 300)))"
  printf '{"conclusion":"startup_failure","createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[]}' "$c" "$c" "$u" > "$BATS_TEST_TMPDIR/o.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/o.json"
  [[ "$output" == *"verdict=other"* ]]
  printf '{"conclusion":null,"createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[]}' "$c" "$c" "$u" > "$BATS_TEST_TMPDIR/p.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/p.json"
  [[ "$output" == *"verdict=running"* ]]
}

@test "sha-reachable: bad repo or dotdot branch exit 2; non-404 branch probe failure exits 4" {
  run bash "$NR" sha-reachable 'o/r/../x' main aaaaaaa
  [ "$status" -eq 2 ]
  run bash "$NR" sha-reachable o/r 'a/../b' aaaaaaa
  [ "$status" -eq 2 ]
  run bash "$NR" sha-reachable o/r flaky aaaaaaa
  [ "$status" -eq 4 ]
}

@test "pin-diff: a manifest with no components yields no bogus row" {
  printf 'version: x\n' > "$BATS_TEST_TMPDIR/e.yml"
  printf 'components:\n  - name: a\n    prepared_commit: abc1234\n' > "$BATS_TEST_TMPDIR/n.yml"
  run bash "$NR" pin-diff "$BATS_TEST_TMPDIR/e.yml" "$BATS_TEST_TMPDIR/n.yml"
  [ "$output" = "$(printf 'a\t-\tabc1234')" ]
}

@test "briefing: creates a missing output directory" {
  run bash "$NR" briefing 99 "$BATS_TEST_TMPDIR/new/dir"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/new/dir/nightly-rca-99.md" ]
}

@test "classify: queue time comes from the earliest job start when the run startedAt equals createdAt" {
  c="$(iso $((NR_NOW - 10*3600)))"; j="$(iso $((NR_NOW - 2*3600)))"; u="$(iso $((NR_NOW - 600)))"
  printf '{"conclusion":null,"createdAt":"%s","startedAt":"%s","updatedAt":"%s","jobs":[{"name":"a","conclusion":null,"startedAt":"%s","steps":[]}]}' "$c" "$c" "$u" "$j" > "$BATS_TEST_TMPDIR/q.json"
  run bash "$NR" classify "$BATS_TEST_TMPDIR/q.json"
  [[ "$output" == *"queue_min=480"* ]]
  [[ "$output" == *"verdict=queued"* ]]
}

@test "sha-reachable: dot-dot repo exits 2" {
  run bash "$NR" sha-reachable ../.. main aaaaaaa
  [ "$status" -eq 2 ]
}
