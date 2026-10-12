#!/usr/bin/env bash
# links.sh — cross-repo worker for /customer-support links/deliver
# (T20261012-373882). Resolves and HTTP-verifies every partner download link
# for a released SBOM, by calling synxdb-build-pipeline's own
# render-partner-download-block.sh (never hand-builds a Cloudsmith URL — the
# cdn_url is not reconstructable from filename+format, per that script's own
# header comment).
#
# Token bridging (the exact gotcha documented in T20261012-373882's design):
# synxdb-build-pipeline's .env key is ENTITLEMENT_TOKEN
# (1Password-backed: op://SynxDB Build/Cloudsmith/entitlement_token), but
# render-partner-download-block.sh / partner-download-url.sh read a
# DIFFERENTLY-named var, SYNX_PARTNER_TOKEN. This script bridges that
# explicitly — never pass the token as a CLI argument (same rule as the two
# scripts it wraps; enforced below too).
#
# Usage:
#   links.sh <released-sbom-path> <entitlement-label> [--clone-dir <path>]
#
# Cloning: by default, clones synxdb-build-pipeline fresh into an ephemeral
# path (same ephemeral-clone pattern as /drive Phase 1.5 — never reuse an
# existing local clone, which may be another live session's working tree).
# Pass --clone-dir <path> to reuse an already-checked-out clone instead (the
# session's own hub clone, or a test fixture) — the caller owns that path's
# lifecycle, this script never deletes a clone it didn't create itself.
#
# Env:
#   SYNXDB_BUILD_PIPELINE_REPO   git remote to clone (default:
#                                git@github.com:Synx-Data-Labs/synxdb-build-pipeline.git)
#   ENTITLEMENT_TOKEN            if already exported, used directly; else
#                                read from the clone's .env
set -euo pipefail

CS_LINKS_REPO="${SYNXDB_BUILD_PIPELINE_REPO:-git@github.com:Synx-Data-Labs/synxdb-build-pipeline.git}"

# cs-links-reject-token-arg <args...> — refuse any --token* flag, mirroring
# render-partner-download-block.sh / partner-download-url.sh's own guard.
cs-links-reject-token-arg() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == --token* ]]; then
      echo "error: the token is never a CLI argument — set ENTITLEMENT_TOKEN or have it in the clone's .env" >&2
      return 1
    fi
  done
  return 0
}

# cs-links-resolve-token <env-file> — prints ENTITLEMENT_TOKEN's value from
# the given .env file (simple KEY=VALUE line match; no shell-sourcing of an
# untrusted .env). Exported ENTITLEMENT_TOKEN (if already set) always wins
# and this function is not consulted in that case (see cs-links-render).
cs-links-resolve-token() {
  local env_file="${1:?env file path required}" line
  if [[ ! -f "$env_file" ]]; then
    echo "error: no .env at ${env_file} and ENTITLEMENT_TOKEN is not already set" >&2
    return 1
  fi
  line=$(grep -E '^ENTITLEMENT_TOKEN=' "$env_file" | tail -1 || true)
  if [[ -z "$line" ]]; then
    echo "error: ENTITLEMENT_TOKEN not found in ${env_file}" >&2
    return 1
  fi
  printf '%s\n' "${line#ENTITLEMENT_TOKEN=}"
}

# cs-links-render <clone-dir> <sbom> <label> — bridges the token and calls
# the real render script. Exits non-zero if any resolved URL fails to
# verify (render-partner-download-block.sh's own overall_rc) — THIS is the
# gate deliver_gate.sh's release path relies on.
cs-links-render() {
  local clone="${1:?clone dir required}" sbom="${2:?sbom path required}" label="${3:?entitlement label required}"
  local render_script="${clone}/scripts/release/render-partner-download-block.sh"
  if [[ ! -f "$render_script" ]]; then
    echo "error: ${render_script} not found — is ${clone} a synxdb-build-pipeline checkout?" >&2
    return 1
  fi
  local token="${ENTITLEMENT_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token=$(cs-links-resolve-token "${clone}/.env")
  fi
  SYNX_PARTNER_TOKEN="$token" bash "$render_script" "$sbom" "$label"
}

cs-links-main() {
  cs-links-reject-token-arg "$@"

  local clone_dir="" sbom="" label="" args=() a
  args=("$@")
  local i=0 n="${#args[@]}"
  local positional=()
  while [[ $i -lt $n ]]; do
    a="${args[$i]}"
    if [[ "$a" == "--clone-dir" ]]; then
      i=$((i + 1))
      clone_dir="${args[$i]:-}"
    else
      positional+=("$a")
    fi
    i=$((i + 1))
  done

  if [[ "${#positional[@]}" -ne 2 ]]; then
    echo "usage: links.sh <released-sbom-path> <entitlement-label> [--clone-dir <path>]" >&2
    return 2
  fi
  sbom="${positional[0]}"
  label="${positional[1]}"

  local created=0 cleanup_dir=""
  if [[ -z "$clone_dir" ]]; then
    clone_dir="$(mktemp -d "${TMPDIR:-/tmp}/customer-support-links.XXXXXX")"
    cleanup_dir="$clone_dir"
    created=1
    git clone --depth=1 "$CS_LINKS_REPO" "$clone_dir" >&2
  fi

  local rc=0
  cs-links-render "$clone_dir" "$sbom" "$label" || rc=$?

  if [[ "$created" -eq 1 ]]; then
    rm -rf "$cleanup_dir"
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-links-main "$@"
fi
