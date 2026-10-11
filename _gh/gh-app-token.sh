#!/usr/bin/env bash
# _gh/gh-app-token.sh — mint a short-lived GitHub App installation token.
#
# Prints the token (and nothing else) on stdout, so a caller can do:
#   GH_TOKEN="$(bash _gh/gh-app-token.sh --repo OWNER/REPO)" gh pr view 123
#
# Use when a workflow needs a GitHub identity distinct from the human `gh`
# account (e.g. a bot that approves a PR or arms auto-merge). The token is
# scoped to the one repo and expires in about an hour.
#
# Usage:
#   gh-app-token.sh [--app-id ID] [--key-file PATH] [--repo OWNER/REPO]
#
# Inputs (flag wins, else env):
#   --app-id    / GH_APP_ID                 the App's numeric ID (or client ID)
#   --key-file  / GH_APP_PRIVATE_KEY_FILE   path to the App's PEM private key
#                 GH_APP_PRIVATE_KEY        PEM contents (alternative to a file)
#   --repo      / GH_APP_REPO               target repo, OWNER/REPO
#
# The credential source is the caller's choice (env vars, a secret-manager
# CLI, ...); this script names no provider and stores nothing.
#
# Flow: sign an RS256 JWT with the private key -> look up the repo's
# installation -> exchange it for an installation token limited to that repo.
#
# Exit: 0 and the token on stdout; non-zero and a message on stderr (stdout
# empty) on missing input, missing tool, API error, or a token-less response.
#
# Test seams (env): GH_APP_TOKEN_CURL, GH_APP_TOKEN_OPENSSL (default curl /
# openssl), GH_APP_TOKEN_API (default https://api.github.com),
# GH_APP_TOKEN_NOW (epoch seconds override).
#
# Sourceable: defines functions only; the CLI runs under the guard below.

set -euo pipefail

gh_app_token_die() { printf 'gh-app-token: %s\n' "$1" >&2; return 1; }

# stdin -> base64url without padding
gh_app_token_b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

# gh_app_token_jwt <app-id> <key-file> — print a signed RS256 JWT
function gh_app_token_jwt() {
  local app_id="$1" key_file="$2"
  local openssl="${GH_APP_TOKEN_OPENSSL:-openssl}"
  local now header claims unsigned sig
  now="${GH_APP_TOKEN_NOW:-$(date +%s)}"
  header='{"alg":"RS256","typ":"JWT"}'
  # iat backdated 60s for clock skew; exp stays under GitHub's 10 min cap
  claims="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id")"
  unsigned="$(printf '%s' "$header" | gh_app_token_b64url).$(printf '%s' "$claims" | gh_app_token_b64url)"
  sig="$(printf '%s' "$unsigned" | "$openssl" dgst -sha256 -sign "$key_file" | gh_app_token_b64url)" \
    || { gh_app_token_die "JWT signing failed (bad private key?)"; return 1; }
  [[ -n "$sig" ]] || { gh_app_token_die "JWT signing produced no signature"; return 1; }
  printf '%s.%s' "$unsigned" "$sig"
}

# gh_app_token_api <GET|POST> <path> <jwt> [json-body] — print response body;
# non-zero (message on stderr) on a non-2xx status.
function gh_app_token_api() {
  local method="$1" path="$2" jwt="$3" body="${4:-}"
  local curl="${GH_APP_TOKEN_CURL:-curl}" api="${GH_APP_TOKEN_API:-https://api.github.com}"
  local args=(-sS -X "$method" -w '\n%{http_code}'
    -H "Authorization: Bearer $jwt"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28")
  [[ -n "$body" ]] && args+=(-d "$body")
  local out code
  out="$("$curl" "${args[@]}" "$api$path")" || { gh_app_token_die "request failed: $method $path"; return 1; }
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    gh_app_token_die "$method $path -> HTTP $code: $(printf '%s' "$out" | jq -r '.message // empty' 2>/dev/null)"
    return 1
  fi
  printf '%s' "$out"
}

# gh_app_token_mint <app-id> <key-file> <owner/repo> — print the token
function gh_app_token_mint() {
  local app_id="$1" key_file="$2" repo="$3"
  local jwt inst_id token
  jwt="$(gh_app_token_jwt "$app_id" "$key_file")" || return 1
  inst_id="$(gh_app_token_api GET "/repos/$repo/installation" "$jwt" | jq -r '.id // empty')" || return 1
  [[ -n "$inst_id" ]] || { gh_app_token_die "no installation found for $repo"; return 1; }
  token="$(gh_app_token_api POST "/app/installations/$inst_id/access_tokens" "$jwt" \
    "$(jq -nc --arg r "${repo#*/}" '{repositories: [$r]}')" | jq -r '.token // empty')" || return 1
  [[ -n "$token" ]] || { gh_app_token_die "response contained no token"; return 1; }
  printf '%s\n' "$token"
}

function gh_app_token_main() {
  local app_id="${GH_APP_ID:-}" key_file="${GH_APP_PRIVATE_KEY_FILE:-}" repo="${GH_APP_REPO:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app-id)   app_id="${2:-}"; shift 2 ;;
      --key-file) key_file="${2:-}"; shift 2 ;;
      --repo)     repo="${2:-}"; shift 2 ;;
      -h|--help)  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)          gh_app_token_die "unknown argument: $1"; return 1 ;;
    esac
  done

  [[ -n "$app_id" ]] || { gh_app_token_die "missing app id (--app-id or GH_APP_ID)"; return 1; }
  [[ "$repo" == */* ]] || { gh_app_token_die "missing or malformed repo, want OWNER/REPO (--repo or GH_APP_REPO)"; return 1; }
  local tool
  for tool in "${GH_APP_TOKEN_OPENSSL:-openssl}" "${GH_APP_TOKEN_CURL:-curl}" jq base64; do
    command -v "$tool" >/dev/null 2>&1 || { gh_app_token_die "required tool not found: $tool"; return 1; }
  done

  local tmp=""
  if [[ -z "$key_file" ]]; then
    [[ -n "${GH_APP_PRIVATE_KEY:-}" ]] || { gh_app_token_die "missing private key (--key-file, GH_APP_PRIVATE_KEY_FILE, or GH_APP_PRIVATE_KEY)"; return 1; }
    tmp="$(mktemp)"
    # shellcheck disable=SC2064  # expand now: $tmp is function-local, gone when EXIT fires
    trap "rm -f '$tmp'" EXIT
    chmod 600 "$tmp"
    printf '%s\n' "$GH_APP_PRIVATE_KEY" >"$tmp"
    key_file="$tmp"
  fi
  [[ -r "$key_file" ]] || { gh_app_token_die "private key file not readable: $key_file"; return 1; }

  gh_app_token_mint "$app_id" "$key_file" "$repo"
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  gh_app_token_main "$@"
fi
