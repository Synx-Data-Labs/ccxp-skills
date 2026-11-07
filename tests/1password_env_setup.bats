#!/usr/bin/env bats
# Tests for 1password-env-setup/scripts/1password-env-setup.sh — bootstraps a
# repo's .env (materialized from .env.tpl via `op inject`) plus a
# skip-if-populated .envrc (direnv), per hub-repo T20260722-399461.
#
# Helper functions (pes-*) are sourced and tested directly (function-wrapped,
# BASH_SOURCE-guarded — same pattern as quality-probe/scripts/probe.sh).
# `op`/`direnv` presence is controlled via a PATH-stub dir so
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
  for tool in bash sh cat printf env rm mkdir dirname basename head wc cut mktemp mv chmod cp cmp grep sleep kill shasum sha256sum perl tr sed; do
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
  [[ "$output" == *'./refresh-env .'* ]]
  [[ "$output" == *'dotenv .env'* ]]
  [[ "$output" == *'log_error'* ]]
  [[ "$output" != *'-nt'* ]]
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
  grep -q "./refresh-env ." "$REPO/.envrc"
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
  grep -q "inject -i $REPO/.env.tpl -o $REPO/.env.tmp." "$OP_CALLS"
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
  [ "\$2" = "-i" ] && echo "materialized" >"\$5"
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

# ---------------------------------------------------------------------------
# refresh-env (T20261107-939110): content-hash freshness, drift, unlock message
# ---------------------------------------------------------------------------

REFRESH="$REPO_ROOT/1password-env-setup/scripts/refresh-env.sh"

# Run refresh-env (sourced) with the stubbed PATH; extra env as leading args.
_re() { env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" "$@" ; }
_run_re() {
  local args="$*"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" bash -c "source '$REFRESH'; refresh-env $args 2>&1"
}

_re_setup() {
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  : >"$OP_CALLS"
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
}

@test "refresh-env first run (no state) refreshes, records both hashes, mode 0600" {
  _re_setup
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason: missing"* ]]
  [[ "$output" == *"materialized: $REPO/.env"* ]]
  [ -s "$REPO/.env.tpl.sha256" ]
  [ -s "$REPO/.env.sha256" ]
  [ "$(stat -c %a "$REPO/.env" 2>/dev/null || stat -f %Lp "$REPO/.env")" = "600" ]
}

@test "refresh-env skips op when template and cache hashes match" {
  _re_setup
  _run_re "'$REPO'"
  : >"$OP_CALLS"
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged: $REPO/.env fresh"* ]]
  [ ! -s "$OP_CALLS" ]
}

@test "refresh-env refreshes when .env.tpl content changes even if .env is newer" {
  _re_setup
  _run_re "'$REPO'"
  echo "BAR=op://vault/item/other" >>"$REPO/.env.tpl"
  touch -t 203001010000 "$REPO/.env"   # .env looks newer than the template
  : >"$OP_CALLS"
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason: tpl-changed"* ]]
  grep -q "inject" "$OP_CALLS"
}

@test "refresh-env refreshes when .env was edited outside the generator (the incident)" {
  _re_setup
  _run_re "'$REPO'"
  echo "FOO=fake-literal-value" >"$REPO/.env"   # hand edit, newer than the template
  : >"$OP_CALLS"
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason: env-edited-outside-generator"* ]]
  grep -q "inject" "$OP_CALLS"
  [ "$(cat "$REPO/.env")" = "materialized" ]
}

@test "refresh-env treats a populated .env with no hash files as stale (no-state)" {
  _re_setup
  echo "FOO=fake" >"$REPO/.env"
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason: no-state"* ]]
  grep -q "inject" "$OP_CALLS"
}

@test "refresh-env --force refreshes even when hashes match" {
  _re_setup
  _run_re "'$REPO'"
  : >"$OP_CALLS"
  _run_re "--force '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason: forced"* ]]
  grep -q "inject" "$OP_CALLS"
}

@test "refresh-env --check reports fresh with exit 0 and never calls op" {
  _re_setup
  _run_re "'$REPO'"
  : >"$OP_CALLS"
  _run_re "--check '$REPO'"
  [ "$status" -eq 0 ]
  [ "$output" = "fresh" ]
  [ ! -s "$OP_CALLS" ]
}

@test "refresh-env --check reports stale (exit 3) with drift key NAMES only, no values" {
  _re_setup
  printf 'FOO=op://vault/item/field\nBAR=op://vault/item/b\nBAZ=plain\n' >"$REPO/.env.tpl"
  printf 'FOO=fake-secret-literal\nBAZ=plain\n' >"$REPO/.env"
  _run_re "--check '$REPO'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"stale: no-state"* ]]
  [[ "$output" == *"drift: BAR"* ]]            # missing from .env
  [[ "$output" != *"drift: FOO"* ]]            # resolved literal is normal
  [[ "$output" != *"fake-secret-literal"* ]]   # values never printed
  [ ! -s "$OP_CALLS" ]
}

@test "refresh-env --check flags a key left as an unresolved op:// string" {
  _re_setup
  echo "FOO=op://vault/item/field" >"$REPO/.env"
  _run_re "--check '$REPO'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"drift: FOO"* ]]
}

@test "refresh-env errors (exit 2) when .env.tpl is missing" {
  _re_setup
  rm "$REPO/.env.tpl"
  _run_re "'$REPO'"
  [ "$status" -eq 2 ]
  [[ "$output" == *".env.tpl not found"* ]]
}

@test "refresh-env exits 10 with install guidance when op is missing and a refresh is needed" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  _run_re "'$REPO'"
  [ "$status" -eq 10 ]
  [[ "$output" == *"op (1Password CLI) not installed"* ]]
  [ ! -f "$REPO/.env" ]
}

@test "refresh-env op needing unlock: clear message, exit 75, old cache and hashes untouched" {
  _re_setup
  _run_re "'$REPO'"
  cp "$REPO/.env.sha256" "$BATS_TEST_TMPDIR/env.sha.before"
  echo "FOO=fake-edited" >"$REPO/.env"
  cat >"$STUB_BIN/op" <<'EOF'
#!/usr/bin/env bash
echo "[ERROR] you are not signed in; unlock 1Password to authorize" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/op"
  _run_re "'$REPO'"
  [ "$status" -eq 75 ]
  [[ "$output" == *"needs your unlock"* ]]
  [[ "$output" == *"NOT changed"* ]]
  [ "$(cat "$REPO/.env")" = "FOO=fake-edited" ]
  cmp -s "$REPO/.env.sha256" "$BATS_TEST_TMPDIR/env.sha.before"
  # next call still sees it as stale (hash not recorded), so it retries
  _run_re "--check '$REPO'"
  [ "$status" -eq 3 ]
}

@test "refresh-env op hanging past REFRESH_ENV_OP_TIMEOUT exits 75 with the unlock message" {
  _re_setup
  cat >"$STUB_BIN/op" <<'EOF'
#!/usr/bin/env bash
exec sleep 30
EOF
  chmod +x "$STUB_BIN/op"
  run env PATH="$STUB_BIN" REFRESH_ENV_OP_TIMEOUT=1 bash -c "source '$REFRESH'; refresh-env '$REPO' 2>&1"
  [ "$status" -eq 75 ]
  [[ "$output" == *"needs your unlock"* ]]
  [ ! -f "$REPO/.env" ]
  [ ! -f "$REPO/.env.tpl.sha256" ]
}

@test "refresh-env generic op failure exits 1, keeps old cache, leaves no temp files" {
  _re_setup
  _stub_op_failing generic
  echo "FOO=fake-old" >"$REPO/.env"
  _run_re "'$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed: op inject"* ]]
  [ "$(cat "$REPO/.env")" = "FOO=fake-old" ]
  ! ls "$REPO"/.env.tmp.* "$REPO"/.env.err.* 2>/dev/null
  [ ! -d "$REPO/.env.refresh.lock" ]
}

@test "refresh-env does not echo template-quoting op stderr lines" {
  _re_setup
  cat >"$STUB_BIN/op" <<'EOF'
#!/usr/bin/env bash
echo "could not resolve FOO=op://vault/item/field" >&2
echo "[ERROR] plain failure line" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/op"
  _run_re "'$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plain failure line"* ]]
  [[ "$output" != *"op://vault/item/field"* ]]
}

@test "refresh-env exits 75 when another live refresh holds the lock, cache untouched" {
  _re_setup
  mkdir "$REPO/.env.refresh.lock"
  echo "$$" >"$REPO/.env.refresh.lock/pid"   # this bats process is alive
  run env PATH="$STUB_BIN" REFRESH_ENV_LOCK_WAIT=1 bash -c "source '$REFRESH'; refresh-env '$REPO' 2>&1"
  [ "$status" -eq 75 ]
  [[ "$output" == *"holds"* ]]
  [ ! -f "$REPO/.env" ]
}

@test "refresh-env breaks a stale lock left by a dead process" {
  _re_setup
  mkdir "$REPO/.env.refresh.lock"
  echo "999999" >"$REPO/.env.refresh.lock/pid"
  _run_re "'$REPO'"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.env" ]
  [ ! -d "$REPO/.env.refresh.lock" ]
}

@test "refresh-env fails cleanly (exit 1) when op produces an empty file" {
  _re_setup
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_BIN/op"
  chmod +x "$STUB_BIN/op"
  _run_re "'$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty file"* ]]
  [ ! -f "$REPO/.env.tpl.sha256" ]
}

@test "refresh-env rejects an unknown flag with usage (exit 2)" {
  _re_setup
  _run_re "--bogus '$REPO'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "refresh-env executed directly works (standalone, no argument defaults to its own dir when named refresh-env)" {
  _re_setup
  cp "$REFRESH" "$REPO/refresh-env"
  chmod +x "$REPO/refresh-env"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" "$REPO/refresh-env"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.env" ]
}

@test "pes-install-helper copies an executable refresh-env and is idempotent" {
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-install-helper '$REPO'"
  [ "$status" -eq 0 ]
  [[ "$output" == "wrote: $REPO/refresh-env" ]]
  [ -x "$REPO/refresh-env" ]
  run env PATH="$STUB_BIN" bash -c "source '$SCRIPT'; pes-install-helper '$REPO'"
  [[ "$output" == "unchanged: $REPO/refresh-env" ]]
}

@test "1password-env-setup end to end installs refresh-env and a hash-based .envrc" {
  echo "FOO=op://vault/item/field" >"$REPO/.env.tpl"
  _stub_op
  _stub_direnv
  OP_CALLS="$BATS_TEST_TMPDIR/op_calls"
  DIRENV_CALLS="$BATS_TEST_TMPDIR/direnv_calls"
  run env PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" DIRENV_CALLS="$DIRENV_CALLS" \
    bash -c "source '$SCRIPT'; 1password-env-setup '$REPO'"
  [ "$status" -eq 0 ]
  [ -x "$REPO/refresh-env" ]
  [ -s "$REPO/.env.tpl.sha256" ]
  grep -q "./refresh-env ." "$REPO/.envrc"
}

@test "refresh-env works under macOS /bin/bash 3.2 semantics with OP_ACCOUNT unset (no empty-array expansion)" {
  _re_setup
  [ -x /bin/bash ] || skip "no /bin/bash"
  cp "$REFRESH" "$REPO/refresh-env"
  run env -u OP_ACCOUNT PATH="$STUB_BIN" OP_CALLS="$OP_CALLS" /bin/bash "$REPO/refresh-env" 2>&1
  [ "$status" -eq 0 ]
  [ -f "$REPO/.env" ]
}

@test "refresh-env wrong-account vault error is a plain failure (exit 1), not an unlock request" {
  _re_setup
  _stub_op_failing vault
  _run_re "'$REPO'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OP_ACCOUNT"* ]]
}

@test "refresh-env killed mid-refresh removes temp files and the lock" {
  _re_setup
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$STUB_BIN/op"; chmod +x "$STUB_BIN/op"
  env PATH="$STUB_BIN" REFRESH_ENV_OP_TIMEOUT=30 bash -c "source '$REFRESH'; refresh-env '$REPO'" >/dev/null 2>&1 &
  local pid=$! i
  for i in $(seq 1 50); do [ -d "$REPO/.env.refresh.lock" ] && break; sleep 0.1; done
  sleep 0.3
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  sleep 0.3
  [ ! -d "$REPO/.env.refresh.lock" ]
  ! ls "$REPO"/.env.tmp.* "$REPO"/.env.err.* 2>/dev/null
}
