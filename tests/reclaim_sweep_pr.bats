#!/usr/bin/env bats
# Tests for ccxp/scripts/reclaim-sweep-pr.sh's SKILLS_ROOT resolution — pins
# T20260914-384424's fix (resolve _session/reclaim_sweep.sh, _docs/lint-docs.sh,
# and _gh/gh.sh via dirname "${BASH_SOURCE[0]}"/SKILLS_ROOT), not a hardcoded
# ~/.claude/skills/... path that only exists under the retired symlink-install
# layout (T20260914-871616).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ccxp/scripts/reclaim-sweep-pr.sh"

setup() {
  REAL_GIT="$(command -v git)"
}

@test "CCXP_PEER_MODE=0 exits 0 without touching SKILLS_ROOT at all" {
  run env CCXP_PEER_MODE=0 SKILLS_ROOT="/nonexistent" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nothing to reclaim: resolves _session/reclaim_sweep.sh via SKILLS_ROOT, not a hardcoded path, and exits 0" {
  fake="$BATS_TEST_TMPDIR/fake-skills"
  mkdir -p "$fake/_session"
  cat > "$fake/_session/reclaim_sweep.sh" <<'STUB'
#!/usr/bin/env bash
# Deliberately empty stdout — "nothing to reclaim" path.
STUB
  chmod +x "$fake/_session/reclaim_sweep.sh"

  run env CCXP_PEER_MODE=1 SKILLS_ROOT="$fake" HOME="$BATS_TEST_TMPDIR/no-real-home" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "something to reclaim: uses SKILLS_ROOT for the apply/lint/gh-create calls, not ~/.claude/skills" {
  target="$BATS_TEST_TMPDIR/target-repo"
  mkdir -p "$target/dev/TODO"
  echo "status: Open" > "$target/dev/TODO/T1-fake.md"
  (cd "$target" && "$REAL_GIT" init -q && "$REAL_GIT" checkout -q -b main && \
    "$REAL_GIT" config user.email t@example.com && "$REAL_GIT" config user.name t && \
    "$REAL_GIT" add dev/TODO/T1-fake.md && "$REAL_GIT" commit -q -m init)
  # A real, uncommitted edit so the script's own `git commit` has something
  # to commit (a no-op commit would fail and abort the script under -e).
  echo "claimed_by:" >> "$target/dev/TODO/T1-fake.md"

  fake="$BATS_TEST_TMPDIR/fake-skills"
  mkdir -p "$fake/_session" "$fake/_docs"
  cat > "$fake/_session/reclaim_sweep.sh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--apply" ]; then
  exit 0
fi
echo "reclaimed: T1 (dead-clone)"
STUB
  chmod +x "$fake/_session/reclaim_sweep.sh"
  cat > "$fake/_docs/lint-docs.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$fake/_docs/lint-docs.sh"

  callog="$BATS_TEST_TMPDIR/gh-calls.log"
  cat > "$fake/_gh_gh.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$callog"
echo "https://github.com/acme-org/acme-repo/pull/99"
EOF
  chmod +x "$fake/_gh_gh.sh"
  mkdir -p "$fake/_gh"
  mv "$fake/_gh_gh.sh" "$fake/_gh/gh.sh"

  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  push) exit 0 ;;
  *) exec "$REAL_GIT" "\$@" ;;
esac
EOF
  chmod +x "$fakebin/git"

  run env PATH="$fakebin:/usr/bin:/bin" CCXP_PEER_MODE=1 SKILLS_ROOT="$fake" \
    HOME="$BATS_TEST_TMPDIR/no-real-home" \
    bash -c "cd '$target' && bash '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaimed: T1 (dead-clone)"* ]]
  [[ "$output" == *"https://github.com/acme-org/acme-repo/pull/99"* ]]
  grep -q -- "pr create --fill" "$callog"
  (cd "$target" && [ "$("$REAL_GIT" branch --show-current)" = "main" ])
}
