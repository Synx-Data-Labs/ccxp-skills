#!/usr/bin/env bats
# Tests for customer-support/scripts/deliver_gate.sh (T20261012-373882).
# curl I/O is injected via the CS_CURL seam (mirrors _gh/ci-triage.sh's
# CI_TRIAGE_GH convention).

load test_helper
setup() {
  source "$REPO_ROOT/customer-support/scripts/deliver_gate.sh"
  cd "$BATS_TEST_TMPDIR"
}

_stub_curl() {
  # $1 = http code to return for every -I call
  cat > curl-stub.sh <<STUB
#!/usr/bin/env bash
echo -n "$1"
STUB
  chmod +x curl-stub.sh
  CS_CURL="$BATS_TEST_TMPDIR/curl-stub.sh"
}

@test "a 200 response verifies" {
  _stub_curl 200
  run cs-deliver-check-url "https://example.test/pkg.rpm"
  [ "$status" -eq 0 ]
}

@test "301 and 302 also verify (Cloudsmith CDN redirects)" {
  _stub_curl 301
  run cs-deliver-check-url "https://example.test/pkg.rpm"
  [ "$status" -eq 0 ]
  _stub_curl 302
  run cs-deliver-check-url "https://example.test/pkg.rpm"
  [ "$status" -eq 0 ]
}

@test "a 404 does NOT verify and blocks delivery" {
  _stub_curl 404
  run cs-deliver-check-url "https://example.test/pkg.rpm"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 404"* ]]
}

@test "a non-200/301/302 regression case: synxdb-support#21-shaped silent publish failure" {
  # The exact failure this gate exists for: a self-reported "delivered"
  # where the actual artifact never published.
  _stub_curl 000
  run cs-deliver-check-url "https://example.test/never-published.rpm"
  [ "$status" -eq 1 ]
}

@test "check-urls requires ALL urls to verify" {
  _stub_curl 200
  run cs-deliver-check-urls "https://a.test" "https://b.test"
  [ "$status" -eq 0 ]
  _stub_curl 500
  run cs-deliver-check-urls "https://a.test" "https://b.test"
  [ "$status" -eq 1 ]
}

@test "check-urls with zero urls fails (a generic delivery needs evidence)" {
  run cs-deliver-check-urls
  [ "$status" -eq 1 ]
  [[ "$output" == *"no URL(s) to verify"* ]]
}

@test "release-gate delegates to the given links script and propagates its exit code" {
  cat > fake-links.sh <<'EOF'
#!/usr/bin/env bash
echo "called with: $*"
exit 7
EOF
  chmod +x fake-links.sh
  run cs-deliver-release-gate "$BATS_TEST_TMPDIR/fake-links.sh" sbom.json "Hashdata.ai"
  [ "$status" -eq 7 ]
  [[ "$output" == *"sbom.json Hashdata.ai"* ]]
}

@test "CLI entrypoint dispatches check-urls" {
  _stub_curl 200
  run env CS_CURL="$BATS_TEST_TMPDIR/curl-stub.sh" bash "$REPO_ROOT/customer-support/scripts/deliver_gate.sh" check-urls "https://a.test"
  [ "$status" -eq 0 ]
}
