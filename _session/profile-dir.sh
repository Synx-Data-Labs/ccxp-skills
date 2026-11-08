#!/usr/bin/env bash
# _session/profile-dir.sh — the ONE definition of "which Claude Code profile
# dir is this session running under" (T20261108-315759).
#
# Sets the plain variable CCXP_PROFILE_DIR once, at source time, and defines two
# functions. Resolution order, first match wins:
#   1. CLAUDE_CONFIG_DIR when set and non-empty (the running session is
#      authoritative; a named profile is used even before its dir exists)
#   2. this file's own LOGICAL absolute path when it lies under
#      <profile>/plugins/cache/ (hooks and cron run from the plugin cache and
#      may carry no CLAUDE_CONFIG_DIR); the LAST such segment splits it
#   3. $HOME/.claude — the legacy default, the only place that literal may live
#
# DELIBERATELY SIDE-EFFECT-FREE, like claimant-id.sh: no `set`, no writes, no
# exports, tolerates an unset HOME. Only `cd`/`pwd` and string work at source
# time, so HUD polls and prompt hooks can source it. Bash-only (BASH_SOURCE).
#
# Callers read "$CCXP_PROFILE_DIR" directly on hot paths. A caller that cannot
# find this file leaves the variable empty and must skip its profile-dependent
# read or write — never guess ~/.claude.
#
# lint: _session/lint_profile_dir.sh fails on a bare ~/.claude elsewhere.

_ccxp_profile_dir_resolve() {
  local here p
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    p="${CLAUDE_CONFIG_DIR}"
  else
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
    case "$here/" in
      */plugins/cache/*) p="${here%/plugins/cache/*}" ;;
      *) p="" ;;
    esac
    [ -n "$p" ] || p="${HOME:-}/.claude" # profile-dir-ok
  fi
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

CCXP_PROFILE_DIR="$(_ccxp_profile_dir_resolve)"

# The profile dir. Cheap: prints the value computed at source time.
ccxp_profile_dir() { printf '%s\n' "$CCXP_PROFILE_DIR"; }

# Candidate .env files, one per line: <profile>/.env, then the legacy
# $HOME/.claude/.env when it is a different path. Existence is the caller's check.
ccxp_env_files() {
  printf '%s\n' "$CCXP_PROFILE_DIR/.env"
  local legacy="${HOME:-}/.claude/.env" # profile-dir-ok
  [ "$legacy" = "$CCXP_PROFILE_DIR/.env" ] || printf '%s\n' "$legacy"
}

# First existing candidate from ccxp_env_files; prints nothing and returns 1 when
# none exists. For the machine-global .env loaders.
ccxp_first_env_file() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done < <(ccxp_env_files)
  return 1
}
