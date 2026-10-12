#!/usr/bin/env bash
# deliver_gate.sh — evidence gate for /customer-support deliver
# (T20261012-373882). "in-progress -> delivered" must never be a
# self-report: this is the regression test for the real failure this design
# documents (synxdb-support#21 — an engineer marked a package delivered when
# the publish step had actually failed silently).
#
# Two paths:
#   generic   — reachability-check whatever was shared (curl -I, expect
#               200/301/302 like render-partner-download-block.sh's own
#               verifier).
#   release   — delegate entirely to links.sh (which itself verifies every
#               resolved URL); a non-zero exit blocks the transition.
#
# curl wrapper — DI seam via CS_CURL (tests inject a stub here), same
# convention as labels.sh's CS_GH.
set -euo pipefail

CS_CURL="${CS_CURL:-curl}"

# cs-deliver-check-url <url> — exit 0 if it verifies (200/301/302).
cs-deliver-check-url() {
  local url="${1:?url required}" code
  code=$("$CS_CURL" -s -o /dev/null -w '%{http_code}' --max-time 20 -I "$url" 2>/dev/null) || code="000"
  case "$code" in
    200|301|302) return 0 ;;
    *)
      echo "error: ${url} returned HTTP ${code} (expected 200/301/302) — not verified, refusing to mark delivered" >&2
      return 1
      ;;
  esac
}

# cs-deliver-check-urls <url>... — ALL must verify (not self-report-able:
# every URL shared with the customer must actually be reachable).
cs-deliver-check-urls() {
  if [[ "$#" -eq 0 ]]; then
    echo "error: no URL(s) to verify — a generic delivery needs at least one reachable URL as evidence" >&2
    return 1
  fi
  local url rc=0
  for url in "$@"; do
    cs-deliver-check-url "$url" || rc=1
  done
  return "$rc"
}

# cs-deliver-release-gate <links.sh-path> <links.sh-args...> — release-type
# delivery: entirely delegates to links.sh, whose own render step verifies
# every resolved artifact URL. A non-zero exit here IS the gate blocking the
# in-progress -> delivered transition.
cs-deliver-release-gate() {
  local links_script="${1:?path to links.sh required}"
  shift
  bash "$links_script" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    check-urls) cs-deliver-check-urls "$@" ;;
    release-gate) cs-deliver-release-gate "$@" ;;
    *)
      echo "usage: deliver_gate.sh <check-urls <url>...|release-gate <links.sh-path> ...>" >&2
      exit 2
      ;;
  esac
fi
