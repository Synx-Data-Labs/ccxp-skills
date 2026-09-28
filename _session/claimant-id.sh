#!/usr/bin/env bash
# _session/claimant-id.sh — the ONE definition of the claimant identity.
#
#   cc1-<machine-id>:<path-hash>        (T20260911-698434)
#
# <machine-id>  8 hex, random, cached per machine. NOT derived from `hostname`:
#               hostname is not stable on one machine (mDNS vs MagicDNS vs
#               ComputerName all answer differently, and change when networking
#               software is installed), which produced false "owned by another
#               agent" verdicts against a task's own rightful owner.
# <path-hash>   16 hex of sha256(secret ‖ clone-path). Salted with the SECRET,
#               never with <machine-id>: <machine-id> is published inside the
#               claim string, so salting with it would leave the clone path
#               brute-forceable from a guessed username list.
#
# Nothing derived from the machine's name, the OS user, or the filesystem path
# is ever written to a task file — these values land on `main` in a public repo.
#
# The `cc1-` marker rides INSIDE the host field rather than being a field of its
# own, so the historical two-field <host>:<path> shape survives and readers that
# split on the first ':' (task_claim.sh's cross-repo check) keep discriminating
# per machine. See the task's "Format alternatives considered" table.
#
# DELIBERATELY SIDE-EFFECT-FREE: no `set`, no env loading, no work at source
# time. statusline-command.sh runs on every prompt render and must not inherit
# shell options or pay for I/O just to know who it is — that constraint is why
# this is its own file rather than part of _lib.sh, and why the identity is not
# reimplemented in two places (the bug class this task exists to close).

CLAIMANT_STATE_DIR="${CLAIMANT_STATE_DIR:-${HOME}/.claude/state}"

# Lowercase hex sha256 of stdin. Portable: macOS ships shasum, GNU ships
# sha256sum, and openssl covers the rest. Runs on every claim, so a missing
# binary must not be a silent failure.
claimant_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else
    printf 'claimant-id: no sha256 implementation (shasum/sha256sum/openssl)\n' >&2
    return 1
  fi
}

_claimant_rand_hex() {
  local n="${1:-8}" out=""
  out="$(od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$out" ] || out="$(uuidgen 2>/dev/null | tr -d '-' | tr 'A-F' 'a-f')"
  [ -n "$out" ] || return 1
  printf '%s' "${out:0:$n}"
}

# Read a cached secret-ish value, creating it on first use. Fails CLOSED: an
# unwritable state dir aborts rather than falling back to a hostname (which
# would reintroduce the leak) or to a per-run ephemeral value (which would make
# the agent unable to recognise its OWN prior claim — permanently recreating
# the false-`owned:` bug this task exists to kill).
_claimant_cached() {
  local name="$1" chars="$2" val file
  # Separate statement on purpose: bash expands every word of a `local` before
  # assigning any of them, so "$name" would still be empty if $file were
  # declared on the line above.
  file="$CLAIMANT_STATE_DIR/$name"
  if [ -r "$file" ]; then
    val="$(tr -d ' \t\n' < "$file" 2>/dev/null)"
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  fi
  mkdir -p "$CLAIMANT_STATE_DIR" 2>/dev/null || {
    printf 'claimant-id: cannot create %s — refusing to claim.\n' "$CLAIMANT_STATE_DIR" >&2
    return 1
  }
  val="$(_claimant_rand_hex "$chars")" || {
    printf 'claimant-id: no random source available — refusing to claim.\n' >&2
    return 1
  }
  ( umask 077; printf '%s' "$val" > "$file" ) 2>/dev/null || {
    printf 'claimant-id: cannot write %s — refusing to claim.\n' "$file" >&2
    return 1
  }
  printf '%s' "$val"
}

claimant_machine_id() { _claimant_cached machine-id 8; }
claimant_secret()     { _claimant_cached claimant-secret 32; }

claimant_clone_path() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# $1 clone path (optional; defaults to this clone). Empty + nonzero on failure,
# so every caller fails closed rather than writing a half-formed claim.
claimant_id() {
  local path="${1:-$(claimant_clone_path)}" mid secret hash
  mid="$(claimant_machine_id)"   || return 1
  secret="$(claimant_secret)"    || return 1
  hash="$(printf '%s\0%s' "$secret" "$path" | claimant_sha256)" || return 1
  printf 'cc1-%s:%s' "$mid" "${hash:0:16}"
}

# The authoritative shape test. Anchored, not a `cc1-*` glob: a machine
# genuinely named "cc1-box" writes `cc1-box:/home/...`, which must stay a
# legacy <host>:<path> claim, and a hand-assigned `cc1-Alex` must keep its
# never-auto-reclaimable protection.
claimant_is_current_shape() {
  [[ "${1:-}" =~ ^cc1-[0-9a-f]{8}:[0-9a-f]{16}$ ]]
}

# Human-facing rendering of a claimed_by value, for logs and any other place a
# person reads one. $1 claimed_by, $2 claimed_role (optional).
#
# The id is opaque by design, and a full "cc1-a1b2c3d4:9f8e7d6c5b4a3210" tells a
# reader nothing its first few characters do not. Legacy "<host>:<path>" values
# and deliberate human assignments pass through untouched so pre-migration logs
# stay readable. Mirrored in Python by sync.py's claim_display(); both are
# pinned by tests.
claimant_display() {
  local raw="${1:-}" role="${2:-}"
  [ -n "$raw" ] || { printf ''; return 0; }
  claimant_is_current_shape "$raw" || { printf '%s' "$raw"; return 0; }
  local short="${raw%%:*}"           # cc1-<machine-id>
  short="cc1-${short#cc1-}"
  short="${short:0:10}"              # cc1- + 6 hex
  if [ -n "$role" ]; then printf '%s (%s)' "$short" "$role"; else printf '%s' "$short"; fi
}
