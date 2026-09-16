#!/usr/bin/env bats
# Tests for _gh/auto-switch.sh — the SessionStart hook that switches the
# active `gh auth` account to whichever one can see the current repo's
# `origin`, so a bare (unwrapped) `gh` call also lands on the right account.
# It also wires the repo's LOCAL git config so bare `git push`/`pull`/`fetch`
# stop depending on the SSH agent's loaded key.
#
# Scope: _auto_switch_org_repo() (URL -> owner/repo parsing), _auto_switch_run()'s
# no-op paths, its account-probing/switching logic, and _auto_switch_wire_git_credentials()
# — all against a stubbed `gh` on PATH — no real `gh auth` calls. I/O is
# hermetic via a throwaway repo tree under $BATS_TEST_TMPDIR (so the local
# `git config` writes land in that repo's own `.git/config`, never a real
# one). The production function is exercised by sourcing the script (its CLI
# dispatch is BASH_SOURCE-guarded, so sourcing is side-effect-free).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CWD_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$CWD_REPO"
  cd "$CWD_REPO"
  git init -q .

  source "$REPO_ROOT/_gh/auto-switch.sh"
}

# --- URL parsing -------------------------------------------------------------

@test "ssh origin resolves to owner/repo" {
  run _auto_switch_org_repo 'git@github.com:acme/widgets.git'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "https + .git origin resolves to owner/repo" {
  run _auto_switch_org_repo 'https://github.com/acme/widgets.git'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "https origin without .git suffix resolves" {
  run _auto_switch_org_repo 'https://github.com/acme/widgets'
  [ "$status" -eq 0 ]
  [ "$output" = "acme/widgets" ]
}

@test "dotted repo name resolves" {
  run _auto_switch_org_repo 'git@github.com:me/a.b.c.git'
  [ "$status" -eq 0 ]
  [ "$output" = "me/a.b.c" ]
}

# --- no-op paths (never reach a real `gh` call) ------------------------------

@test "non-git directory is a no-op that exits 0" {
  cd "$BATS_TEST_TMPDIR"
  run _auto_switch_run
  [ "$status" -eq 0 ]
}

@test "git repo with no origin remote is a no-op that exits 0" {
  run _auto_switch_run
  [ "$status" -eq 0 ]
}

# --- account probing/switching (stubbed `gh`) --------------------------------

@test "already-correct account: no switch attempted" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  MARKER="$BATS_TEST_TMPDIR/switch-calls"
  : > "$MARKER"
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then exit 0; fi
if [ "\$1" = "auth" ] && [ "\$2" = "switch" ]; then echo "\$4" >> "$MARKER"; exit 0; fi
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then echo "Logged in to github.com account someuser (keyring)"; exit 0; fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  [ ! -s "$MARKER" ]
}

# --- git credential wiring ----------------------------------------------------

@test "already-correct account: still wires local git credentials" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then exit 0; fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then echo "Logged in to github.com account someuser (keyring)"; exit 0; fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  # NOTE: intentionally not using bats' `run`/`$lines` here — bash's
  # IFS-whitespace word splitting silently drops the leading EMPTY line
  # (the credential.helper reset value) when building that array, so
  # index-based assertions against it would pass for the wrong reason.
  # Direct command substitution + sed preserves it.
  helper="$(git config --local --get-all credential.helper)"
  [ "$(printf '%s\n' "$helper" | sed -n '1p')" = "" ]
  [ "$(printf '%s\n' "$helper" | sed -n '2p')" = "!gh auth git-credential" ]
  [ "$(printf '%s\n' "$helper" | wc -l | tr -d ' ')" = "2" ]
  urls="$(git config --local --get-all 'url.https://github.com/.insteadOf')"
  [ "$(printf '%s\n' "$urls" | sed -n '1p')" = "git@github.com:" ]
  [ "$(printf '%s\n' "$urls" | sed -n '2p')" = "ssh://git@github.com/" ]
}

@test "switched account: wires local git credentials too" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  MARKER="$BATS_TEST_TMPDIR/switch-calls"
  : > "$MARKER"
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
  echo "Logged in to github.com account user1 (keyring)"
  echo "Logged in to github.com account user2 (keyring)"
  exit 0
fi
if [ "\$1" = "auth" ] && [ "\$2" = "switch" ]; then
  echo "\$4" >> "$MARKER"
  exit 0
fi
if [ "\$1" = "api" ]; then
  last="\$(tail -n1 "$MARKER" 2>/dev/null)"
  [ "\$last" = "user2" ] && exit 0
  exit 1
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  helper="$(git config --local --get-all credential.helper)"
  [ "$(printf '%s\n' "$helper" | sed -n '2p')" = "!gh auth git-credential" ]
}

@test "no account can see the repo: git config left untouched" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "Logged in to github.com account user1 (keyring)"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "switch" ]; then exit 0; fi
if [ "$1" = "api" ]; then exit 1; fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  run git config --local --get-all credential.helper
  [ "$status" -ne 0 ]
  run git config --local --get-all 'url.https://github.com/.insteadOf'
  [ "$status" -ne 0 ]
}

@test "wiring is idempotent across repeated runs (no duplicate entries)" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ]; then exit 0; fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then echo "Logged in to github.com account someuser (keyring)"; exit 0; fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  helper="$(git config --local --get-all credential.helper)"
  [ "$(printf '%s\n' "$helper" | wc -l | tr -d ' ')" = "2" ]
  urls="$(git config --local --get-all 'url.https://github.com/.insteadOf')"
  [ "$(printf '%s\n' "$urls" | wc -l | tr -d ' ')" = "2" ]
}

@test "switches to the account that can see the repo" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  MARKER="$BATS_TEST_TMPDIR/switch-calls"
  : > "$MARKER"
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
  echo "Logged in to github.com account user1 (keyring)"
  echo "Logged in to github.com account user2 (keyring)"
  exit 0
fi
if [ "\$1" = "auth" ] && [ "\$2" = "switch" ]; then
  echo "\$4" >> "$MARKER"
  exit 0
fi
if [ "\$1" = "api" ]; then
  last="\$(tail -n1 "$MARKER" 2>/dev/null)"
  [ "\$last" = "user2" ] && exit 0
  exit 1
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  run cat "$MARKER"
  [ "$output" = "$(printf 'user1\nuser2')" ]
}

@test "no account can see the repo: tries every account, still exits 0" {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  MARKER="$BATS_TEST_TMPDIR/switch-calls"
  : > "$MARKER"
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
  echo "Logged in to github.com account user1 (keyring)"
  echo "Logged in to github.com account user2 (keyring)"
  exit 0
fi
if [ "\$1" = "auth" ] && [ "\$2" = "switch" ]; then
  echo "\$4" >> "$MARKER"
  exit 0
fi
if [ "\$1" = "api" ]; then
  exit 1
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
  git remote add origin git@github.com:acme/widgets.git
  PATH="$FAKEBIN:$PATH" run _auto_switch_run
  [ "$status" -eq 0 ]
  run cat "$MARKER"
  [ "$output" = "$(printf 'user1\nuser2')" ]
}
