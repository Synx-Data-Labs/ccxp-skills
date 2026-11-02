#!/usr/bin/env bash
# SessionStart(startup) hook: opt-in auto-update of the ccxp-skills plugin (`/update auto on`).
# Silent no-op (exit 0, no output) when auto is off, throttled (~6 h), offline, jq/git missing or on any
# error: it never blocks session start (hard time limit below). When a newer release exists it downloads it
# (update.sh --quiet --no-agent), refreshes the persona with the NEW version's agent-pairing.sh (backup kept),
# and emits ONE systemMessage per version. MAJOR bumps are held (notice only); while autopilot is busy in the
# session's repo nothing is changed. It never restarts anything and cannot run /reload-plugins: a running
# session only loads the new version when the user types /reload-plugins. See update/SKILL.md.
set -uo pipefail

THROTTLE_SECS="${CCXP_UPDATE_THROTTLE_SECS:-21600}"
LIMIT_SECS="${CCXP_UPDATE_LIMIT_SECS:-20}"

function update-check() {
  command -v jq >/dev/null 2>&1 || return 0
  local here dir json cwd state now last
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  state="$dir/ccxp-skills-auto-update.json"
  [ -f "$state" ] || return 0
  [ "$(jq -r '.enabled // false' "$state" 2>/dev/null)" = true ] || return 0   # off: instant exit
  command -v git >/dev/null 2>&1 || return 0

  # shellcheck source=../update/scripts/auto.sh
  . "$here/../update/scripts/auto.sh" 2>/dev/null || return 0
  # shellcheck source=../update/scripts/update.sh
  . "$here/../update/scripts/update.sh" 2>/dev/null || return 0
  set +e +o pipefail
  export CLAUDE_DIR="$dir"

  now="$(date +%s)"
  last="$(auto_state_get "$dir" '.lastCheck')"
  if [[ "$last" =~ ^[0-9]+$ ]] && [ $(( now - last )) -lt "$THROTTLE_SECS" ]; then return 0; fi

  json="$(cat 2>/dev/null)"; cwd="$(jq -r '.cwd // empty' <<<"$json" 2>/dev/null)"; cwd="${cwd:-$PWD}"

  export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10
  local latest installed loaded=""
  latest="$(latest_version)"
  [ -n "$latest" ] || return 0   # offline / failed: stay silent, do not advance lastCheck
  auto_state_merge "$dir" "{\"lastSeen\":\"$latest\"}" || return 0
  # lastCheck (the throttle stamp) is written only once the decision is final; a busy skip or a failed
  # update leaves it alone so the next session start retries.
  checked() { auto_state_merge "$dir" "{\"lastCheck\":$now,\"lastCheckIso\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"; }

  installed="$(installed_version)"
  [[ "$installed" =~ $SEMVER_RE ]] || return 0
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || loaded="$(basename "$CLAUDE_PLUGIN_ROOT")"
  [[ "$loaded" =~ $SEMVER_RE ]] || loaded="$installed"

  # Autopilot state of the session's repo (a hot update must not land mid-cycle).
  local ap="$cwd/dev/.autopilot-state.json" ap_status="off" ap_busy=0
  if [ -f "$ap" ]; then
    ap_status="$(jq -r '.status // "off"' "$ap" 2>/dev/null)"
    # busy_since set and under 3 h old (older = a crashed cycle, same rule as autopilot-state.sh); unparseable = busy.
    if [ "$(jq -r 'if .busy_since == null then "no" else (try ((now - (.busy_since | sub("\\.[0-9]+";"") | fromdateiso8601)) < 10800) catch true | tostring) end' "$ap" 2>/dev/null)" = true ]; then ap_busy=1; fi
  fi

  local hold major_new major_cur
  hold="$(auto_state_get "$dir" '.holdMajor')"; [ "$hold" = false ] || hold=true
  major_new="${latest%%.*}"; major_cur="${installed%%.*}"

  if ver_gt "$latest" "$installed"; then
    if [ "$hold" = true ] && [ "$major_new" != "$major_cur" ]; then
      checked
      if [ "$(auto_state_get "$dir" '.notifiedFor')" != "$latest" ]; then
        auto_state_merge "$dir" "{\"notifiedFor\":\"$latest\"}"
        emit "ccxp-skills $latest is a MAJOR release (installed $installed), so auto-update is holding it. Review the release notes, then run /update to install it."
      fi
      return 0
    fi
    [ "$ap_busy" = 0 ] || return 0   # autopilot is mid-cycle: skip, retried at the next session start
    bash "$here/../update/scripts/update.sh" --quiet --no-agent --claude-dir "$dir" >/dev/null 2>&1 || return 0
    installed="$(installed_version)"
    [[ "$installed" =~ $SEMVER_RE ]] || return 0
  fi
  checked

  # Newest installed version differs from what this session loaded: refresh persona once, tell the user once.
  [ "$installed" != "$loaded" ] || return 0
  [ "$(auto_state_get "$dir" '.notifiedFor')" != "$installed" ] || return 0
  local persona="not refreshed (run /agent-pairing update)" newdir
  if [ "$(auto_state_get "$dir" '.personaFor')" = "$installed" ]; then
    persona="refreshed"
  else
    newdir="$dir/plugins/cache/ccxp-skills/ccxp-skills/$installed"
    if [ -f "$newdir/agent-pairing/scripts/agent-pairing.sh" ] \
       && bash "$newdir/agent-pairing/scripts/agent-pairing.sh" update --claude-dir "$dir" >/dev/null 2>&1; then
      auto_state_merge "$dir" "{\"personaFor\":\"$installed\"}"; persona="refreshed, backup kept"
    fi
  fi
  auto_state_merge "$dir" "{\"notifiedFor\":\"$installed\",\"loaded\":\"$loaded\",\"installed\":\"$installed\"}"

  local jobs ap3
  if [ "$ap_busy" = 1 ]; then jobs="autopilot is busy right now, so wait for it"; else jobs="autopilot is not busy in this repo"; fi
  if [ "$ap_status" = on ]; then ap3="autopilot was on, so turn it back on"; else ap3="only if you use it"; fi
  emit "ccxp-skills $installed is installed (this session still runs $loaded; a running session cannot load it by itself). In order: 1) type /reload-plugins to load it now; 2) restart once no jobs are running (persona $persona; a restart ends background jobs; $jobs); 3) then /autopilot on ($ap3)."
}

# emit MESSAGE: one systemMessage for the user + the same text as context for the main-session agent.
function emit() {
  jq -cn --arg m "$1" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
}

# kill_tree PID: TERM the process and all its descendants (a hung `claude plugin update` is a grandchild).
function kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null
}

# Hard time limit: the check runs in the background and is killed after LIMIT_SECS.
function update-check-limited() {
  exec 3<&0   # a background job would otherwise get /dev/null as stdin
  update-check <&3 &
  local pid=$! wd
  ( sleep "$LIMIT_SECS"; kill_tree "$pid" ) >/dev/null 2>&1 </dev/null &
  wd=$!
  wait "$pid" 2>/dev/null
  kill "$wd" 2>/dev/null
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  update-check-limited || true
  exit 0
fi
