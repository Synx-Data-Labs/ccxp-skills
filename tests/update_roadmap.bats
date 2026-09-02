#!/usr/bin/env bats
# Tests for ccxp/scripts/update-roadmap.sh — the ROADMAP hub-repo target is
# config-driven via ROADMAP_TARGET_REPO (no hardcoded your-org/
# hub-repo default), per T20260827-280088's "Config-drive-and-move whole"
# checklist. Same ENV_FILE/~/.claude/.env resolution convention as
# vpn/scripts/vpn.sh's load_vpn_env and _session/_lib.sh's _session_load_env.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/ccxp/scripts/update-roadmap.sh"

setup() {
  unset ROADMAP_TARGET_REPO ENV_FILE
  REAL_GIT="$(command -v git)"
}

# ============================================================================
# env resolution
# ============================================================================

@test "_update_roadmap_load_env: no default — ROADMAP_TARGET_REPO is empty with nothing configured" {
  result=$(bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

@test "_update_roadmap_load_env: ENV_FILE override wins when set" {
  envfile="$BATS_TEST_TMPDIR/custom.env"
  cat > "$envfile" <<'EOF'
ROADMAP_TARGET_REPO=some-org/some-repo
EOF
  result=$(ENV_FILE="$envfile" bash -c "source '$SCRIPT'; echo \"\$ROADMAP_TARGET_REPO\"")
  [ "$result" = "some-org/some-repo" ]
}

@test "_update_roadmap_load_env: already-exported ROADMAP_TARGET_REPO is left alone (no file needed)" {
  result=$(ROADMAP_TARGET_REPO=preset-org/preset-repo bash -c "source '$SCRIPT'; echo \"\$ROADMAP_TARGET_REPO\"")
  [ "$result" = "preset-org/preset-repo" ]
}

@test "_update_roadmap_load_env: does not abort the shell when ~/.claude/.env is absent (real, non-BATS code path)" {
  # Every other test in this file inherits BATS_TEST_TMPDIR, which makes
  # _update_roadmap_load_env return before ever reaching the
  # $HOME/.claude/.env check — so it can't catch a set -e bug in that branch
  # (a bare `[ -f ... ] && { source ...; }` as the function's last statement
  # makes the *function itself* return non-zero when the file is missing,
  # which set -e treats as an unshielded failure at the call site and aborts
  # the whole script with zero output — caught in PR #238 review). Force the
  # real path with `env -u BATS_TEST_TMPDIR` and a HOME with no .claude/.env.
  fakehome="$BATS_TEST_TMPDIR/no-env-here"
  mkdir -p "$fakehome"
  result=$(env -u ROADMAP_TARGET_REPO -u ENV_FILE -u BATS_TEST_TMPDIR HOME="$fakehome" \
    bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

@test "clone: real (non-BATS) code path prints the clear error and exits 1 when nothing is configured" {
  fakehome="$BATS_TEST_TMPDIR/no-env-here-clone"
  mkdir -p "$fakehome"
  fakebin="$BATS_TEST_TMPDIR/fakebin-realpath"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
echo "git should not have been called: $*" >&2
exit 99
EOF
  chmod +x "$fakebin/git"

  run env -u ROADMAP_TARGET_REPO -u ENV_FILE -u BATS_TEST_TMPDIR \
    PATH="$fakebin:/usr/bin:/bin" HOME="$fakehome" \
    bash "$SCRIPT" clone
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROADMAP_TARGET_REPO"* ]]
}

@test "_update_roadmap_load_env: ENV_FILE existing but its last statement fails does not abort the shell" {
  # ~/.claude/.env-style files are shared and hand-edited (VPN_*,
  # RETRO_SLACK_CHANNEL, METRICS_OWNER/REPOS, ...) — a stray failing command
  # on the last line must degrade to "still unset", not crash the whole
  # script under set -e (source's own exit status is the final command of
  # its if-body, so unlike the file-ABSENT case, this failure is NOT exempt
  # from set -e without an explicit `|| true` — caught in PR #238 review).
  envfile="$BATS_TEST_TMPDIR/bad.env"
  echo 'false' > "$envfile"
  result=$(env -u ROADMAP_TARGET_REPO -u BATS_TEST_TMPDIR ENV_FILE="$envfile" \
    bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

@test "_update_roadmap_load_env: ~/.claude/.env existing but its last statement fails does not abort the shell" {
  fakehome="$BATS_TEST_TMPDIR/bad-home-env"
  mkdir -p "$fakehome/.claude"
  echo 'false' > "$fakehome/.claude/.env"
  result=$(env -u ROADMAP_TARGET_REPO -u ENV_FILE -u BATS_TEST_TMPDIR HOME="$fakehome" \
    bash -c "source '$SCRIPT'; echo \"[\$ROADMAP_TARGET_REPO]\"")
  [ "$result" = "[]" ]
}

# ============================================================================
# clone
# ============================================================================

@test "clone: fails with a clear error and does not invoke git when ROADMAP_TARGET_REPO is unset" {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
echo "git should not have been called: $*" >&2
exit 99
EOF
  chmod +x "$fakebin/git"

  run env PATH="$fakebin:/usr/bin:/bin" bash "$SCRIPT" clone
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROADMAP_TARGET_REPO"* ]]
}

@test "clone: clones the configured ROADMAP_TARGET_REPO, not a hardcoded org/repo" {
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  callog="$BATS_TEST_TMPDIR/git-calls.log"
  cat > "$fakebin/git" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$callog"
case "\$1" in
  clone)
    dest="\${@: -1}"
    mkdir -p "\$dest/.git"
    ;;
esac
EOF
  chmod +x "$fakebin/git"

  run env PATH="$fakebin:/usr/bin:/bin" ROADMAP_TARGET_REPO="acme-org/acme-team" \
    bash "$SCRIPT" clone
  [ "$status" -eq 0 ]
  grep -q "clone --depth=20 git@github.com:acme-org/acme-team.git" "$callog"
  ! grep -qi "hub-repo\|your-org" "$callog"
}

# ============================================================================
# commit-pr
# ============================================================================

@test "commit-pr: fails with a clear error and does not invoke git/gh when ROADMAP_TARGET_REPO is unset" {
  target="$BATS_TEST_TMPDIR/target-repo"
  mkdir -p "$target"
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  for bin in git gh; do
    cat > "$fakebin/$bin" <<EOF
#!/usr/bin/env bash
echo "$bin should not have been called: \$*" >&2
exit 99
EOF
    chmod +x "$fakebin/$bin"
  done

  run env PATH="$fakebin:/usr/bin:/bin" bash "$SCRIPT" commit-pr --target "$target"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ROADMAP_TARGET_REPO"* ]]
}

@test "commit-pr: opens the PR against the configured ROADMAP_TARGET_REPO, not a hardcoded org/repo" {
  target="$BATS_TEST_TMPDIR/target-repo"
  mkdir -p "$target/dev"
  echo "# ROADMAP" > "$target/dev/ROADMAP.md"
  (cd "$target" && "$REAL_GIT" init -q && "$REAL_GIT" checkout -q -b roadmap/ipm-test && \
    "$REAL_GIT" config user.email t@example.com && "$REAL_GIT" config user.name t && \
    "$REAL_GIT" add dev/ROADMAP.md && "$REAL_GIT" commit -q -m init)
  # A real, uncommitted edit so the script's own `git commit` has something
  # to commit (a no-op commit would fail and abort the script under -e).
  echo "- this week's IPM update" >> "$target/dev/ROADMAP.md"

  fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  callog="$BATS_TEST_TMPDIR/gh-calls.log"
  cat > "$fakebin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
  push) exit 0 ;;
  branch) echo "roadmap/ipm-test" ;;
  *) exec "$REAL_GIT" "\$@" ;;
esac
EOF
  chmod +x "$fakebin/git"

  fakehome="$BATS_TEST_TMPDIR/fakehome"
  mkdir -p "$fakehome/.claude/skills/_gh" "$fakehome/.claude/skills/_docs"
  cat > "$fakehome/.claude/skills/_gh/gh.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$callog"
EOF
  chmod +x "$fakehome/.claude/skills/_gh/gh.sh"
  cat > "$fakehome/.claude/skills/_docs/lint-docs.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fakehome/.claude/skills/_docs/lint-docs.sh"

  run env PATH="$fakebin:/usr/bin:/bin" HOME="$fakehome" \
    ROADMAP_TARGET_REPO="acme-org/acme-team" \
    bash "$SCRIPT" commit-pr --target "$target" --bp-pr-url "https://example.com/pr/1"
  [ "$status" -eq 0 ]
  grep -q -- "--repo acme-org/acme-team" "$callog"
  ! grep -qi "hub-repo\|your-org" "$callog"
}
