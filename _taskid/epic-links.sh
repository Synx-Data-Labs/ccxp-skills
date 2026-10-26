#!/usr/bin/env bash
# Keep epic member lines in dev/EPICS/E*.md clickable and current.
#
# Member-line format:   - [T<8>-<6>](<path relative to dev/EPICS/>) — <title>
#   path = ../TODO/T<id>-<slug>.md | ../PARKING/... | ../JOURNAL/<date>-T<id>-<slug>.md
# Legacy plain form `- T<id> — <title>` stays accepted (sync converts it).
# A task file renames on close (TODO -> JOURNAL, date prefix) and on park, so
# links rot unless `sync` reruns after every move.
#
# Usage (run from the repo toplevel; EPIC_LINKS_DIR overrides dev/EPICS):
#   bash epic-links.sh sync                 # rewrite every member link to the task's current file; idempotent
#   bash epic-links.sh lint                 # exit 1 if any link target is missing
#   bash epic-links.sh add <E1|file> <Tid> [title]   # append a member line (no-op if already listed)
#
# Sourceable: source epic-links.sh; epic_links_sync / epic_links_lint / epic_links_add
# A member whose task file exists nowhere is left/made plain and reported on stderr.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
fi

_EPIC_LINKS_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_EPIC_LINKS_DIR_SELF/url.sh"

_EL_ID='T[0-9]{8}-[0-9]{6}'
_EL_LINKED="^-[[:space:]]+\\[(${_EL_ID})\\]\\(([^)]*)\\)(.*)\$"
_EL_PLAIN="^-[[:space:]]+(${_EL_ID})(.*)\$"

function _epic_links_files() {
  local d="${EPIC_LINKS_DIR:-dev/EPICS}" f
  for f in "$d"/E*.md; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done
  return 0
}

# _epic_links_member <line> -> "id<TAB>path<TAB>rest" (path empty for plain); 1 if not a member line
function _epic_links_member() {
  local line="$1"
  if [[ "$line" =~ $_EL_LINKED ]]; then
    printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$line" =~ $_EL_PLAIN ]]; then
    printf '%s\t\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    return 1
  fi
}

# _epic_links_is_url <member parts> -> 0 when the link path is an absolute http(s) URL
function _epic_links_is_url() {
  local rest="${1#*$'\t'}" path
  path="${rest%%$'\t'*}"
  [[ "$path" =~ ^https?:// ]]
}

function epic_links_sync() {
  local f line parts id rest cur tmp target
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      if parts="$(_epic_links_member "$line")"; then
        id="${parts%%$'\t'*}"; rest="${parts#*$'\t'*$'\t'}"
        if _epic_links_is_url "$parts"; then
          # Cross-repo member: the link is already correct by construction; never rewrite it.
          printf '%s\n' "$line" >> "$tmp"
        elif cur="$(taskid-path "$id")"; then
          target="../${cur#dev/}"
          printf -- '- [%s](%s)%s\n' "$id" "$target" "$rest" >> "$tmp"
        else
          printf -- '- %s%s\n' "$id" "$rest" >> "$tmp"
          echo "epic-links: $id in $f has no task file (left plain)" >&2
        fi
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$f"
    if ! cmp -s "$tmp" "$f"; then cat "$tmp" > "$f"; fi
    rm -f "$tmp"
  done < <(_epic_links_files)
  return 0
}

function epic_links_lint() {
  local f line parts id path rest bad=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      parts="$(_epic_links_member "$line")" || continue
      id="${parts%%$'\t'*}"; rest="${parts#*$'\t'}"; path="${rest%%$'\t'*}"
      if [ -n "$path" ] && ! [[ "$path" =~ ^https?:// ]] && [ ! -e "$(dirname "$f")/$path" ]; then
        echo "epic-links: $f: $id -> $path does not exist (run: epic-links.sh sync)" >&2
        bad=1
      fi
    done < "$f"
  done < <(_epic_links_files)
  return "$bad"
}

# epic_links_add <E<n>|file> <Tid> [title] — title defaults to the task's H1.
function epic_links_add() {
  local epic="${1:-}" id="${2:-}" title="${3:-}" f cur last line
  if [ -z "$epic" ] || [ -z "$id" ]; then
    echo "usage: epic_links_add <E1|file> <Tid> [title]" >&2
    return 2
  fi
  if [ -f "$epic" ]; then
    f="$epic"
  else
    f="$(find "${EPIC_LINKS_DIR:-dev/EPICS}" -maxdepth 1 -name "${epic}-*.md" -o -maxdepth 1 -name "${epic}.md" 2>/dev/null | sort | head -n1)"
  fi
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "epic-links: no epic file for '$epic'" >&2
    return 1
  fi
  if grep -qE "^-[[:space:]]+\\[?${id}" "$f"; then return 0; fi
  if cur="$(taskid-path "$id")"; then
    if [ -z "$title" ]; then
      title="$(sed -n -E "s/^# ${id}: *//p" "$cur" | head -n1)"
    fi
    line="- [$id](../${cur#dev/})"
  else
    line="- $id"
  fi
  if [ -n "$title" ]; then line="$line — $title"; fi
  last="$(grep -nE "^-[[:space:]]+\\[?${_EL_ID}" "$f" | tail -n1 | cut -d: -f1)"
  if [ -n "$last" ]; then
    { head -n "$last" "$f"; printf '%s\n' "$line"; tail -n +"$((last + 1))" "$f"; } > "$f.tmp"
    mv "$f.tmp" "$f"
  else
    printf '\n%s\n' "$line" >> "$f"
  fi
  return 0
}

function epic_links_main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    sync) epic_links_sync "$@" ;;
    lint) epic_links_lint "$@" ;;
    add)  epic_links_add "$@" ;;
    *) echo "Usage: epic-links.sh sync | lint | add <E1|file> <Tid> [title]" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  epic_links_main "$@"
fi
