#!/usr/bin/env bash
set -euo pipefail

# Install this repo's skills + shared libs as symlinks into a Claude Code
# skills directory (default: ~/.claude/skills), so they load alongside an
# existing, independently-git-tracked skills repo without merging file
# trees. Claude Code's skill loader is exactly one level deep
# (~/.claude/skills/<name>/SKILL.md) — it does NOT recurse into a
# repo-root clone placed under ~/.claude/skills/, so cloning this repo
# directly there (e.g. ~/.claude/skills/ccxp-skills) would make every
# skill inside it invisible. Symlinking each top-level skill/shared-lib
# directory individually is the supported way to install a second skills
# repo as a sibling set (Claude Code follows symlinks and reads SKILL.md
# from the target).
#
# Usage:
#   scripts/install.sh                # installs into ~/.claude/skills
#   scripts/install.sh --target DIR   # installs into DIR instead
#   scripts/install.sh --dry-run      # print what would be linked, no writes
#   scripts/install.sh --uninstall    # remove only the symlinks this script owns

install_ccxp_skills() {
  local repo_root target=""
  local dry_run=0 uninstall=0

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --uninstall) uninstall=1; shift ;;
      *) echo "install.sh: unknown option: $1" >&2; return 2 ;;
    esac
  done

  target="${target:-$HOME/.claude/skills}"
  mkdir -p "$target"

  local name path
  for path in "$repo_root"/*/; do
    path="${path%/}"
    name="$(basename "$path")"

    # A skill (has SKILL.md) or a shared leading-underscore lib.
    if [ ! -f "$path/SKILL.md" ] && [[ "$name" != _* ]]; then
      continue
    fi

    local dest="$target/$name"

    if [ "$uninstall" = 1 ]; then
      if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$path" ]; then
        echo "removing $dest"
        [ "$dry_run" = 1 ] || rm "$dest"
      fi
      continue
    fi

    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$path" ]; then
      continue  # already correctly linked
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      echo "install.sh: $dest already exists and is not a link to this repo — skipping (remove or rename it manually to install this one)" >&2
      continue
    fi

    echo "linking $dest -> $path"
    [ "$dry_run" = 1 ] || ln -s "$path" "$dest"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_ccxp_skills "$@"
fi
