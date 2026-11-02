#!/usr/bin/env bash
# repo.sh — entrypoint for the /repo skill (T20261031-139856).
#
#   repo.sh scan [path] [--depth N] [--all] [--roots a:b]
#   repo.sh list [--json] [--fresh]
#   repo.sh switch <name>
#
# Thin dispatcher over the registry lib `_repos/repos.sh`; the skill calls this
# so its prose never has to know the lib layout. Read-only toward every repo it
# looks at: it never cd's, checks out, fetches or claims anything.
#
# Sourceable: defines functions only; the CLI runs under the guard below.

function repo-skill-main() {
  local here
  here="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=/dev/null
  source "$here/../../_repos/repos.sh"
  local verb="${1:-list}"
  [ $# -gt 0 ] && shift
  case "$verb" in
    scan|list|switch) repos-main "$verb" "$@" ;;
    *) printf 'repo: unknown verb %s (switch <name> | scan [path] | list)\n' "$verb" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  repo-skill-main "$@"
fi
