#!/usr/bin/env bash
# find-memory-dir.sh — resolve the CURRENT clone's Claude Code auto-memory
# directory from its working-directory path, with no glob sweep across other
# clones/checkouts of the same repo (that's /retro Phase 1b's job, not this
# skill's — see memory-to-skill/SKILL.md).
#
# Claude Code keys a project's memory directory by its absolute working-dir
# path with every "/" replaced by "-" (e.g. /a/b/c -> -a-b-c), stored under
# ~/.claude/projects/<encoded-path>/memory/. This script reproduces that
# encoding deterministically instead of re-deriving it in prose each run.
#
# Usage:
#   find-memory-dir.sh [--cwd PATH] [--claude-home PATH]
#
# Output: the memory directory's absolute path on stdout.
# Exit: 0 if the directory exists, 1 if it does not (message on stderr), 2 on
# a usage error.
#
# Sourceable: defines functions only; the CLI entrypoint runs solely under
# the direct-execution guard at the bottom (repo guidelines).

set -euo pipefail

memory-to-skill-find-dir-usage() {
  cat <<'EOF'
Usage:
  find-memory-dir.sh [--cwd PATH] [--claude-home PATH]

Prints the absolute path to the current clone's Claude Code auto-memory
directory (~/.claude/projects/<encoded-cwd>/memory), derived from --cwd (or
the actual working directory when omitted). Exits 1 if no memory directory
exists for that path yet (nothing has been remembered there).

Options:
  --cwd PATH          Working-directory path to encode (default: pwd).
  --claude-home PATH  Override ~/.claude (default: $HOME/.claude).
EOF
}

memory-to-skill-find-dir() {
  local target_cwd="" claude_home="${HOME:-}/.claude"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cwd) target_cwd="$2"; shift 2 ;;
      --claude-home) claude_home="$2"; shift 2 ;;
      -h|--help) memory-to-skill-find-dir-usage; return 0 ;;
      *) echo "find-memory-dir.sh: unknown argument: $1" >&2; return 2 ;;
    esac
  done

  [ -n "$target_cwd" ] || target_cwd="$(pwd)"

  # Must be an absolute path — Claude Code's own encoding is always over the
  # absolute working-directory path, never a relative one.
  case "$target_cwd" in
    /*) ;;
    *) echo "find-memory-dir.sh: --cwd must be an absolute path, got: $target_cwd" >&2; return 2 ;;
  esac

  local encoded="${target_cwd//\//-}"
  local dir="$claude_home/projects/$encoded/memory"

  if [ ! -d "$dir" ]; then
    echo "find-memory-dir.sh: no memory directory for $target_cwd (looked for $dir)" >&2
    return 1
  fi

  echo "$dir"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  memory-to-skill-find-dir "$@"
fi
