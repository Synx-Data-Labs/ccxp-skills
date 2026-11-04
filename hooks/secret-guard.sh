#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Denies a command line that carries a secret
# (token-shaped literal, --token/--password <value>, curl -u user:pass, echo or
# env dump of a secret variable, set -x with a secret) and tells the agent the
# safe form. The analysis lives in secret-guard.py; the deny message never
# contains the matched value (masked to a few characters plus "...").
#
# - Deny is a JSON permissionDecision "deny" on stdout (exit 0), like rm-guard.sh.
# - Fails OPEN: no python3, a crash or unparsable input prints one line on stderr
#   and allows the call.
# - Override: CCXP_ALLOW_SECRETS=1 in the environment of the Claude Code process
#   allows the call and appends one line (UTC timestamp and rule ids, never the
#   command) to ${CCXP_SECRET_GUARD_LOG:-$HOME/.claude/secret-guard-overrides.log}.
#   Unlike rm-guard it still runs the analyzer first so the log can name the
#   rules; with no python3 it logs "unknown".
# - Rule ids mirror scripts/lint-secret-handling.sh in the hub repo (see
#   tests/secret_guard_rules.bats); set-x-secret here means the same command line.
set -uo pipefail

function secret-guard-log() {
  local rules=${1:-unknown} log
  log="${CCXP_SECRET_GUARD_LOG:-$HOME/.claude/secret-guard-overrides.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s override rules=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${rules:-none}" >>"$log" 2>/dev/null || true
}

function secret-guard() {
  local dir out rc input
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  input="$(cat)"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "secret-guard: python3 not found; allowing the command" >&2
    [[ "${CCXP_ALLOW_SECRETS:-}" == 1 ]] && secret-guard-log unknown
    return 0
  fi
  if [[ "${CCXP_ALLOW_SECRETS:-}" == 1 ]]; then
    out="$(printf '%s' "$input" | SECRET_GUARD_REPORT_ONLY=1 python3 -I "$dir/secret-guard.py")" || out=unknown
    [[ -n "$out" ]] && secret-guard-log "$out"
    return 0
  fi
  out="$(printf '%s' "$input" | python3 -I "$dir/secret-guard.py")"; rc=$?
  if (( rc != 0 )); then
    echo "secret-guard: analyzer exited $rc; allowing the command" >&2
    return 0
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  secret-guard "$@"
fi
