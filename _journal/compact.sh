#!/usr/bin/env bash
# compact.sh <month> --repo-root <dir> [--dry-run]
#
# Monthly compaction of dev/JOURNAL/: collapses last month's individual
# task-closure files into a single digest, moving originals to
# archive/YYYY-MM/ (history preserved via `git mv`).
#
# ALGORITHM:
#   1. Validate <month> matches YYYY-MM.
#   2. List dev/JOURNAL/*.md (excludes archive/ by construction).
#   3. For each file, determine its effective month:
#        a. filename matches ^YYYY-MM-DD-...           -> that YYYY-MM
#        b. else fall back to the file's last commit date (git log -1).
#   4. Keep only files whose effective month == <month>.
#   5. Split into "task files" (filename contains T<8digits>-<6digits>-)
#      and "other files" (everything else).
#   6. For each task file extract ID / Title / Shipped-via / Notes from a
#      "## Closed" section (best-effort; "-"/"-" if absent or not found).
#   7. Build dev/JOURNAL/<month>-digest.md per the DIGEST FORMAT.
#   8. N == 0 still writes a valid digest with empty tables.
#   9. git mv every kept file into archive/<month>/, write/overwrite the
#      digest, and `git add` it.
#  10. Idempotent: a second run on an already-compacted month is a no-op
#      (nothing left under dev/JOURNAL/ matches that month anymore).
#
# --dry-run prints what would be archived/written without touching the
# filesystem or git index.
set -euo pipefail

_jc_usage() {
  sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//; /^set -/d'
}

_jc_validate_month() {
  # $1 month -> 0 if it matches YYYY-MM (valid calendar month), else 1.
  [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]
}

_jc_filename_month() {
  # $1 basename -> echoes YYYY-MM if it starts with a YYYY-MM-DD- date prefix
  # AND MM is a valid calendar month (01-12), else empty. Filename date wins
  # over any commit-date fallback (step 3a). Requiring a valid month here
  # (matching _jc_validate_month's own 01-12 check) matters: a bogus prefix
  # like "2026-13-01-" can never equal any real <month> CLI argument, so
  # without this check such a file would be permanently un-archivable
  # instead of correctly falling through to the commit-date path.
  local base="$1"
  if [[ "$base" =~ ^([0-9]{4}-(0[1-9]|1[0-2]))-[0-9]{2}- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

_jc_commit_month() {
  # $1 repo_root  $2 relpath (relative to repo_root) -> YYYY-MM of the file's
  # last commit touching it on the current branch, or empty if it has none.
  # KNOWN LIMITATION: stderr is discarded, so a real git failure (corrupted
  # .git, transient error) is indistinguishable from "file has no commits" --
  # both just skip the file silently. The upfront .git check in _jc_run
  # covers the common "repo_root isn't a repo at all" case; a mid-run git
  # failure on one specific file is not currently surfaced.
  local repo_root="$1" relpath="$2" d
  d="$(git -C "$repo_root" log -1 --format=%ad --date=format:%Y-%m-%d -- "$relpath" 2>/dev/null || true)"
  [ -n "$d" ] || return 0
  printf '%s' "${d:0:7}"
}

_jc_file_month() {
  # $1 repo_root  $2 relpath -> the file's effective month (filename date,
  # falling back to last-commit date).
  local repo_root="$1" relpath="$2" base m
  base="$(basename "$relpath")"
  m="$(_jc_filename_month "$base")"
  if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  _jc_commit_month "$repo_root" "$relpath"
}

_jc_list_journal_files() {
  # $1 repo_root -> one relpath (relative to repo_root) per line, for every
  # dev/JOURNAL/*.md file. -maxdepth 1 excludes archive/ by construction.
  # Excludes previously-generated *-digest.md files -- those are this
  # script's own output, not source material to re-compact (idempotency:
  # without this exclusion, a digest written by a prior run would itself
  # get swept up and archived on the next run).
  # Assumes JOURNAL filenames never contain embedded newlines (true for
  # every filename this convention produces, hand-authored or scripted) --
  # a newline-safe (NUL-delimited) pipeline would be needed if that ever
  # stops holding.
  # Strips the repo_root prefix via bash parameter expansion, not sed --
  # repo_root is a user-supplied path (--repo-root) and splicing it
  # unescaped into a sed pattern (as an earlier version of this function
  # did) breaks on a literal "#" and could regex-mismatch on other
  # metacharacters; "${var#"$pat"}" removal is always literal.
  local repo_root="$1" abspath
  find "$repo_root/dev/JOURNAL" -maxdepth 1 -type f -name '*.md' ! -name '*-digest.md' 2>/dev/null \
    | sort \
    | while IFS= read -r abspath; do
        printf '%s\n' "${abspath#"$repo_root"/}"
      done
}

_jc_is_task_filename() {
  # $1 basename -> 0 if it contains a T<8digits>-<6digits> token, else 1.
  [[ "$1" =~ T[0-9]{8}-[0-9]{6} ]]
}

_jc_task_id() {
  # $1 basename -> the T<8digits>-<6digits> token, or empty.
  grep -oE 'T[0-9]{8}-[0-9]{6}' <<<"$1" | head -1
}

_jc_extract_title() {
  # $1 file  $2 id -> first "# " heading line, stripped of the "# " prefix
  # and a duplicated leading "T<id>: " if present; falls back to the basename.
  local file="$1" id="$2" line
  line="$(grep -m1 '^# ' "$file" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    basename "$file"
    return 0
  fi
  line="${line#\# }"
  line="${line#"$id": }"
  printf '%s' "$line"
}

_jc_extract_closed() {
  # $1 file -> "shipped_via\tnotes", defaulting either/both to "-". No
  # "## Closed" heading at all -> "-\t-" immediately.
  local file="$1" body shipped notes
  body="$(awk '/^## Closed/{f=1; next} /^## /{f=0} f' "$file" 2>/dev/null || true)"
  if [ -z "$(grep -m1 '^## Closed' "$file" 2>/dev/null || true)" ]; then
    printf -- '-\t-\n'
    return 0
  fi
  shipped="$(grep -oE '([A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' <<<"$body" | head -1 || true)"
  [ -n "$shipped" ] || shipped="-"
  notes="$(grep -m1 -v '^[[:space:]]*$' <<<"$body" || true)"
  notes="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$notes")"
  [ -n "$notes" ] || notes="-"
  printf '%s\t%s\n' "$shipped" "$notes"
}

_jc_escape_cell() {
  # $1 text -> markdown-table-safe: escapes literal "|" as "\|" so extracted
  # free-form title/notes text can't break the digest table's column
  # alignment (a title like "Fix A | B toggle bug" is a realistic input).
  printf '%s' "$1" | sed 's/|/\\|/g'
}

_jc_task_row() {
  # $1 repo_root  $2 relpath -> one "| ID | Title | Shipped via | Notes |" row.
  local repo_root="$1" relpath="$2" file id title closed shipped notes
  file="$repo_root/$relpath"
  id="$(_jc_task_id "$(basename "$relpath")")"
  title="$(_jc_escape_cell "$(_jc_extract_title "$file" "$id")")"
  closed="$(_jc_extract_closed "$file")"
  shipped="$(_jc_escape_cell "${closed%%$'\t'*}")"
  notes="$(_jc_escape_cell "${closed#*$'\t'}")"
  printf '| %s | %s | %s | %s |' "$id" "$title" "$shipped" "$notes"
}

_jc_build_digest() {
  # $1 month  $2 n  $3 task_rows (newline-joined)  $4 other_files (newline-joined)
  local month="$1" n="$2" task_rows="$3" other_files="$4"
  printf '# JOURNAL digest: %s\n\n' "$month"
  printf '**Files archived**: %s (see archive/%s/ for full content)\n\n' "$n" "$month"
  printf '### Tasks closed this month\n'
  printf '| ID | Title | Shipped via | Notes |\n'
  printf '|----|-------|-------------|-------|\n'
  if [ -n "$task_rows" ]; then printf '%s\n' "$task_rows"; fi
  printf '\n### Other files archived this month\n'
  if [ -n "$other_files" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf -- '- %s\n' "$f"
    done <<<"$other_files"
  fi
}

_jc_run() {
  local month="$1" repo_root="$2" dry_run="$3"

  # Fail fast on a bad --repo-root instead of silently fabricating a
  # dev/JOURNAL/ tree there (a typo'd path would otherwise "succeed" with
  # an empty, misleading digest).
  if [ ! -d "$repo_root/.git" ]; then
    echo "compact.sh: '$repo_root' does not look like a git repo (no .git)" >&2
    return 2
  fi

  # No mkdir here: _jc_list_journal_files already tolerates a missing
  # dev/JOURNAL/ (find's stderr is discarded, yielding zero files), and
  # creating it unconditionally would make --dry-run mutate the filesystem
  # in a repo that never had one -- the mkdir only happens right before the
  # real digest write, below, on a non-dry-run.

  local relpath base fmonth task_relpaths=() other_relpaths=()
  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    base="$(basename "$relpath")"
    fmonth="$(_jc_file_month "$repo_root" "$relpath")"
    [ "$fmonth" = "$month" ] || continue
    if _jc_is_task_filename "$base"; then
      task_relpaths+=("$relpath")
    else
      other_relpaths+=("$relpath")
    fi
  done < <(_jc_list_journal_files "$repo_root")

  local task_rows="" row other_files=""
  for relpath in "${task_relpaths[@]:-}"; do
    [ -n "$relpath" ] || continue
    row="$(_jc_task_row "$repo_root" "$relpath")"
    if [ -n "$task_rows" ]; then task_rows+=$'\n'"$row"; else task_rows="$row"; fi
  done
  for relpath in "${other_relpaths[@]:-}"; do
    [ -n "$relpath" ] || continue
    base="$(basename "$relpath")"
    if [ -n "$other_files" ]; then other_files+=$'\n'"$base"; else other_files="$base"; fi
  done

  local n=$(( ${#task_relpaths[@]} + ${#other_relpaths[@]} ))
  local digest_relpath="dev/JOURNAL/$month-digest.md"
  local digest_path="$repo_root/$digest_relpath"

  # Idempotency (step 10): once a month is fully compacted, its files no
  # longer live at dev/JOURNAL/ top level, so a re-run always finds n == 0
  # for it. Rewriting the digest in that case would DESTROY the real record
  # from the original compaction, so a re-run with nothing new to archive
  # and an existing digest is a true no-op -- leave the digest untouched.
  if [ "$n" -eq 0 ] && [ -f "$digest_path" ]; then
    [ "$dry_run" = "1" ] && cat "$digest_path"
    return 0
  fi

  local digest
  digest="$(_jc_build_digest "$month" "$n" "$task_rows" "$other_files")"

  if [ "$dry_run" = "1" ]; then
    printf '%s' "$digest"
    for relpath in "${task_relpaths[@]:-}" "${other_relpaths[@]:-}"; do
      [ -n "$relpath" ] || continue
      printf 'would archive: %s\n' "$relpath"
    done
    return 0
  fi

  # KNOWN LIMITATION: this loop is not atomic. If one `git mv` fails partway
  # (permissions, disk full, a stray pre-existing destination), `set -e`
  # aborts before the digest below is written, leaving some files already
  # moved and others not. A resumed run only sees the still-unarchived
  # remainder, so its digest's "Files archived" count and rows reflect just
  # that remainder -- not the true total across both attempts. Recovering
  # from a partial failure currently needs manual inspection of
  # archive/<month>/ before re-running.
  if [ "$n" -gt 0 ]; then
    mkdir -p "$repo_root/dev/JOURNAL/archive/$month"
    for relpath in "${task_relpaths[@]:-}" "${other_relpaths[@]:-}"; do
      [ -n "$relpath" ] || continue
      base="$(basename "$relpath")"
      git -C "$repo_root" mv "$relpath" "dev/JOURNAL/archive/$month/$base"
    done
  fi

  mkdir -p "$repo_root/dev/JOURNAL"
  printf '%s' "$digest" > "$digest_path"
  # `git -C "$repo_root"` chdirs before resolving path args, so the pathspec
  # here must be relative to repo_root (like the git mv above) -- NOT
  # prefixed with $repo_root again (that double-prefixes and 404s whenever
  # repo_root is a real relative path; only worked before because every
  # caller happened to pass an absolute --repo-root).
  git -C "$repo_root" add "$digest_relpath"
}

journal_compact() {
  case "${1:-}" in -h|--help) _jc_usage; return 0 ;; esac
  local month="${1:-}"; shift || true
  [ -n "$month" ] || { echo "compact.sh: <month> is required (YYYY-MM)" >&2; return 2; }
  _jc_validate_month "$month" || { echo "compact.sh: invalid month '$month' (want YYYY-MM)" >&2; return 2; }

  local repo_root="." dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        [ $# -ge 2 ] || { echo "compact.sh: --repo-root needs a dir" >&2; return 2; }
        repo_root="$2"; shift 2 ;;
      --dry-run)   dry_run=1; shift ;;
      -h|--help)   _jc_usage; return 0 ;;
      -*)          echo "compact.sh: unknown option '$1'" >&2; return 2 ;;
      *)           echo "compact.sh: unexpected argument '$1'" >&2; return 2 ;;
    esac
  done
  _jc_run "$month" "$repo_root" "$dry_run"
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  journal_compact "$@"
fi
