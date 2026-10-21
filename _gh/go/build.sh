#!/usr/bin/env bash
# _gh/go/build.sh — build the opt-in Go counterpart of _gh/gh.sh / _gh/git.sh
# into _gh/bin/ccxp-gh (gitignored). Manual in stage 1 (T20261020-231370);
# the wrappers use it only when CCXP_GH_GO=1.
#
# Usage: bash _gh/go/build.sh [output-path]
set -euo pipefail

function build-ccxp-gh() {
  local here out
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  out="${1:-$here/../bin/ccxp-gh}"
  mkdir -p "$(dirname "$out")"
  (cd "$here" && go build -o "$out" .)
  printf '%s\n' "$out"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  build-ccxp-gh "$@"
fi
