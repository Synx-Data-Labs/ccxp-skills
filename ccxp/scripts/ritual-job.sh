#!/usr/bin/env bash
# ccxp/scripts/ritual-job.sh — pure decisions for a /ccxp ritual job run by the
# ccxp-agent persona (T20261113-927500). It sends and changes nothing.
#
#   ritual-job.sh skip-sync [--dir DIR]
#       Phase 0 gate. Prints "skip" (exit 0) when CCXP_CRON_MODE=1 and DIR (default
#       the cwd) is a linked git worktree, i.e. a persona job, whose clone the
#       persona already fetched. Prints "sync" (exit 10) otherwise.
#   ritual-job.sh rca-reuse --now EPOCH [--live-job yes|no]
#       Reads the alert thread replies on stdin, one "ts<TAB>text" line per reply, and
#       asks labrun.sh thread-state (same marker, mention and ack rules). Prints
#       "reuse <classification> <task-id|none>" (exit 0) for a posted *RCA reply,
#       "wait" (exit 11) while only a fresh "🔍 Running RCA" ack or a live job is there,
#       else "run-rca" (exit 10).
#   ritual-job.sh channel standup|standup-id|alerts
#       Prints the configured Slack channel; exit 3 and a message on stderr when
#       unset (no default). standup = SLACK_STANDUP_CHANNEL, else CCXP_SLACK_CHANNEL;
#       standup-id = SLACK_STANDUP_CHANNEL_ID; alerts = SLACK_AUTOMATION_ALERTS_CHANNEL_ID.
#       Lookup order, first set wins: exported, then each file of RITUAL_JOB_ENV_FILES
#       (colon-separated; default the profile .env files, then $(pwd)/.env).
# Exit: 2 usage.

_rj_die() { echo "ritual-job.sh: $1" >&2; exit "${2:-2}"; }

rj_skip_sync() {
  local dir="." gd cgd
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || _rj_die "--dir needs a value"; dir="$2"; shift 2 ;;
      *) _rj_die "unknown argument: $1" ;;
    esac
  done
  if [ "${CCXP_CRON_MODE:-0}" = 1 ]; then
    gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
    cgd="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cgd=""
    if [ -n "$gd" ] && [ -n "$cgd" ] && [ "$gd" != "$cgd" ]; then
      echo skip; return 0
    fi
  fi
  echo sync; return 10
}

rj_rca_reuse() {
  local replies rc ts text cls act id state here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  replies="$(cat)"
  # Share labrun.sh thread-state's marker logic (done / wait / continue) instead of copying it.
  state="$(printf '%s\n' "$replies" | bash "$here/../../labrun-rca/scripts/labrun.sh" thread-state "$@")"; rc=$?
  case "$rc" in
    10) ;;
    11) echo wait; return 11 ;;
    0) echo run-rca; return 10 ;;
    *) _rj_die "labrun.sh thread-state failed (exit $rc)" "$rc" ;;
  esac
  while IFS=$'\t' read -r ts text || [ -n "$ts$text" ]; do
    text="${text//$'\r'/}"
    while [[ "$text" =~ ^([[:space:]]+|\<[@!][^\>]*\>) ]]; do text="${text:${#BASH_REMATCH[0]}}"; done
    [[ "$ts" =~ ^[0-9]{9,}(\.[0-9]+)?$ ]] || continue
    case "$text" in
      '*RCA'*)
        # One flattened line per reply (a literal "\n" may stand for a newline); split on the field labels.
        cls="$(printf '%s' "$text" | sed -n 's/.*\*Classification:\* *\([^*]*\)\*Confidence:\*.*/\1/p' | sed 's/\\n[[:space:]]*$//; s/[[:space:]]*$//')"
        act="$(printf '%s' "$text" | sed -n 's/.*\*Action:\* *//p')"
        id="$(printf '%s' "$act" | grep -oE 'T[0-9]{8}-[0-9]{6}' | head -1)"
        echo "reuse ${cls:-unknown} ${id:-none}"; return 0 ;;
    esac
  done <<< "$replies"
  echo "$state"; return 10
}

_rj_env_files() {
  local f here
  if [ -n "${RITUAL_JOB_ENV_FILES+x}" ]; then
    printf '%s\n' "$RITUAL_JOB_ENV_FILES" | tr ':' '\n'
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  [ -r "$here/../../_session/profile-dir.sh" ] && source "$here/../../_session/profile-dir.sh"
  if command -v ccxp_env_files >/dev/null 2>&1; then ccxp_env_files; fi
  f="$(pwd)/.env"; printf '%s\n' "$f"
}

# value of VAR from the first env file that sets it non-empty (read, never sourced)
_rj_lookup() { # <VAR>
  local v="${!1:-}" f line
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$f" | tail -1)" || line=""
    [ -n "$line" ] || continue
    v="${line#*=}"; v="${v//$'\r'/}"
    case "$v" in \"*) v="${v#\"}"; v="${v%%\"*}" ;; \'*) v="${v#\'}"; v="${v%%\'*}" ;; *) v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}" ;; esac
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done < <(_rj_env_files)
  return 1
}

rj_channel() {
  [ $# -eq 1 ] || _rj_die "usage: ritual-job.sh channel standup|standup-id|alerts"
  local v
  case "$1" in
    standup)
      v="$(_rj_lookup SLACK_STANDUP_CHANNEL)" || v="$(_rj_lookup CCXP_SLACK_CHANNEL)" \
        || { echo "ritual-job.sh: standup channel not configured (SLACK_STANDUP_CHANNEL or CCXP_SLACK_CHANNEL)" >&2; return 3; } ;;
    standup-id)
      v="$(_rj_lookup SLACK_STANDUP_CHANNEL_ID)" \
        || { echo "ritual-job.sh: SLACK_STANDUP_CHANNEL_ID not configured" >&2; return 3; } ;;
    alerts)
      v="$(_rj_lookup SLACK_AUTOMATION_ALERTS_CHANNEL_ID)" \
        || { echo "ritual-job.sh: SLACK_AUTOMATION_ALERTS_CHANNEL_ID not configured" >&2; return 3; } ;;
    *) _rj_die "unknown channel: $1 (standup|standup-id|alerts)" ;;
  esac
  printf '%s\n' "${v#\#}"
}

ritual_job_main() {
  [ $# -ge 1 ] || _rj_die "usage: ritual-job.sh skip-sync|rca-reuse|channel ..."
  local sub="$1"; shift
  case "$sub" in
    skip-sync) rj_skip_sync "$@" ;;
    rca-reuse) rj_rca_reuse "$@" ;;
    channel) rj_channel "$@" ;;
    *) _rj_die "unknown subcommand: $sub (skip-sync|rca-reuse|channel)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  ritual_job_main "$@"
fi
