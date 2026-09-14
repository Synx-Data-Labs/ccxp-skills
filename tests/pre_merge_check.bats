#!/usr/bin/env bats
# Tests for address-pr/scripts/pre-merge-check.sh's GH_SH resolution — pins
# T20260914-384424's fix (resolve _gh/gh.sh via dirname "${BASH_SOURCE[0]}"),
# not a hardcoded ~/.claude/skills/_gh/gh.sh path that broke under a
# plugin-only install (confirmed failing with "could not determine repo"
# before this fix).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/address-pr/scripts/pre-merge-check.sh"

setup() {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-stub.sh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    echo "acme-org/acme-repo" ;;
  "pr checks")
    echo -e "Markdown Lint\tpass\t1s\thttp://example.com" ;;
  "api graphql")
    cat <<'JSON'
{"data":{"repository":{"pullRequest":{
  "reviews":{"nodes":[]},
  "commits":{"nodes":[{"commit":{"pushedDate":"2025-01-01T00:00:00Z"}}]},
  "reviewThreads":{"nodes":[]}
}}}}
JSON
    ;;
  "api /repos/acme-org/acme-repo/issues/42/comments")
    echo '[{"user":{"login":"Copilot"},"created_at":"2026-01-02T00:00:00Z"}]' ;;
  "pr view")
    printf '### Pre-merge\n- [x] done\n' ;;
  *)
    echo "unhandled gh-stub invocation: $*" >&2
    exit 1 ;;
esac
STUB
  chmod +x "$fakebin/gh-stub.sh"
}

@test "resolves gh.sh via GH_SH override, not a hardcoded ~/.claude/skills path" {
  run env GH_SH="$fakebin/gh-stub.sh" bash "$SCRIPT" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL CHECKS PASSED"* ]]
}

@test "default GH_SH resolves to the real sibling _gh/gh.sh next to this script" {
  ! grep -q '\~/\.claude/skills' "$SCRIPT"
  [ -x "$REPO_ROOT/_gh/gh.sh" ]
}
