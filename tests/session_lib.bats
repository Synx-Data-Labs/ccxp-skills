#!/usr/bin/env bats
# Tests for _session/_lib.sh's _session_gh() — resolves the _gh/gh.sh wrapper
# relative to _lib.sh's own directory instead of a hardcoded
# ~/.claude/skills/_gh/gh.sh path, which does not exist on a bare GHA runner
# (T20260810-922807). Falls back to plain `gh` when no sibling is present
# (e.g. a caller that sparse-clones just _session/).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_session/_lib.sh"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH/_session"
  # Tests control token resolution explicitly — don't let ambient CI env
  # tokens (GH_TOKEN is commonly pre-set by Actions for gh-CLI auth) leak in.
  unset SESSION_TOKEN PROJECT_PAT GH_TOKEN
}

@test "_session_gh invokes _gh/gh.sh resolved relative to _lib.sh's directory, not the hardcoded ~ path" {
  mkdir -p "$SCRATCH/_gh"
  cat > "$SCRATCH/_gh/gh.sh" <<'STUB'
#!/usr/bin/env bash
printf 'stub-invoked: %s\n' "$*"
STUB
  chmod +x "$SCRATCH/_gh/gh.sh"
  _SESSION_LIB_DIR="$SCRATCH/_session"
  [ "$(_session_gh pr view 1)" = "stub-invoked: pr view 1" ]
}

@test "_session_gh passes a resolved token through to the wrapper as GH_TOKEN" {
  mkdir -p "$SCRATCH/_gh"
  cat > "$SCRATCH/_gh/gh.sh" <<'STUB'
#!/usr/bin/env bash
printf 'token=%s\n' "${GH_TOKEN:-}"
STUB
  chmod +x "$SCRATCH/_gh/gh.sh"
  _SESSION_LIB_DIR="$SCRATCH/_session"
  SESSION_TOKEN="secret-tok"
  [ "$(_session_gh pr view 1)" = "token=secret-tok" ]
}

@test "_session_gh falls back to plain gh when no _gh/gh.sh sibling exists (GHA runner shape)" {
  # No _gh/ directory created next to $SCRATCH/_session at all.
  _SESSION_LIB_DIR="$SCRATCH/_session"
  local stub_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'plain-gh-invoked: %s\n' "$*"
STUB
  chmod +x "$stub_bin/gh"
  PATH="$stub_bin:$PATH"
  [ "$(_session_gh pr view 1)" = "plain-gh-invoked: pr view 1" ]
}

@test "_session_gh plain-gh fallback also passes a resolved token through as GH_TOKEN" {
  _SESSION_LIB_DIR="$SCRATCH/_session"
  local stub_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'token=%s\n' "${GH_TOKEN:-}"
STUB
  chmod +x "$stub_bin/gh"
  PATH="$stub_bin:$PATH"
  SESSION_TOKEN="secret-tok"
  [ "$(_session_gh pr view 1)" = "token=secret-tok" ]
}

# ============================================================================
# PROJECT_OWNER/PROJECT_NUMBER — no baked-in default; ~/.claude/.env resolution
# (T20260827-280088: removed the hardcoded your-org/1 default so the
# public ccxp-skills copy of this file ships with no company name baked in)
# ============================================================================

@test "_session_load_env: no default — PROJECT_OWNER is empty with nothing configured" {
  result=$(bash -c "source '$REPO_ROOT/_session/_lib.sh'; echo \"[\$PROJECT_OWNER]\"")
  [ "$result" = "[]" ]
}

@test "_session_load_env: ENV_FILE override wins when set" {
  envfile="$BATS_TEST_TMPDIR/custom.env"
  cat > "$envfile" <<'EOF'
PROJECT_OWNER=custom-org
PROJECT_NUMBER=42
EOF
  result=$(ENV_FILE="$envfile" bash -c "source '$REPO_ROOT/_session/_lib.sh'; echo \"\$PROJECT_OWNER \$PROJECT_NUMBER\"")
  [ "$result" = "custom-org 42" ]
}

@test "_session_load_env: already-exported PROJECT_OWNER is left alone (no file needed)" {
  result=$(PROJECT_OWNER=preset-org bash -c "source '$REPO_ROOT/_session/_lib.sh'; echo \"\$PROJECT_OWNER\"")
  [ "$result" = "preset-org" ]
}

@test "_session_resolve_project: logs a clear message and fails when unconfigured" {
  run bash -c "source '$REPO_ROOT/_session/_lib.sh'; _session_resolve_project"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROJECT_OWNER/PROJECT_NUMBER not configured"* ]]
}
