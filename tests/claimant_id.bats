#!/usr/bin/env bats
# Tests for _session/claimant-id.sh — the ONE definition of the claimant
# identity written to `claimed_by:` (T20260911-698434).
#
# This suite carries the three assertions no pre-existing suite could make:
#   - the FORMAT CONTRACT every other suite's fixtures are validated against
#   - the PRIVACY guard (nothing derived from hostname/user/path survives into
#     a value that gets committed to `main` in a public repo)
#   - the YAML guard (the written line must survive yaml.safe_load, which
#     sync.py and lint_tasks.py both depend on)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  source "$REPO_ROOT/_session/claimant-id.sh"
}

# --- format contract --------------------------------------------------------

@test "claimant_id matches the anchored cc1- shape" {
  claimant_is_current_shape "$(claimant_id /some/repo)"
}

@test "claimant_is_current_shape accepts only the exact shape" {
  claimant_is_current_shape 'cc1-a1b2c3d4:9f8e7d6c5b4a3210'
  ! claimant_is_current_shape 'cc1-a1b2c3d4'                      # no path-hash
  ! claimant_is_current_shape 'cc1-a1b2c3d4:9f8e'                  # hash too short
  ! claimant_is_current_shape 'cc1-A1B2C3D4:9f8e7d6c5b4a3210'      # uppercase
  ! claimant_is_current_shape 'cc2-a1b2c3d4:9f8e7d6c5b4a3210'      # unknown version
  ! claimant_is_current_shape 'cc1-box:/home/x'                    # legacy plaintext
  ! claimant_is_current_shape 'cc1-Alex'                           # human override
  ! claimant_is_current_shape ''
}

@test "the machine half stays distinct per machine (what the cross-repo guard rests on)" {
  # Splitting on the FIRST ':' must still yield something machine-specific.
  # Under a "cc1:<id>:<hash>" spelling this would be the literal "cc1" for
  # every claim and task_claim.sh's foreign-machine guard would pass for
  # everyone. This pins the reason the version marker rides inside the field.
  local id host; id="$(claimant_id /some/repo)"; host="${id%%:*}"
  [[ "$host" =~ ^cc1-[0-9a-f]{8}$ ]]
}

# --- identity behaviour -----------------------------------------------------

@test "stable across calls for one clone, distinct across clones" {
  [ "$(claimant_id /clone/a)" = "$(claimant_id /clone/a)" ]
  [ "$(claimant_id /clone/a)" != "$(claimant_id /clone/b)" ]
}

@test "unchanged when hostname drifts on the same machine (the original repro)" {
  hostname() { printf 'Shines-Laptop.local'; }
  local before; before="$(claimant_id /clone/x)"
  hostname() { printf 'shines-laptop-1.tailnet.ts.net'; }
  [ "$(claimant_id /clone/x)" = "$before" ]
}

@test "machine-id and secret are generated once and reused" {
  local first; first="$(claimant_machine_id)"
  [ "$(claimant_machine_id)" = "$first" ]
  [ -f "$CLAIMANT_STATE_DIR/machine-id" ]
  [ "$(cat "$CLAIMANT_STATE_DIR/machine-id")" = "$first" ]
}

@test "the secret is distinct from the machine-id and not world-readable" {
  local mid sec; mid="$(claimant_machine_id)"; sec="$(claimant_secret)"
  [ -n "$sec" ] && [ "$sec" != "$mid" ]
  # 600: the secret is what makes the path hash unguessable, so it must not
  # leak to other users on a shared box.
  [ "$(stat -c %a "$CLAIMANT_STATE_DIR/claimant-secret" 2>/dev/null || stat -f %Lp "$CLAIMANT_STATE_DIR/claimant-secret")" = "600" ]
}

@test "a machine-id is NOT enough to derive the path hash (salted with the secret)" {
  # Guards the decision to salt with the secret rather than the machine-id:
  # the machine-id is published inside the claim, so hashing with it would
  # leave the clone path brute-forceable from a guessed username list.
  local id mid naive
  id="$(claimant_id /home/someone/workspace/repo)"
  mid="$(claimant_machine_id)"
  naive="$(printf '%s\0%s' "$mid" /home/someone/workspace/repo | claimant_sha256)"
  [ "${id#*:}" != "${naive:0:16}" ]
}

# --- fail closed ------------------------------------------------------------

@test "fails closed when the state dir cannot be created" {
  # Never fall back to a hostname (reintroduces the leak) and never mint an
  # ephemeral secret (the agent would stop recognising its own prior claim).
  CLAIMANT_STATE_DIR="/proc/cannot-create-here"
  run claimant_id /some/repo
  [ "$status" -ne 0 ]
  [[ "$output" != cc1-* ]]
}

@test "fails closed rather than emitting a partial id" {
  CLAIMANT_STATE_DIR="/proc/cannot-create-here"
  run claimant_id /some/repo
  [[ "$output" != *":"* ]] || [[ "$output" == *"refusing to claim"* ]]
}

# --- portability ------------------------------------------------------------

@test "claimant_sha256 agrees across every available implementation" {
  # Field differs by implementation: shasum/sha256sum print "<hash>  -" ($1),
  # openssl prints "SHA2-256(stdin)= <hash>" ($NF). claimant_sha256 already
  # picks the right one per branch; this mirrors that.
  local expect="" got
  command -v shasum >/dev/null 2>&1 && expect="$(printf 'abc' | shasum -a 256 | awk '{print $1}')"
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(printf 'abc' | sha256sum | awk '{print $1}')"
    [ -n "$expect" ] || expect="$got"
    [ "$got" = "$expect" ]
  fi
  if command -v openssl >/dev/null 2>&1; then
    got="$(printf 'abc' | openssl dgst -sha256 | awk '{print $NF}')"
    [ -n "$expect" ] || expect="$got"
    [ "$got" = "$expect" ]
  fi
  [ -n "$expect" ]
  [ "$(printf 'abc' | claimant_sha256)" = "$expect" ]
}

@test "claimant_sha256 still works when shasum is absent (the macOS/GNU split)" {
  # A missing binary here breaks EVERY claim, so the fallback chain is
  # load-bearing rather than defensive decoration.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  for c in sha256sum awk tr od; do
    command -v "$c" >/dev/null 2>&1 && ln -sf "$(command -v "$c")" "$bin/$c"
  done
  # Absolute bash: `env PATH=... bash` would resolve bash via the NEW PATH.
  run env PATH="$bin" "$BASH" -c "source '$REPO_ROOT/_session/claimant-id.sh'; printf 'abc' | claimant_sha256"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'abc' | sha256sum | awk '{print $1}')" ]
}

# --- the two guards that stop this class of bug recurring -------------------

@test "PRIVACY: a written claimed_by carries no hostname, OS user or path" {
  local id; id="$(claimant_id "/Users/someone/workspace/acme/repo")"
  [[ "$id" != *"$(hostname)"* ]]
  [[ "$id" != *"/Users/"* ]]
  [[ "$id" != *"/home/"* ]]
  [[ "$id" != *"someone"* ]]
  [[ "$id" != *".ts.net"* ]]
  [[ "$id" != *"acme"* ]]
}

@test "YAML: the frontmatter line round-trips through yaml.safe_load as a string" {
  # sync.py:643 and lint_tasks.py:54 both yaml.safe_load this block. A value
  # like "[cc1] <mid>:<hash>" raises ParserError and would break board sync and
  # the task linter on every claimed task — with no bats test able to see it.
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  python3 -c 'import yaml' 2>/dev/null || skip "pyyaml unavailable"
  local id; id="$(claimant_id /some/repo)"
  run python3 -c "
import sys, yaml
v = yaml.safe_load('claimed_by: ' + sys.argv[1])['claimed_by']
assert isinstance(v, str), type(v)
assert v == sys.argv[1], (v, sys.argv[1])
print('ok')
" "$id"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- human-facing rendering -------------------------------------------------

@test "claimant_display shortens a current id and appends the role" {
  [ "$(claimant_display 'cc1-a1b2c3d4:9f8e7d6c5b4a3210' ccxp)" = "cc1-a1b2c3 (ccxp)" ]
  [ "$(claimant_display 'cc1-a1b2c3d4:9f8e7d6c5b4a3210')" = "cc1-a1b2c3" ]
}

@test "claimant_display passes legacy and human-assigned values through untouched" {
  # Pre-migration log lines and board rows must not change shape underneath
  # anyone, and a hand-assigned name is already the most readable form.
  [ "$(claimant_display 'cdw:/home/ci/repo')" = "cdw:/home/ci/repo" ]
  [ "$(claimant_display 'Alex')" = "Alex" ]
  [ "$(claimant_display 'cc1-a1b2c3d4')" = "cc1-a1b2c3d4" ]
  [ -z "$(claimant_display '')" ]
}

@test "claimant_display agrees with sync.py's claim_display (same value, two languages)" {
  # The rendering exists in bash (logs) and Python (the Project board). They
  # must not drift; this is the only thing that would catch it.
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  local id='cc1-a1b2c3d4:9f8e7d6c5b4a3210'
  local from_sh from_py
  from_sh="$(claimant_display "$id" ccxp)"
  from_py="$(cd "$REPO_ROOT" && GH_REPO=o/r GH_TOKEN=x PROJECT_OWNER=o PROJECT_NUMBER=1 \
    python3 -c "
import sys; sys.path.insert(0, 'actions/sync-tasks')
from sync import claim_display
print(claim_display(sys.argv[1], 'ccxp'))
" "$id")"
  [ "$from_sh" = "$from_py" ]
}
