#!/usr/bin/env bash
# update.sh [--check|--dry-run|-n] [--claude-dir DIR]
#
# Update the installed ccxp-skills plugin from the public repo, then refresh the
# ccxp-agent definition using the NEWLY installed version's agent-pairing.sh
# (never this script's own copy, which belongs to the old version).
#
#   1. claude plugin marketplace update ccxp-skills
#   2. claude plugin update ccxp-skills@ccxp-skills
#   3. <newest cache dir>/agent-pairing/scripts/agent-pairing.sh update
#
# Fails loudly and never half-updates: if step 1 or 2 fails, step 3 is skipped
# and the resulting state is printed. --check/--dry-run writes nothing.
set -euo pipefail

PLUGIN_ID="ccxp-skills@ccxp-skills"
MARKETPLACE="ccxp-skills"
REPO="Synx-Data-Labs/ccxp-skills"
REPO_URL="https://github.com/$REPO.git"
TAG_PREFIX="ccxp-skills--v"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

function usage() {
  echo "usage: update.sh [--check|--dry-run|-n] [--claude-dir DIR]" >&2
}

function die() { echo "update: ERROR: $*" >&2; exit 1; }

# ver_gt A B -> success when semver A > B (numeric per component).
function ver_gt() {
  local a b i
  IFS=. read -r -a a <<<"$1"; IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if (( 10#${a[$i]:-0} > 10#${b[$i]:-0} )); then return 0; fi
    if (( 10#${a[$i]:-0} < 10#${b[$i]:-0} )); then return 1; fi
  done
  return 1
}

# newest_semver: reads versions on stdin, prints the highest valid x.y.z.
function newest_semver() {
  local v best=""
  while IFS= read -r v; do
    [[ "$v" =~ $SEMVER_RE ]] || continue
    if [ -z "$best" ] || ver_gt "$v" "$best"; then best="$v"; fi
  done
  printf '%s' "$best"
}

# latest_version: newest ccxp-skills--v* tag of the public repo.
function latest_version() {
  local v=""
  if command -v git >/dev/null 2>&1; then
    v="$(git ls-remote --tags "$REPO_URL" 2>/dev/null \
      | sed -n "s|.*refs/tags/${TAG_PREFIX}\([0-9][0-9.]*\)\$|\1|p" | newest_semver)" || v=""
  fi
  if [ -z "$v" ] && command -v gh >/dev/null 2>&1; then
    v="$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null \
      | sed -n "s|^${TAG_PREFIX}||p" | newest_semver)" || v=""
  fi
  printf '%s' "$v"
}

# installed_version: version of PLUGIN_ID per `claude plugin list --json`.
function installed_version() {
  claude plugin list --json 2>/dev/null \
    | jq -r --arg id "$PLUGIN_ID" '[.[] | select(.id==$id)][0].version // empty' 2>/dev/null || true
}

# newest_cache_dir: highest x.y.z dir under the profile's ccxp-skills cache.
function newest_cache_dir() {
  local root="$CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills" d v
  [ -d "$root" ] || return 0
  v="$(for d in "$root"/*; do [ -d "$d" ] && basename "$d"; done | newest_semver)"
  [ -n "$v" ] && printf '%s' "$root/$v"
  return 0
}

function main() {
  local check=0
  CLAUDE_DIR="${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --check|--dry-run|-n) check=1; shift ;;
      --claude-dir) CLAUDE_DIR="${2:?--claude-dir requires a value}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v claude >/dev/null 2>&1 || die "'claude' CLI not found on PATH; run 'claude plugin update $PLUGIN_ID' from a terminal, then '/agent-pairing update'"
  [ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR is not a directory"
  export CLAUDE_CONFIG_DIR="$CLAUDE_DIR"

  local before latest
  before="$(installed_version)"
  [ -n "$before" ] || die "$PLUGIN_ID is not installed in $CLAUDE_DIR (or 'claude plugin list --json' failed); nothing changed"
  latest="$(latest_version)"
  [ -n "$latest" ] || die "could not determine the latest version from $REPO (git ls-remote and gh both failed); nothing changed"

  echo "update: profile          $CLAUDE_DIR"
  echo "update: installed        $before"
  echo "update: latest available $latest"
  echo "update: release notes    https://github.com/$REPO/releases/tag/${TAG_PREFIX}${latest}"

  local newer=0
  if ver_gt "$latest" "$before"; then newer=1; echo "update: a newer version is available"; else echo "update: plugin is already at the latest version"; fi

  if [ "$check" = 1 ]; then
    echo "update: --check: writing nothing. A real run would:"
    if [ "$newer" = 1 ]; then
      echo "  - refresh the marketplace clone and install $latest under $CLAUDE_DIR/plugins/ (cache dir + installed_plugins.json)"
    fi
    echo "  - run the installed agent-pairing.sh 'update': refresh $CLAUDE_DIR/agents/ccxp-agent.md (timestamped .bak- kept)"
    echo "  - never change the agent on/off state in settings.json"
    local cur
    cur="$(newest_cache_dir)"
    if [ -n "$cur" ] && [ -f "$cur/agent-pairing/scripts/agent-pairing.sh" ]; then
      echo "update: agent definition preview against the currently installed ${cur##*/} (the $latest copy is only available after the plugin update):"
      bash "$cur/agent-pairing/scripts/agent-pairing.sh" update --dry-run --claude-dir "$CLAUDE_DIR" || echo "update: (agent preview failed; see above)"
    fi
    return 0
  fi

  echo "update: WILL CHANGE under $CLAUDE_DIR: plugins/known_marketplaces.json + the marketplace clone, plugins/cache/ccxp-skills/ (new version dir), plugins/installed_plugins.json, and agents/ccxp-agent.md (old copy saved as ccxp-agent.md.bak-<timestamp>). settings.json agent on/off is not touched."
  echo "update: WARNING: check for running background jobs/subagents first (/agent-pairing status, ListAgents); a restart afterwards ends them."

  if [ "$newer" = 1 ]; then
    if ! claude plugin marketplace update "$MARKETPLACE"; then
      echo "update: FAILED at 'claude plugin marketplace update $MARKETPLACE'. State: plugin still $before, agent definition NOT refreshed, nothing else changed." >&2
      exit 1
    fi
    if ! claude plugin update "$PLUGIN_ID"; then
      echo "update: FAILED at 'claude plugin update $PLUGIN_ID'. State: marketplace refreshed, plugin still $before (or unchanged), agent definition NOT refreshed." >&2
      exit 1
    fi
  fi

  local after
  after="$(installed_version)"
  [ -n "$after" ] || die "plugin no longer listed after update; agent definition NOT refreshed. Check 'claude plugin list'"
  if [ "$newer" = 1 ] && ! ver_gt "$after" "$before"; then
    echo "update: FAILED: plugin still reports $after after update (latest is $latest). Agent definition NOT refreshed. Try 'claude plugin marketplace update $MARKETPLACE' manually." >&2
    exit 1
  fi

  local dir
  dir="$(newest_cache_dir)"
  if [ -z "$dir" ] || [ ! -f "$dir/agent-pairing/scripts/agent-pairing.sh" ]; then
    echo "update: FAILED: plugin updated to $after but no agent-pairing.sh found under $CLAUDE_DIR/plugins/cache/ccxp-skills/ccxp-skills/. Agent definition NOT refreshed." >&2
    exit 1
  fi
  echo "update: refreshing the agent definition with ${dir##*/}'s agent-pairing.sh"
  if ! bash "$dir/agent-pairing/scripts/agent-pairing.sh" update --claude-dir "$CLAUDE_DIR"; then
    echo "update: FAILED: plugin is now $after but the agent refresh failed; run '/agent-pairing update' after fixing the error above." >&2
    exit 1
  fi

  echo "update: DONE. plugin $before -> $after (latest $latest). Release notes: https://github.com/$REPO/releases/tag/${TAG_PREFIX}${latest}"
  echo "update: MANUAL steps: (1) run /reload-plugins; (2) restart Claude Code for the refreshed agent persona to apply (a restart ends running background jobs)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
