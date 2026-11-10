#!/usr/bin/env bash
# refresh-env: keep <dir>/.env (the cache of <dir>/.env.tpl) fresh BY CONTENT,
# not mtime. Self-contained so the skill can copy it to <dir>/refresh-env and
# any process (direnv, launchd, Claude Code hooks, scripts) can call it.
#
#   refresh-env [--check|--force] [dir]
#
# State (hashes only, mode 0600, never values) lives next to the cache:
#   .env.tpl.sha256  hash of .env.tpl at the last refresh
#   .env.sha256      hash of the .env the generator wrote
# .env is fresh iff it is non-empty and both hashes still match; otherwise a
# hand edit, a rewritten template or a missing state file triggers `op inject`.
#
# Exit codes: 0 fresh/refreshed, 1 error, 2 usage or no .env.tpl,
#   3 stale (--check only), 10 op missing, 75 needs the owner's unlock,
#   timed out, or lock held (callers must NOT load the stale cache).
#
# Env: OP_ACCOUNT, REFRESH_ENV_OP_TIMEOUT (default 60s),
#   REFRESH_ENV_LOCK_WAIT (default 10s),
#   REFRESH_ENV_SWEEP_MINS (default 10): leftover .env.tmp.*/.env.err.* older
#   than this, and not open by any process, are removed on the next run.

re-sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    echo "refresh-env: need shasum or sha256sum" >&2
    return 1
  fi
}

# Print why <dir>/.env is stale, or nothing when fresh.
re-stale-reason() {
  local dir="$1" stored cur
  [ -s "$dir/.env" ] || { echo "missing"; return 0; }
  if [ ! -f "$dir/.env.tpl.sha256" ] || [ ! -f "$dir/.env.sha256" ]; then
    echo "no-state"; return 0
  fi
  cur="$(re-sha256 "$dir/.env.tpl")" || return 1
  stored="$(cat "$dir/.env.tpl.sha256")"
  [ "$cur" = "$stored" ] || { echo "tpl-changed"; return 0; }
  cur="$(re-sha256 "$dir/.env")" || return 1
  stored="$(cat "$dir/.env.sha256")"
  [ "$cur" = "$stored" ] || { echo "env-edited-outside-generator"; return 0; }
}

# Key NAMES (never values) the template defines as op:// references whose
# .env line is missing or still an unresolved op:// string. Simple KEY=value
# lines only (optional `export`, comments skipped).
re-drift-keys() {
  local dir="$1" line key tpl_val env_line env_val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#export }"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    tpl_val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ "$tpl_val" == *op://* ]] || continue
    env_line="$(grep -E "^(export )?${key}=" "$dir/.env" 2>/dev/null | head -n 1 || true)"
    if [ -z "$env_line" ]; then echo "$key"; continue; fi
    env_val="${env_line#*=}"
    env_val="${env_val#[\"\']}"
    [[ "$env_val" == op://* ]] && echo "$key"
  done <"$dir/.env.tpl"
  return 0
}

# Run `op inject` with a bounded wait. Returns 124 on timeout.
re-run-op() {
  local tpl="$1" out="$2" errf="$3" tmo="${REFRESH_ENV_OP_TIMEOUT:-60}"
  # No empty-array expansion: bash 3.2 (macOS) fails on it under set -u.
  if [ -n "${OP_ACCOUNT:-}" ]; then
    op inject -i "$tpl" -o "$out" --account "$OP_ACCOUNT" >/dev/null 2>"$errf" &
  else
    op inject -i "$tpl" -o "$out" >/dev/null 2>"$errf" &
  fi
  local pid=$! ticks=0 max=$((tmo * 10))
  _RE_PID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

re-unlock-msg() {
  echo "refresh-env: 1Password needs your unlock (biometric/approval) to refresh $1/.env." \
       "Unlock the 1Password app, then run: $1/refresh-env $1 (or: refresh-env $1)." \
       "The stale cache was NOT changed; do not load it." >&2
}

# op's stderr, minus any line that could quote a template value.
re-safe-err() { grep -v -e 'op://' -e '=' "$1" 2>/dev/null | head -n 3 || true; }

# Temp files of the refresh in flight; removed by the signal/EXIT traps and
# after every refresh, so no exit path leaves them behind.
_RE_TMP=""; _RE_ERR=""
re-cleanup() { rm -f "${_RE_TMP:-}" "${_RE_ERR:-}"; _RE_TMP=""; _RE_ERR=""; }

# Remove leftovers of killed runs (SIGKILL, older helper versions, an old
# inline .envrc): only the exact mktemp shape, regular files, older than
# REFRESH_ENV_SWEEP_MINS, and not open by a live process (when lsof exists).
re-sweep-stale() {
  local dir="$1" mins="${REFRESH_ENV_SWEEP_MINS:-10}" f
  case "$mins" in ''|*[!0-9]*) mins=10 ;; esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if command -v lsof >/dev/null 2>&1 && lsof -- "$f" >/dev/null 2>&1; then continue; fi
    rm -f "$f"
  done < <(find "$dir" -maxdepth 1 -type f \( -name '.env.tmp.??????' -o -name '.env.err.??????' \) -mmin "+$mins" 2>/dev/null)
  return 0
}

re-lock() {
  local lock="$1/.env.refresh.lock" waited=0 max=$(( ${REFRESH_ENV_LOCK_WAIT:-10} * 5 )) p
  while ! mkdir "$lock" 2>/dev/null; do
    p="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
      rm -rf "$lock"; continue   # holder died: break the stale lock
    fi
    [ "$waited" -ge "$max" ] && return 1
    sleep 0.2
    waited=$((waited + 1))
  done
  echo "$$" >"$lock/pid"
}
re-unlock() { rm -rf "$1/.env.refresh.lock"; }

# Refresh under the lock; assumes the caller decided a refresh is needed.
re-do-refresh() {
  local dir="$1" tmp errf rc=0 reason line tpl_hash env_hash
  if ! command -v op >/dev/null 2>&1; then
    echo "op (1Password CLI) not installed -- cannot refresh $dir/.env." \
         "Install via 'brew install 1password-cli', then run: op inject -i $dir/.env.tpl -o $dir/.env" >&2
    return 10
  fi
  tmp="$(umask 077 && mktemp "$dir/.env.tmp.XXXXXX")" || { echo "refresh-env: cannot write in $dir" >&2; return 1; }
  _RE_TMP="$tmp"
  errf="$(umask 077 && mktemp "$dir/.env.err.XXXXXX")" || { re-cleanup; return 1; }
  _RE_ERR="$errf"
  tpl_hash="$(re-sha256 "$dir/.env.tpl")" || { rm -f "$tmp" "$errf"; return 1; }
  re-run-op "$dir/.env.tpl" "$tmp" "$errf" || rc=$?
  if [ "$rc" -eq 124 ]; then
    re-unlock-msg "$dir"; rm -f "$tmp" "$errf"; return 75
  elif [ "$rc" -ne 0 ]; then
    if ! grep -q "isn't a vault in this account" "$errf" \
       && grep -qiE 'not signed in|sign in|unlock|biometric|session expired|authentication required' "$errf"; then
      re-unlock-msg "$dir"; rm -f "$tmp" "$errf"; return 75
    fi
    echo "failed: op inject for $dir/.env.tpl" >&2
    re-safe-err "$errf" >&2
    if grep -q "isn't a vault in this account" "$errf"; then
      echo "hint: the signed-in 1Password account doesn't have this vault -- set OP_ACCOUNT (e.g. OP_ACCOUNT=my.1password.com) and retry" >&2
    fi
    rm -f "$tmp" "$errf"; return 1
  fi
  [ -s "$tmp" ] || { echo "failed: op inject produced an empty file" >&2; rm -f "$tmp" "$errf"; return 1; }
  re-safe-err "$errf" >&2
  env_hash="$(re-sha256 "$tmp")" || { rm -f "$tmp" "$errf"; return 1; }
  # Hashes first, then the move: a reader never sees a mismatch on a healthy cache.
  ( umask 077; printf '%s\n' "$tpl_hash" >"$dir/.env.tpl.sha256"; printf '%s\n' "$env_hash" >"$dir/.env.sha256" )
  chmod 600 "$tmp"
  mv -f "$tmp" "$dir/.env"
  rm -f "$errf"
  echo "materialized: $dir/.env"
}

refresh-env() {
  local mode="refresh" dir="" arg reason rc=0 keys
  for arg in "$@"; do
    case "$arg" in
      --check) mode="check" ;;
      --force) mode="force" ;;
      -*) echo "usage: refresh-env [--check|--force] [dir]" >&2; return 2 ;;
      *) dir="$arg" ;;
    esac
  done
  dir="$(cd "${dir:-.}" 2>/dev/null && pwd)" || { echo "error: no such directory: ${dir:-.}" >&2; return 2; }
  [ -f "$dir/.env.tpl" ] || { echo "error: $dir/.env.tpl not found" >&2; return 2; }

  reason="$(re-stale-reason "$dir")" || return 1
  if [ "$mode" = "check" ]; then
    if [ -z "$reason" ]; then echo "fresh"; return 0; fi
    echo "stale: $reason"
    keys="$(re-drift-keys "$dir")"
    [ -n "$keys" ] && while IFS= read -r arg; do echo "drift: $arg"; done <<<"$keys"
    return 3
  fi
  re-sweep-stale "$dir"
  if [ "$mode" = "force" ]; then reason="forced"; fi
  if [ -z "$reason" ]; then
    echo "unchanged: $dir/.env fresh (content hash matches .env.tpl)"
    return 0
  fi
  echo "refresh-env: refreshing $dir/.env (reason: $reason)" >&2
  re-lock "$dir" || { echo "refresh-env: another refresh holds $dir/.env.refresh.lock; try again shortly" >&2; return 75; }
  # Killed mid-refresh (Ctrl-C, direnv abort, SIGTERM): drop temp files holding
  # resolved secrets, the lock, and the orphaned op.
  _RE_PID=""
  trap 'kill "${_RE_PID:-0}" 2>/dev/null; re-cleanup; re-unlock "'"$dir"'"; exit 75' INT TERM HUP
  # Another caller may have refreshed while we waited for the lock.
  reason="$(re-stale-reason "$dir")" || reason="error"
  if [ "$mode" != "force" ] && [ -z "$reason" ]; then
    trap - INT TERM HUP; re-unlock "$dir"
    echo "unchanged: $dir/.env fresh (refreshed by another caller)"
    return 0
  fi
  re-do-refresh "$dir" || rc=$?
  re-cleanup   # every return path of re-do-refresh, success or failure
  trap - INT TERM HUP
  re-unlock "$dir"
  return "$rc"
}

# Run only when executed directly. An installed copy named `refresh-env`
# defaults to its own directory so callers need no argument.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
  trap 're-cleanup' EXIT   # direct run only: a sourced caller's EXIT trap stays untouched
  default_dir="."
  [ "$(basename "$0")" = "refresh-env" ] && default_dir="$(cd "$(dirname "$0")" && pwd)"
  has_dir=0
  for a in "$@"; do case "$a" in -*) ;; *) has_dir=1 ;; esac; done
  if [ "$has_dir" = 1 ]; then refresh-env "$@"; else refresh-env "$@" "$default_dir"; fi
fi
