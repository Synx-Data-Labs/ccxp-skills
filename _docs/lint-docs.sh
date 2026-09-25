#!/usr/bin/env bash
#
# lint-docs.sh — local markdownlint guard for repo docs (T20260626-117003).
#
# Catches Markdown render-bug violations (chiefly MD032 blanks-around-lists) in
# dev/JOURNAL + dev/TODO docs *before* a push reaches `main`, instead of after —
# a repo's own CI Markdown Lint workflow only gates post-push, so a malformed
# standup / retro / IPM doc reds main until a fix-PR lands.
#
# Moved here from build-pipeline-repo's scripts/ (T20260719-111051): the
# script's own logic never hardcoded a repo name — it always operated on
# whatever `dev/JOURNAL`/`dev/TODO` (or explicit path args) it was pointed at —
# but living inside one repo's scripts/ tree made it "resident" there: callers
# elsewhere (ccxp, gcpr) had to guard every invocation with
# `[ -f scripts/lint-docs.sh ]` and silently no-op when absent. Living here
# instead, any repo's IPM/PR flow gets the real guard, not just a safe skip.
#
# Design (T20260626-117003):
#   * Single ruleset — reuses the target repo's .markdownlint-cli2.jsonc, if
#     present (no drift vs its CI). Falls back to markdownlint-cli2's own
#     defaults when the target repo has no such config.
#   * Runner-preferring: an installed `markdownlint-cli2`, else `npx --yes
#     markdownlint-cli2@<pinned>` (exact CI parity). Both exit 0 (clean) / 1
#     (violations) — authoritative. With NO explicit path args, a repo config's
#     FULL config-glob doc set (dev/**/*.md + *.md) is linted — i.e. exactly
#     what its CI lints — for the default-scope pre-commit-guard use case.
#     With EXPLICIT path args (T20260910-919422), `--no-globs` is added so
#     those paths are the SOLE file selector — the config's own `globs` no
#     longer apply, and only the exact given file(s) are ever touched.
#   * Vendored MD032 floor: a dependency-free awk check that runs when no runner
#     can execute (truly offline / no node), so the guard never silently passes a
#     malformed doc. Scoped to MD032 — the entire recurring failure class — over
#     the given paths (default dev/JOURNAL + dev/TODO, the high-risk standup docs).
#
# Coverage model: runner present (normal) => full-tree CI parity; runner absent
# (offline) => vendored MD032 floor over the scoped paths. LINT_DOCS_FORCE_VENDORED=1
# forces the floor (test seam / distrust-npx override).
#
# Usage:
#   bash lint-docs.sh [--fix] [path ...]   # no paths => dev/JOURNAL dev/TODO (vendored scope)
#   source lint-docs.sh                     # then call lint_docs_run / _lint_docs_md032
#
# Options:
#   --fix      auto-correct via `markdownlint-cli2 --fix` when a runner is active.
#              Vendored mode is check-only (a pure-bash MD032 rewriter risks
#              mangling nested lists / fences) — logs and reports without fixing.
#
# Exit codes: 0 = clean; 1 = violations found; 2 = usage / bad input.

set -euo pipefail

# Pinned default so local + CI agree when the target repo doesn't pin its own
# runner version. A repo with its own CI pin should keep node_modules /
# package.json in sync separately — this is just the fallback.
_LINT_DOCS_MDL_VERSION="0.22.1"
# Default scope: the standup/journal/task docs that have caused the reds.
_LINT_DOCS_DEFAULT_PATHS=("dev/JOURNAL" "dev/TODO")

_lint_docs_usage() {
  cat >&2 <<'EOF'
Usage: lint-docs.sh [--fix] [path ...]
  No paths        lint the default scope (dev/JOURNAL dev/TODO)
  --fix           auto-fix via markdownlint-cli2 when a runner is available
Exit: 0 clean, 1 violations, 2 usage/bad input
EOF
}

# Resolve a markdownlint-cli2 runner. Echoes "markdownlint-cli2" | "npx" | "".
# LINT_DOCS_FORCE_VENDORED=1 forces the empty result (vendored floor) — a test
# seam and an operational override for environments that distrust npx-download.
_lint_docs_runner() {
  if [ "${LINT_DOCS_FORCE_VENDORED:-0}" = "1" ]; then
    printf ''
    return 0
  fi
  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    printf 'markdownlint-cli2'
  elif command -v npx >/dev/null 2>&1; then
    printf 'npx'
  else
    printf ''
  fi
}

# Vendored, dependency-free MD032 check over ONE file. Prints
# "<file>:<line>: MD032 ..." per violation. Returns 0 clean, 1 violations,
# 2 file-not-found. This is the BATS target — pure awk, no external runner.
#
# MD032 = "lists should be surrounded by blank lines". We flag the recurring
# class: a list block whose first item is glued to a preceding non-blank text
# line (the "colon-then-bullets" case), or whose last item is glued to a
# following un-indented text line. Fenced code and YAML frontmatter are skipped;
# indented continuation / sub-items stay part of the list block so they never
# false-positive.
_lint_docs_md032() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "ERROR: lint-docs: file not found: ${file}" >&2
    return 2
  fi
  awk -v F="$file" '
    BEGIN { v=0; in_fence=0; in_fm=0; in_list=0; prev_text=0 }

    # YAML frontmatter: only when --- is the very first line of the file.
    NR==1 && $0 ~ /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm==1 { if ($0 ~ /^---[[:space:]]*$/) in_fm=0; in_list=0; prev_text=0; next }

    # Fenced code: toggle on ``` or ~~~ ; a fence delimiter ends any open list
    # and counts as text for spacing. Skip everything inside the fence.
    $0 ~ /^[[:space:]]*(```|~~~)/ { in_list=0; prev_text=1; in_fence=!in_fence; next }
    in_fence==1 { in_list=0; prev_text=1; next }

    # Blank line: ends a list block; resets the "preceded by text" state.
    $0 ~ /^[[:space:]]*$/ { in_list=0; prev_text=0; next }

    {
      is_list = ($0 ~ /^[[:space:]]*[-*+][[:space:]]+/ || $0 ~ /^[[:space:]]*[0-9]+[.)][[:space:]]+/)
      is_indented = ($0 ~ /^[[:space:]]+/)

      if (is_list) {
        # before-case: a NEW list block (not already inside one) glued to text.
        if (in_list==0 && prev_text==1) {
          printf "%s:%d: MD032 list-item not preceded by a blank line\n", F, NR
          v++
        }
        in_list=1; prev_text=0
        next
      }

      # Non-list text line.
      if (is_indented==1 && in_list==1) {
        # Indented continuation / lazy text under a list item — part of the list.
        next
      }
      # after-case: un-indented text right after a list block, no blank between.
      if (in_list==1) {
        printf "%s:%d: MD032 list not followed by a blank line\n", F, NR
        v++
        in_list=0
      }
      prev_text=1
      next
    }

    END { exit (v>0 ? 1 : 0) }
  ' "$file"
}

# Vendored fallback over a set of paths (dirs are walked for *.md).
# Returns 0 clean, 1 if any file had violations.
_lint_docs_vendored() {
  local total=0 p f
  for p in "$@"; do
    if [ -d "$p" ]; then
      while IFS= read -r f; do
        _lint_docs_md032 "$f" || total=$((total + 1))
      done < <(find "$p" -type f -name '*.md' | sort)
    elif [ -f "$p" ]; then
      _lint_docs_md032 "$p" || total=$((total + 1))
    fi
  done
  if [ "$total" -gt 0 ]; then
    echo "lint-docs: MD032 violations in ${total} file(s) (vendored check)" >&2
    return 1
  fi
  return 0
}

# Rules disabled in the isolated safe-fix path (T20260922-383156): both
# recognize ambiguous prose as list/emphasis markup and silently rewrite it,
# changing meaning rather than just formatting —
#   MD004 (ul-style)          a hard-wrapped line starting with a bare "+"
#                              gets flipped to "-" (dash-style enforcement).
#   MD037 (no-space-in-emphasis)  a literal "*.ext" glob-pattern asterisk
#                              gets misread as an emphasis marker, and its
#                              adjacent comma-spacing gets stripped.
# Repo-wide/CI full-tree lint is untouched — this only applies to the
# isolated single-file copy the safe-fix path operates on.
_LINT_DOCS_SAFE_FIX_DISABLE_RULES=(MD004 MD037)

# Build an isolated temp-directory copy of the given path(s), with a config
# derived from the real discovered .markdownlint-cli2.jsonc (rules above
# forced off, everything else untouched), and run markdownlint-cli2 --fix
# there — so an ambiguous "+"/glob-asterisk prose line in the ONE file being
# fixed doesn't get silently corrupted (T20260922-383156). A naive --config
# override alone does NOT achieve this while the real config is discoverable
# in cwd: it's a per-rule cascade where a rule the real config explicitly
# sets (MD004) wins over --config regardless — hence the temp-directory
# isolation, not just a config flag.
#
# Returns 0 (clean) / 1 (violations, now fixed) on success, or 3 when the
# safe path can't be applied (no jq, or no .markdownlint-cli2.jsonc in cwd)
# — the caller falls back to the plain (pre-existing, non-isolated)
# invocation unchanged, never a hard failure.
_lint_docs_safe_fix() {
  local runner="$1" mdl_version="$2"
  shift 2
  local paths=("$@")

  if ! command -v jq >/dev/null 2>&1 || [ ! -f .markdownlint-cli2.jsonc ]; then
    return 3
  fi

  local tmpdir
  tmpdir="$(mktemp -d)" || return 3
  # shellcheck disable=SC2064  # intentional immediate expansion of $tmpdir
  trap "rm -rf '$tmpdir'" RETURN

  # Deliberately NOT named .markdownlint-cli2.jsonc: markdownlint-cli2 does
  # its own auto-discovery walk for that exact filename independent of
  # --config, and parses a discovery-found file under different structural
  # expectations than one supplied via --config — even the identical bare
  # rules content, under that reserved name, silently failed to suppress a
  # rule (MD037) that the same content DID suppress under any other name.
  # Empirically confirmed during this task's implementation; a name outside
  # markdownlint-cli2's own recognized-config-filename list sidesteps it.
  local override_config="$tmpdir/lint-docs-safe-fix-override.jsonc"
  local disable_filter='.config'
  local rule
  for rule in "${_LINT_DOCS_SAFE_FIX_DISABLE_RULES[@]}"; do
    disable_filter+=" | .${rule} = false"
  done
  jq "$disable_filter" .markdownlint-cli2.jsonc > "$override_config" 2>/dev/null \
    || return 3

  local p
  for p in "${paths[@]}"; do
    mkdir -p "$tmpdir/$(dirname "$p")" || return 3
    cp "$p" "$tmpdir/$p" || return 3
  done

  local cmd=()
  case "$runner" in
    markdownlint-cli2) cmd=(markdownlint-cli2) ;;
    npx)               cmd=(npx --yes "markdownlint-cli2@${mdl_version}") ;;
    *)                 return 3 ;;
  esac
  cmd+=(--config "$override_config" --fix --no-globs)

  local out rc
  out="$(cd "$tmpdir" && "${cmd[@]}" "${paths[@]}" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"

  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    return 3
  fi

  for p in "${paths[@]}"; do
    cp "$tmpdir/$p" "$p" || return 3
  done
  return "$rc"
}

# Run the real markdownlint-cli2 via the resolved runner. Echoes its output and
# returns 0 (clean) / 1 (violations) when it actually ran, or 3 when it could
# not run (e.g. npx offline) — the caller treats 3 as "fall back to vendored".
# With no explicit paths the tool uses .markdownlint-cli2.jsonc globs (full CI
# parity, unchanged); explicit paths get --no-globs (T20260910-919422) so the
# CLI path(s) become the SOLE file-selection mechanism instead of merging with
# the config's own globs (verified: a config's globs are otherwise additive,
# never narrowed by CLI args — and a globs-stripped temp-config override does
# NOT work either, since markdownlint-cli2 falls back to its own hardcoded
# **/*.md default with no top-level globs present at all).
#
# A scoped --fix call (fix=1 && explicit=1) tries the isolated safe-fix path
# first (T20260922-383156); a rc of 3 from that (no jq / no discoverable
# config) falls through to the plain invocation below, unchanged.
_lint_docs_run_tool() {
  local runner="$1" fix="$2" explicit="$3"
  shift 3

  if [ "$fix" -eq 1 ] && [ "$explicit" -eq 1 ]; then
    local safe_rc
    _lint_docs_safe_fix "$runner" "$_LINT_DOCS_MDL_VERSION" "$@"
    safe_rc=$?
    [ "$safe_rc" -ne 3 ] && return "$safe_rc"
  fi

  local cmd=()
  case "$runner" in
    markdownlint-cli2) cmd=(markdownlint-cli2) ;;
    npx)               cmd=(npx --yes "markdownlint-cli2@${_LINT_DOCS_MDL_VERSION}") ;;
    *)                 return 3 ;;
  esac
  [ "$fix" -eq 1 ] && cmd+=(--fix)
  [ "$explicit" -eq 1 ] && cmd+=(--no-globs)

  local out rc
  out="$("${cmd[@]}" "$@" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    return "$rc"
  fi
  return 3
}

# Public entry point.
lint_docs_run() {
  local fix=0 arg
  local paths=()
  for arg in "$@"; do
    case "$arg" in
      --fix)        fix=1 ;;
      -h|--help)    _lint_docs_usage; return 0 ;;
      --*)          echo "ERROR: lint-docs: unknown option: ${arg}" >&2; return 2 ;;
      *)            paths+=("$arg") ;;
    esac
  done
  # Explicit-path scoping (--no-globs) only applies when the CALLER gave a
  # path — the default-scope fallback below still wants full config-glob
  # coverage, so this must be captured before the default substitution.
  local explicit=1
  [ "${#paths[@]}" -eq 0 ] && { explicit=0; paths=("${_LINT_DOCS_DEFAULT_PATHS[@]}"); }

  local runner
  runner="$(_lint_docs_runner)"
  if [ -n "$runner" ]; then
    local rc=0
    _lint_docs_run_tool "$runner" "$fix" "$explicit" "${paths[@]}" || rc=$?
    if [ "$rc" -le 1 ]; then
      return "$rc"
    fi
    echo "::warning::lint-docs: '${runner}' could not run (exit ${rc}) — falling back to vendored MD032 check" >&2
  else
    echo "::warning::lint-docs: no markdownlint-cli2 / npx runner found — using vendored MD032 check" >&2
  fi

  _lint_docs_vendored "${paths[@]}"
}

# Only run if executed directly (not sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  lint_docs_run "$@"
fi
