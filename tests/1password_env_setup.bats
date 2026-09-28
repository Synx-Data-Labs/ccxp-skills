#!/usr/bin/env bats
# Tests for 1password-env-setup/scripts/1password-env-setup.sh — bootstraps a
# repo's .env (materialized from .env.tpl via `op inject`) plus a
# skip-if-populated .envrc (direnv), per hub-repo T20260722-399461.
#
# Helper functions (pes-*) are sourced and tested directly (function-wrapped,
# BASH_SOURCE-guarded — same pattern as statusline-setup/scripts/statusline-
# command.sh). `op`/`direnv` presence is controlled via a PATH-stub dir so
# tests never touch a real 1Password session or shell hook.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/1password-env-setup/scripts/1password-env-setup.sh"

setup() {
  # A PATH-stub dir that symlinks ONLY the core utilities the script needs
  # (bash, cat, printf, …) but NOT op/direnv — so both appear "missing" by
  # default. Individual tests add fake op/direnv executables on top when they
  # need to exercise the "installed" path.
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  local tool src
  for tool in bash sh cat printf env rm mkdir dirname head wc; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$STUB_BIN/$tool"
  done

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
}

_load() { source "$SCRIPT"; }

# A fake `op` that records its args to a file instead of touching 1Password.
_stub_op() {
  cat >"$STUB_BIN/op" <<'EOF'
#!/usr/bin/env bash
echo "op $*" >>"$OP_CALLS"
# `op inject -i <tpl> -o <out>` -- write a marker file so callers can assert materialization happened.
if [ "$1" = "inject" ]; then
  shift
  out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$out" ] && echo "materialized" >"$out"
fi
EOF
  chmod +x "$STUB_BIN/op"
}

# A fake `direnv` that records its args to a file instead of hooking a shell.
_stub_direnv() {
  cat >"$STUB_BIN/direnv" <<'EOF'
#!/usr/bin/env bash
echo "direnv $*" >>"$DIRENV_CALLS"
EOF
  chmod +x "$STUB_BIN/direnv"
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "1password-env-setup.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "1password-env-setup.sh is sourceable without executing its main (function-wrapped)" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; type 1password-env-setup >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# pes-envrc-content
# ---------------------------------------------------------------------------

@test "pes-envrc-content emits the skip-if-populated template" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-envrc-content"
  [ "$status" -eq 0 ]
  [[ "$output" == *'if [ -f .env ] && [ .env -nt .env.tpl ]; then'* ]]
  [[ "$output" == *'op inject -i .env.tpl -o .env'* ]]
  [[ "$output" == *'dotenv .env'* ]]
}

# ---------------------------------------------------------------------------
# pes-check-env-tpl
# ---------------------------------------------------------------------------

@test "pes-check-env-tpl fails with guidance when .env.tpl is missing" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-check-env-tpl '$REPO' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *".env.tpl not found"* ]]
}

@test "pes-check-env-tpl succeeds when .env.tpl exists" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-check-env-tpl '$REPO'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# pes-write-envrc
# ---------------------------------------------------------------------------

@test "pes-write-envrc writes .envrc when missing" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-write-envrc '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == "wrote: $REPO/.envrc" ]]
  [ -f "$REPO/.envrc" ]
  grep -q "op inject -i .env.tpl -o .env" "$REPO/.envrc"
}

@test "pes-write-envrc is idempotent when content already matches" {
  env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-write-envrc '$REPO'" >/dev/null
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-write-envrc '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == "unchanged: $REPO/.envrc" ]]
}

@test "pes-write-envrc overwrites a differing .envrc" {
  echo "some other content" >"$REPO/.envrc"
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-write-envrc '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == "wrote: $REPO/.envrc" ]]
  ! grep -q "some other content" "$REPO/.envrc"
}

# ---------------------------------------------------------------------------
# pes-materialize-env
# ---------------------------------------------------------------------------

@test "pes-materialize-env skips when .env is already newer than .env.tpl" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  sleep 1.1
  echo "FOO=bar" >"$REPO/.env"
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already newer than .env.tpl"* ]]
  [ "$(cat "$REPO/.env")" = "FOO=bar" ]
}

@test "pes-materialize-env prints install guidance and skips when op is not installed" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"op (1Password CLI) not installed"* ]]
  [ ! -f "$REPO/.env" ]
}

@test "pes-materialize-env invokes op inject when op is installed" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"materialized: $REPO/.env"* ]]
  [ -f "$REPO/.env" ]
  grep -q "inject -i $REPO/.env.tpl -o $REPO/.env" "$OP_CALLS"
}

# A fake `op` whose `inject` always fails (T20260918-214522). $1, when set to
# "vault", emits the exact "isn't a vault in this account" message the real
# incident produced; otherwise a generic failure.
_stub_op_failing() {
  local kind="${1:-generic}"
  cat >"$STUB_BIN/op" <<EOF
#!/usr/bin/env bash
echo "op \$*" >>"$OP_CALLS"
if [ "\$1" = "inject" ]; then
  if [ "$kind" = "vault" ]; then
    echo '[ERROR] 2026/09/18 10:00:00 "Personal" isn'"'"'t a vault in this account' >&2
  else
    echo "[ERROR] some other op inject failure" >&2
  fi
  exit 1
fi
EOF
  chmod +x "$STUB_BIN/op"
}

@test "pes-materialize-env reports failure (not materialized) and returns non-zero when op inject fails" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  _stub_op_failing generic
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" != *"materialized: $REPO/.env"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "pes-materialize-env gives an actionable hint for an account-mismatch failure" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  _stub_op_failing vault
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OP_ACCOUNT"* ]]
}

@test "pes-materialize-env passes --account to op inject when OP_ACCOUNT is set" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" OP_ACCOUNT="my.1password.com" \
    bash -c "source '$SCRIPT'; pes-materialize-env '$REPO'"
  [ "$status" -eq 0 ]
  grep -q -- "--account my.1password.com" "$OP_CALLS"
}

@test "pes-materialize-env surfaces op's own stderr warning on an otherwise-successful run" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  cat >"$STUB_BIN/op" <<EOF
#!/usr/bin/env bash
echo "op \$*" >>"$OP_CALLS"
if [ "\$1" = "inject" ]; then
  echo "[WARNING] some benign op warning" >&2
  echo "materialized" >"$REPO/.env"
fi
EOF
  chmod +x "$STUB_BIN/op"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"some benign op warning"* ]]
  [[ "$output" == *"materialized: $REPO/.env"* ]]
}

@test "pes-materialize-env omits --account when OP_ACCOUNT is unset" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$SCRIPT'; pes-materialize-env '$REPO'"
  [ "$status" -eq 0 ]
  ! grep -q -- "--account" "$OP_CALLS"
}

# ---------------------------------------------------------------------------
# pes-direnv-allow
# ---------------------------------------------------------------------------

@test "pes-direnv-allow prints install guidance and skips when direnv is not installed" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-direnv-allow '$REPO' 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"direnv not installed"* ]]
}

@test "pes-direnv-allow invokes direnv allow when direnv is installed" {
  _stub_direnv
  DIRENV_CALLS="$BATS_TEST_TMPDIR/direnv_calls"
  run env PATH="$STUB_BIN" DIRENV_CALLS="$DIRENV_CALLS" bash -c "source '$SCRIPT'; pes-direnv-allow '$REPO'"
  [ "$status" -eq 0 ]
  grep -q "^direnv allow$" "$DIRENV_CALLS"
}

# ---------------------------------------------------------------------------
# 1password-env-setup (full entry point)
# ---------------------------------------------------------------------------

@test "1password-env-setup fails and writes nothing when .env.tpl is missing" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; 1password-env-setup '$REPO' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *".env.tpl not found"* ]]
  [ ! -f "$REPO/.envrc" ]
}

@test "1password-env-setup fails with a clear error for a nonexistent directory" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; 1password-env-setup '$REPO/does-not-exist' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such directory"* ]]
}

@test "1password-env-setup writes .envrc and materializes .env end to end (op+direnv stubbed)" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
  _stub_direnv
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  DIRENV_CALLS="$BATS_TEST_TMPDIR/direnv_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" DIRENV_CALLS="$DIRENV_CALLS" \
    bash -c "source '$SCRIPT'; 1password-env-setup '$REPO'"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.envrc" ]
  [ -f "$REPO/.env" ]
  grep -q "inject" "$OP_CALLS"
  grep -q "^direnv allow$" "$DIRENV_CALLS"
}

@test "1password-env-setup propagates a pes-materialize-env failure instead of silently succeeding" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op_failing generic
  _stub_direnv
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  DIRENV_CALLS="$BATS_TEST_TMPDIR/direnv_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" DIRENV_CALLS="$DIRENV_CALLS" \
    bash -c "source '$SCRIPT'; 1password-env-setup '$REPO'"
  [ "$status" -ne 0 ]
  # the failure short-circuits before pes-direnv-allow -- direnv never runs
  [ ! -f "$DIRENV_CALLS" ]
}

@test "1password-env-setup defaults to the current directory when no path is given" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  run env PATH="$STUB_BIN" bash -c "cd '$REPO' && source '$SCRIPT' && 1password-env-setup 2>&1"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.envrc" ]
}
