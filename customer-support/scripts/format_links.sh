#!/usr/bin/env bash
# format_links.sh — turn render-partner-download-block.sh output into a
# GitHub-comment body whose download URLs actually linkify (T20261021-332125).
#
# The render script wraps its list in a ``` fence (good for logs, bad for a
# comment: GitHub does not linkify inside a fence). This formatter, skill-side
# only, drops the fence + the ==== / ---- rules + the in-fence title, turns
# each TYPE into "### TYPE", and each package into
#   - **component** (`artifact`): <bare URL>
# It refuses (non-zero, nothing on stdout) unless the URL multiset is
# byte-identical before/after, no fence survives, and at least one URL exists.
#
# Token hygiene: stdin -> stdout only; never an argument. Error messages print
# counts, never URLs (they carry the entitlement token).
#
# Usage:
#   render... | format_links.sh [format]    # Markdown to stdout
#   body...   | format_links.sh check       # exit 1 if a fence is present
set -euo pipefail

# cs-fmt-urls — one URL per line, sorted (multiset form), from stdin.
cs-fmt-urls() {
  { grep -oE 'https?://[^[:space:]]+' || true; } | LC_ALL=C sort
}

# cs-fmt-assert-urls <raw-urls> <formatted-urls> — multiset equality.
cs-fmt-assert-urls() {
  if [[ "${1-}" != "${2-}" ]]; then
    echo "error: URL mismatch between render output and formatted body — refusing to post (nothing printed to avoid leaking the token)" >&2
    return 1
  fi
}

# cs-fmt-assert-no-fence — stdin body must contain no ``` fence line.
cs-fmt-assert-no-fence() {
  if grep -qE '^[[:space:]]*```' ; then
    echo "error: formatted body still contains a code fence — GitHub would not linkify the URLs; refusing to post" >&2
    return 1
  fi
}

# cs-fmt-markdown — stdin render output -> Markdown (no validation).
cs-fmt-markdown() {
  local line pending_c="" pending_a="" in_fence=0 seen_title=0 raw
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
      in_fence=$((1 - in_fence)); seen_title=0; continue
    fi
    if [[ "$in_fence" -eq 0 ]]; then
      printf '%s\n' "$line"; continue
    fi
    # inside the old fence
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "$seen_title" -eq 0 ]]; then seen_title=1; continue; fi
    [[ "$line" =~ ^=+$ || "$line" =~ ^-+$ ]] && continue
    if [[ "$line" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      printf '\n### %s\n\n' "$line"; continue
    fi
    if [[ "$line" =~ ^[[:space:]]+https?://[^[:space:]]+$ ]]; then
      local url="${line#"${line%%[![:space:]]*}"}"
      if [[ -n "$pending_c" ]]; then
        printf '%s\n' "- **${pending_c}** (\`${pending_a}\`): ${url}"
      else
        printf '%s\n' "- ${url}"
      fi
      pending_c=""; pending_a=""; continue
    fi
    if [[ "$line" =~ ^[[:space:]]*⚠ ]]; then
      printf '%s\n' "- ${line#"${line%%[![:space:]]*}"}"; continue
    fi
    if [[ "$line" =~ ^(.+)\ \(([^()]*)\):$ ]]; then
      pending_c="${BASH_REMATCH[1]}"; pending_a="${BASH_REMATCH[2]}"; continue
    fi
    printf '%s\n' "- ${line}"
  done
}

# cs-fmt-main — stdin -> validated Markdown on stdout.
cs-fmt-main() {
  local raw out
  raw="$(cat)"
  local raw_urls
  raw_urls="$(printf '%s\n' "$raw" | cs-fmt-urls)"
  if [[ -z "$raw_urls" ]]; then
    echo "error: no download URLs in the render output — nothing to post" >&2
    return 1
  fi
  out="$(printf '%s\n' "$raw" | cs-fmt-markdown)"
  cs-fmt-assert-urls "$raw_urls" "$(printf '%s\n' "$out" | cs-fmt-urls)" || return 1
  printf '%s\n' "$out" | cs-fmt-assert-no-fence || return 1
  printf '%s\n' "$out"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-format}"
  [[ "$#" -gt 0 ]] && shift
  for a in "$@"; do
    if [[ "$a" == --token* ]]; then
      echo "error: the token is never a CLI argument" >&2; exit 1
    fi
  done
  case "$cmd" in
    format) cs-fmt-main ;;
    check) cs-fmt-assert-no-fence ;;
    *) echo "usage: format_links.sh [format|check]  (stdin -> stdout)" >&2; exit 2 ;;
  esac
fi
