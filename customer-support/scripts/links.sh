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
#   links.sh <released-sbom-path> <entitlement-label> [--clone-dir <path>] [--raw]
#
# Output: by default the render output is reformatted into Markdown (headings
# + one bullet per package, bare URLs) via format_links.sh so the posted
# comment's URLs linkify — a fenced block is NOT linkified by GitHub
# (T20261021-332125). `--raw` keeps the render script's output byte-for-byte
# (for logs). The render exit code (the verification gate) is preserved.
#
# Cloning: by default, clones synxdb-build-pipeline fresh into an ephemeral
# path (same ephemeral-clone pattern as /drive Phase 1.5 — never reuse an
# existing local clone, which may be another live session's working tree).
# Pass --clone-dir <path> to reuse an already-checked-out clone instead (the
# session's own hub clone, or a test fixture) — the caller owns that path's
# lifecycle, this script never deletes a clone it didn't create itself.
#
# Token source in each path (found by independent review of ccxp-skills#346
# — the .env fallback below is NOT reachable from the default ephemeral-
# clone path, since synxdb-build-pipeline's .env is gitignored and only
# populated locally via `1password-env-setup`/`op inject`; a bare
# `git clone` never has one):
#   - Default (ephemeral clone, no --clone-dir): the CALLER must already
#     have ENTITLEMENT_TOKEN exported (the normal case for an engineer or
#     agent session already working in this suite, where the hub repo's own
#     1Password-backed .env is typically already loaded). This script does
#     NOT read any .env in this path.
#   - --clone-dir pointing at an existing, already-populated checkout: the
#     .env fallback applies there, and ENTITLEMENT_TOKEN is read from that
#     checkout's .env if not already exported.
# Either way, an already-exported ENTITLEMENT_TOKEN always wins.
#
# Env:
#   SYNXDB_BUILD_PIPELINE_REPO   git remote to clone (default:
#                                git@github.com:Synx-Data-Labs/synxdb-build-pipeline.git)
#   ENTITLEMENT_TOKEN            if already exported, used directly; else
#                                read from the clone's .env
set -euo pipefail

CS_LINKS_REPO="${SYNXDB_BUILD_PIPELINE_REPO:-git@github.com:Synx-Data-Labs/synxdb-build-pipeline.git}"
CS_LINKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "error: no ENTITLEMENT_TOKEN in the environment, and no .env at ${env_file} — a freshly-cloned checkout never has a populated .env (it's gitignored). Export ENTITLEMENT_TOKEN yourself before calling links.sh, or pass --clone-dir pointing at an existing checkout whose .env IS populated." >&2
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

# cs-links-render-md <clone-dir> <sbom> <label> — cs-links-render, then the
# Markdown formatter. Returns the render's exit code; if the render passed
# but formatting was refused (URL mismatch / no URLs / fence), returns 1 with
# nothing on stdout. Output is buffered in a variable, never a temp file.
cs-links-render-md() {
  local raw rc=0
  raw="$(cs-links-render "$@")" || rc=$?
  local md
  if ! md="$(printf '%s\n' "$raw" | bash "${CS_LINKS_DIR}/format_links.sh" format)"; then
    return $(( rc != 0 ? rc : 1 ))
  fi
  printf '%s\n' "$md"
  return "$rc"
}

cs-links-main() {
  cs-links-reject-token-arg "$@"

  local clone_dir="" sbom="" label="" args=() a raw_out=0
  args=("$@")
  local i=0 n="${#args[@]}"
  local positional=()
  while [[ $i -lt $n ]]; do
    a="${args[$i]}"
    if [[ "$a" == "--clone-dir" ]]; then
      i=$((i + 1))
      clone_dir="${args[$i]:-}"
    elif [[ "$a" == "--raw" ]]; then
      raw_out=1
    else
      positional+=("$a")
    fi
    i=$((i + 1))
  done

  if [[ "${#positional[@]}" -ne 2 ]]; then
    echo "usage: links.sh <released-sbom-path> <entitlement-label> [--clone-dir <path>] [--raw]" >&2
    return 2
  fi
  sbom="${positional[0]}"
  label="${positional[1]}"

  local created=0 cleanup_dir=""
  if [[ -z "$clone_dir" ]]; then
    # Fail fast, BEFORE the network clone: a fresh ephemeral clone can never
    # have a populated .env (gitignored), so without --clone-dir the caller
    # must already have ENTITLEMENT_TOKEN exported. Checking this up front
    # avoids a slow clone only to fail on the token afterward.
    if [[ -z "${ENTITLEMENT_TOKEN:-}" ]]; then
      echo "error: ENTITLEMENT_TOKEN is not set. Without --clone-dir, links.sh clones synxdb-build-pipeline fresh — a fresh clone never has a populated .env (gitignored) — so the caller must export ENTITLEMENT_TOKEN itself first, or pass --clone-dir pointing at an existing checkout with a populated .env." >&2
      return 1
    fi
    clone_dir="$(mktemp -d "${TMPDIR:-/tmp}/customer-support-links.XXXXXX")"
    cleanup_dir="$clone_dir"
    created=1
    git clone --depth=1 "$CS_LINKS_REPO" "$clone_dir" >&2
  fi

  local rc=0
  if [[ "$raw_out" -eq 1 ]]; then
    cs-links-render "$clone_dir" "$sbom" "$label" || rc=$?
  else
    cs-links-render-md "$clone_dir" "$sbom" "$label" || rc=$?
  fi

  if [[ "$created" -eq 1 ]]; then
    rm -rf "$cleanup_dir"
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cs-links-main "$@"
fi
