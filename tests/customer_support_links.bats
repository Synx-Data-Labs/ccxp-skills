#!/usr/bin/env bats
# Tests for customer-support/scripts/links.sh (T20261012-373882).
# Token bridging (ENTITLEMENT_TOKEN -> SYNX_PARTNER_TOKEN) and the
# --clone-dir fixture path (no real network/git clone needed).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/customer-support/scripts/links.sh"
  cd "$BATS_TEST_TMPDIR"
}

@test "rejects any --token* flag, same rule as the scripts it wraps" {
  run cs-links-reject-token-arg sbom.json label --token-foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"never a CLI argument"* ]]
  run cs-links-reject-token-arg --tokenvalue=x
  [ "$status" -eq 1 ]
}

@test "accepts normal args with no --token flag" {
  run cs-links-reject-token-arg sbom.json label --clone-dir /tmp/x
  [ "$status" -eq 0 ]
}

@test "resolve-token reads ENTITLEMENT_TOKEN from a given .env file" {
  cat > fixture.env <<'EOF'
SOME_OTHER_KEY=abc
ENTITLEMENT_TOKEN=secret-value-123
EOF
  run cs-links-resolve-token fixture.env
  [ "$status" -eq 0 ]
  [ "$output" = "secret-value-123" ]
}

@test "resolve-token errors clearly when the .env has no ENTITLEMENT_TOKEN" {
  cat > fixture.env <<'EOF'
SOME_OTHER_KEY=abc
EOF
  run cs-links-resolve-token fixture.env
  [ "$status" -eq 1 ]
  [[ "$output" == *"ENTITLEMENT_TOKEN not found"* ]]
}

@test "resolve-token errors clearly when the .env file doesn't exist" {
  run cs-links-resolve-token /nonexistent/.env
  [ "$status" -eq 1 ]
}

@test "cs-links-render bridges .env's ENTITLEMENT_TOKEN into SYNX_PARTNER_TOKEN for the wrapped script" {
  mkdir -p fake-clone/scripts/release
  cat > fake-clone/.env <<'EOF'
ENTITLEMENT_TOKEN=bridged-token-xyz
EOF
  cat > fake-clone/scripts/release/render-partner-download-block.sh <<'EOF'
#!/usr/bin/env bash
echo "token=${SYNX_PARTNER_TOKEN:-}"
echo "args=$*"
EOF
  chmod +x fake-clone/scripts/release/render-partner-download-block.sh
  # Explicitly unset: a real ENTITLEMENT_TOKEN may be present in the
  # ambient shell (e.g. direnv-loaded .env) and must not shadow this test's
  # fixture .env — same isolation need as the "prefers already-exported"
  # case below, just the opposite direction.
  run env -u ENTITLEMENT_TOKEN bash -c "source '$REPO_ROOT/customer-support/scripts/links.sh'; cs-links-render fake-clone sbom.json 'Hashdata.ai'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token=bridged-token-xyz"* ]]
  [[ "$output" == *"args=sbom.json Hashdata.ai"* ]]
}

@test "cs-links-render prefers an already-exported ENTITLEMENT_TOKEN over the .env file" {
  mkdir -p fake-clone/scripts/release
  cat > fake-clone/.env <<'EOF'
ENTITLEMENT_TOKEN=from-env-file
EOF
  cat > fake-clone/scripts/release/render-partner-download-block.sh <<'EOF'
#!/usr/bin/env bash
echo "token=${SYNX_PARTNER_TOKEN:-}"
EOF
  chmod +x fake-clone/scripts/release/render-partner-download-block.sh
  run env ENTITLEMENT_TOKEN=from-shell bash -c "source '$REPO_ROOT/customer-support/scripts/links.sh'; cs-links-render fake-clone sbom.json label"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token=from-shell"* ]]
}

@test "cs-links-render errors clearly when the clone has no render script" {
  mkdir -p empty-clone
  run cs-links-render empty-clone sbom.json label
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "main with --clone-dir reuses the fixture clone and propagates a non-verifying failure" {
  mkdir -p fake-clone/scripts/release
  cat > fake-clone/.env <<'EOF'
ENTITLEMENT_TOKEN=xyz
EOF
  cat > fake-clone/scripts/release/render-partner-download-block.sh <<'EOF'
#!/usr/bin/env bash
echo "one artifact failed to verify (HTTP 404)" >&2
exit 1
EOF
  chmod +x fake-clone/scripts/release/render-partner-download-block.sh
  run cs-links-main sbom.json label --clone-dir fake-clone
  [ "$status" -eq 1 ]
  [ -d fake-clone ]   # --clone-dir is caller-owned; never deleted by links.sh
}

@test "main with --clone-dir rejects a bad usage (wrong positional count)" {
  run cs-links-main --clone-dir fake-clone
  [ "$status" -eq 2 ]
}

@test "main without --clone-dir fails fast (before any clone) when ENTITLEMENT_TOKEN is unset" {
  # Regression test for the gap an independent review of ccxp-skills#346
  # found: a fresh ephemeral clone can never have a populated .env, so the
  # caller must export ENTITLEMENT_TOKEN itself. This must fail BEFORE
  # attempting a network clone, with a clear, actionable message.
  run env -u ENTITLEMENT_TOKEN bash -c "source '$REPO_ROOT/customer-support/scripts/links.sh'; CS_LINKS_REPO=/nonexistent/should-never-be-cloned cs-links-main sbom.json label"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ENTITLEMENT_TOKEN is not set"* ]]
  [[ "$output" == *"--clone-dir"* ]]
}

@test "main without --clone-dir proceeds past the token check when ENTITLEMENT_TOKEN IS set (clone itself may still fail in this sandbox, but not on the token)" {
  run env ENTITLEMENT_TOKEN=already-exported CS_LINKS_REPO=/nonexistent/not-a-real-repo bash -c "source '$REPO_ROOT/customer-support/scripts/links.sh'; cs-links-main sbom.json label"
  [ "$status" -ne 0 ]
  [[ "$output" != *"ENTITLEMENT_TOKEN is not set"* ]]
}
