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
#   scripts/install.sh --wire-hooks   # also wire the _gh/auto-switch.sh
#                                     # SessionStart hook into settings.json
#                                     # (composes with --dry-run/--uninstall)

# $1 skills target dir (its sibling is where settings.json lives, same
# skills/+settings.json layout documented in statusline-setup/SKILL.md —
# holds for an alternate CLAUDE_CONFIG_DIR too, not just the default).
# $2 dry_run (0/1)  $3 uninstall (0/1)
_ccxp_wire_session_hook() {
  local target="$1" dry_run="$2" uninstall="$3"
  local settings_file cmd cmd_tilde
  settings_file="$(dirname "$target")/settings.json"
  cmd="bash $target/_gh/auto-switch.sh"

  # A previously-wired entry may spell this "~/..." instead of absolute (the
  # README's own documented snippet does) — recognize that spelling too,
  # without trying to generically tilde-expand arbitrary existing command
  # strings (error-prone: the "~" sits mid-string, after "bash ", not at
  # index 0). Only matches when $target is actually under $HOME.
  cmd_tilde=""
  case "$target" in
    "$HOME"/*) cmd_tilde="bash ~${target#"$HOME"}/_gh/auto-switch.sh" ;;
  esac

  command -v jq >/dev/null 2>&1 || {
    echo "install.sh: --wire-hooks requires jq (e.g. brew install jq) — skipping hook wiring" >&2
    return 1
  }

  if [ ! -f "$settings_file" ]; then
    [ "$uninstall" = 1 ] && { echo "no $settings_file — nothing to unwire"; return 0; }
    echo "creating $settings_file"
    if [ "$dry_run" != 1 ]; then
      mkdir -p "$(dirname "$settings_file")"
      printf '{}\n' > "$settings_file"
    fi
  fi

  # Does an existing SessionStart hook already point at this script (either
  # spelling above)? settings.json itself may be a symlink into a separate
  # dotfiles repo (true on the machine this hook was first wired on) — `-f`
  # above already follows that, jq reads through it fine too.
  local existing found=0
  while IFS= read -r existing; do
    [ -z "$existing" ] && continue
    if [ "$existing" = "$cmd" ] || { [ -n "$cmd_tilde" ] && [ "$existing" = "$cmd_tilde" ]; }; then
      found=1; break
    fi
  done < <(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$settings_file" 2>/dev/null)

  if [ "$uninstall" = 1 ]; then
    if [ "$found" = 0 ]; then
      echo "no SessionStart hook for _gh/auto-switch.sh in $settings_file — nothing to unwire"
      return 0
    fi
    echo "removing SessionStart hook for _gh/auto-switch.sh from $settings_file"
    [ "$dry_run" = 1 ] && return 0
    local tmp
    tmp="$(mktemp "${settings_file}.XXXXXX")" || return 1
    jq --arg cmd "$cmd" --arg cmd_tilde "$cmd_tilde" '
      .hooks.SessionStart |= (
        map(.hooks |= map(select(.command != $cmd and .command != $cmd_tilde)))
        | map(select((.hooks // []) | length > 0))
      )
    ' "$settings_file" > "$tmp" || { rm -f "$tmp"; return 1; }
    # settings_file may itself be a symlink (e.g. into a dotfiles repo) —
    # write through it (cat >) rather than `mv` a temp file over it, which
    # would silently replace the symlink with a plain file.
    if [ -L "$settings_file" ]; then cat "$tmp" > "$settings_file"; rm -f "$tmp"
    else mv "$tmp" "$settings_file"; fi
    return 0
  fi

  if [ "$found" = 1 ]; then
    echo "$settings_file already wires _gh/auto-switch.sh — skipping"
    return 0
  fi

  echo "wiring SessionStart hook -> $cmd in $settings_file"
  [ "$dry_run" = 1 ] && return 0

  local tmp
  tmp="$(mktemp "${settings_file}.XXXXXX")" || return 1
  jq --arg cmd "$cmd" '
    .hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $cmd}]}])
  ' "$settings_file" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -L "$settings_file" ]; then cat "$tmp" > "$settings_file"; rm -f "$tmp"
  else mv "$tmp" "$settings_file"; fi
}

install_ccxp_skills() {
  local repo_root target=""
  local dry_run=0 uninstall=0 wire_hooks=0

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --uninstall) uninstall=1; shift ;;
      --wire-hooks) wire_hooks=1; shift ;;
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

  [ "$wire_hooks" = 1 ] && _ccxp_wire_session_hook "$target" "$dry_run" "$uninstall"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  install_ccxp_skills "$@"
fi
