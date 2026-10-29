#!/usr/bin/env bash
# trash.sh -- send paths to the macOS Trash (~/.Trash) instead of `rm`.
#
#   trash.sh [--dry-run] [--label NAME] [--] <path>...
#
# Mover 1 (primary): /usr/bin/trash (macOS 15+, Finder-aware), one item at a time with
#   -v -s. The item lands in ~/.Trash with Finder "Put Back" metadata; the destination it
#   prints (it may rename on a name clash) is recorded.
# Mover 2 (fallback, when that binary is missing or fails for an item): plain `mv` to
#   $HOME/.Trash/<YYYYMMDD-HHMMSS>-<label>/files/<original absolute path>   (no Put Back)
# Either way one line per item goes to
#   $HOME/.Trash/<YYYYMMDD-HHMMSS>-<label>/MANIFEST.tsv    (original<TAB>trashed, "<TAB>mv" or "<TAB>trash")
# so every deletion is reversible: `mv <trashed> <original>` (or Finder Put Back).
#
# - Collision-safe: a batch folder that already exists gets -2, -3, ... appended;
#   nothing in the trash is ever overwritten.
# - All paths are checked before anything moves; one bad path moves nothing (exit 2).
# - Symlinks are moved as links (never followed). A path already covered by another
#   given path (dir and dir/file) is skipped.
# - Refused: /, $HOME or any parent of it, the trash dir or anything inside it.
# - --dry-run prints what would move and creates nothing.
# - Last output line: `TRASH <batch dir>` (dry-run: `TRASH (dry-run) <batch dir>`).
# - Env: CCXP_TRASH_DIR overrides the trash root (default $HOME/.Trash);
#   CCXP_TRASH_BIN overrides the primary mover (default /usr/bin/trash; set it empty to
#   force the `mv` fallback). Both are for tests.
# - Cross-volume `mv` copies then deletes; fine, still lands in the trash dir.
# - macOS may auto-empty the Trash after 30 days (Finder setting FXRemoveOldTrashItems).
# Exit: 0 ok, 1 a move failed part-way (earlier items stay moved, listed), 2 bad usage/path.

set -uo pipefail

die() { echo "trash: $*" >&2; exit 2; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Physical absolute path of $1 (last component NOT followed if it is a symlink).
abs-path() {
  local p="$1" dir base
  while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
  [[ "$p" != "/" ]] || { echo "/"; return; }
  base="$(basename -- "$p")"
  if [[ "$base" == "." || "$base" == ".." ]]; then
    (cd -P -- "$p" 2>/dev/null && pwd -P)
    return
  fi
  dir="$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
  if [[ "$dir" == "/" ]]; then printf '/%s\n' "$base"; else printf '%s/%s\n' "$dir" "$base"; fi
}

# true when $1 equals $2 or lies inside it (case-insensitive: macOS volumes are)
within() {
  local a b
  a="$(lower "$1")"; b="$(lower "$2")"
  [[ "$a" == "$b" || "$a" == "$b"/* ]]
}

dry=0 label="trash" paths=()
while (( $# )); do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --label) [[ $# -ge 2 ]] || die "--label needs a value"; label="$2"; shift 2 ;;
    --) shift; while (( $# )); do paths+=("$1"); shift; done ;;
    -*) die "unknown option: $1" ;;
    *) paths+=("$1"); shift ;;
  esac
done
(( ${#paths[@]} )) || die "usage: trash.sh [--dry-run] [--label NAME] [--] <path>..."

[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is not set to a directory"
home="$(cd -P -- "$HOME" && pwd -P)"
root="${CCXP_TRASH_DIR:-$home/.Trash}"
[[ "$root" == /* ]] || die "trash dir must be absolute: $root"
if [[ -d "$root" ]]; then root="$(cd -P -- "$root" && pwd -P)"; fi

label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')"
label="${label:0:40}"
[[ -n "$label" ]] || label="trash"

# Validate and resolve every path first; nothing moves unless all pass.
resolved=()
for p in "${paths[@]}"; do
  [[ -n "$p" ]] || die "empty path"
  case "$p" in *$'\n'*|*$'\t'*) die "control character in path: refused" ;; esac
  [[ -e "$p" || -L "$p" ]] || die "no such file or directory: $p"
  a="$(abs-path "$p")" || die "cannot resolve: $p"
  [[ -n "$a" ]] || die "cannot resolve: $p"
  [[ "$a" != "/" ]] || die "refusing to trash /"
  if within "$home" "$a"; then die "refusing to trash \$HOME or a parent of it: $a"; fi
  if within "$root" "$a"; then die "refusing to trash the trash dir or an item inside it: $a"; fi
  if within "$a" "$root"; then die "refusing to trash a parent of the trash dir: $a"; fi
  resolved+=("$a")
done

# Drop duplicates and paths covered by another given path.
keep=()
for ((i = 0; i < ${#resolved[@]}; i++)); do
  skip=0
  for ((j = 0; j < ${#resolved[@]}; j++)); do
    (( i == j )) && continue
    if [[ "${resolved[i]}" == "${resolved[j]}" ]]; then
      (( j < i )) && skip=1
    elif [[ "${resolved[i]}" == "${resolved[j]}"/* ]]; then
      skip=1
    fi
  done
  if (( skip )); then echo "skip (already covered): ${resolved[i]}"; else keep+=("${resolved[i]}"); fi
done

stamp="$(date +%Y%m%d-%H%M%S)"
batch="$root/$stamp-$label"
if (( dry )); then
  n=2
  while [[ -e "$batch" ]]; do batch="$root/$stamp-$label-$n"; n=$((n + 1)); done
else
  mkdir -p -- "$root" || die "cannot create $root"
  n=2
  until mkdir -- "$batch" 2>/dev/null; do
    [[ -e "$batch" ]] || die "cannot create $batch"
    batch="$root/$stamp-$label-$n"; n=$((n + 1))
  done
fi

bin="${CCXP_TRASH_BIN-/usr/bin/trash}"
[[ -n "$bin" && -x "$bin" ]] || bin=""

# Finder-aware move; on success sets $moved_to (destination reported by the tool).
trash-bin() {
  local a="$1" out line prefix
  moved_to=""
  out="$("$bin" -v -s -- "$a" 2>/dev/null)" || return 1
  [[ -e "$a" || -L "$a" ]] && return 1
  prefix="# Moved \"$a\" to \""
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"*\" ]]; then moved_to="${line#"$prefix"}"; moved_to="${moved_to%\"}"; fi
  done <<<"$out"
  [[ -n "$moved_to" ]] || moved_to="(in $root)"
  return 0
}

rc=0
for a in "${keep[@]}"; do
  dest="$batch/files$a"
  if (( dry )); then
    if [[ -n "$bin" ]]; then echo "would move: $a -> $root/ (via $bin; fallback $dest)"
    else echo "would move: $a -> $dest"; fi
    continue
  fi
  if [[ -n "$bin" ]] && trash-bin "$a"; then
    printf '%s\t%s\ttrash\n' "$a" "$moved_to" >> "$batch/MANIFEST.tsv"
    echo "moved: $a -> $moved_to"
  elif mkdir -p -- "$(dirname -- "$dest")" && [[ ! -e "$dest" && ! -L "$dest" ]] && mv -- "$a" "$dest"; then
    printf '%s\t%s\tmv\n' "$a" "$dest" >> "$batch/MANIFEST.tsv"
    echo "moved: $a -> $dest"
  else
    echo "FAILED: $a (left in place)" >&2
    rc=1
  fi
done

if (( dry )); then echo "TRASH (dry-run) $batch"; else echo "TRASH $batch"; fi
exit "$rc"
