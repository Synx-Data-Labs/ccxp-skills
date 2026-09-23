#!/usr/bin/env bash
# migrate.sh — move a task file from one repo's dev/TODO/ to another's
# (T20260827-201400). See migrate-task/SKILL.md for the full design.
#
# All mutating git/gh work runs against fresh /tmp clones — never the
# caller's interactive sibling clones (T20260629-332546's
# feedback_ephemeral_clone_cross_repo guard, mirroring /drive Phase 1.5).
set -euo pipefail

# --- frontmatter helpers (pure — touch only the leading '---' fence) --------

# mt-fm-get <file> <field> — print the field's value, or empty if absent.
mt-fm-get() {
  local file="$1" field="$2"
  awk -v field="$field" '
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { exit }
    in_fm && $0 ~ "^"field":" { sub("^"field":[[:space:]]*", ""); print; exit }
  ' "$file"
}

# mt-fm-delete <file> <field> — remove the field's line from the frontmatter
# fence only; body lines (even ones that look like frontmatter) are untouched.
mt-fm-delete() {
  local file="$1" field="$2" tmp
  tmp="$(mktemp)"
  awk -v field="$field" '
    NR==1 && $0=="---" { in_fm=1; print; next }
    in_fm && $0=="---" { in_fm=0; print; next }
    in_fm && $0 ~ "^"field":" { next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- collision check (T20260827-201400 Solution step 2) ---------------------

# mt-collision-check <target-dev-dir> <task-id> — exit 0 if the id exists
# nowhere under target's TODO/PARKING/JOURNAL, else exit 1 and print the hit.
mt-collision-check() {
  local dev_dir="$1" task_id="$2" dir match
  shopt -s nullglob
  for dir in "$dev_dir/TODO" "$dev_dir/PARKING" "$dev_dir/JOURNAL"; do
    [ -d "$dir" ] || continue
    for match in "$dir"/*"${task_id}"*; do
      echo "collision: $match"
      shopt -u nullglob
      return 1
    done
  done
  shopt -u nullglob
  return 0
}

# --- bidirectional-blocking check (Solution step 3) -------------------------

# mt-blocking-check <source-todo-dir> <task-id> <task-file> — exit 0 if clear
# to migrate, else exit 1 with a reason. Per lifecycle.md's "Blocking:
# Bidirectional Links": neither the migrated task's own blocks: field nor
# another source task's "Blocked by T<id>" pointing at it may be non-empty.
mt-blocking-check() {
  local todo_dir="$1" task_id="$2" task_file="$3" blocks other self_base

  blocks="$(mt-fm-get "$task_file" blocks)"
  if [ -n "$blocks" ] && [ "$blocks" != "[]" ]; then
    echo "blocks: non-empty ($blocks) — migrating would move the blocker out from under what it blocks"
    return 1
  fi

  # Compare by basename, not full path: the caller may pass an absolute
  # todo_dir alongside a relative task_file (both naming the same file),
  # which would never string-compare equal.
  self_base="$(basename "$task_file")"
  for other in "$todo_dir"/*.md; do
    [ -f "$other" ] || continue
    [ "$(basename "$other")" = "$self_base" ] && continue
    # Blocked-by status lines may name more than one blocker
    # (lifecycle.md: "list all blockers"; lint_tasks.py's check_blocked_by
    # extracts every id via findall) — the migrated id can appear anywhere
    # after "Blocked by ", not only immediately after it.
    if grep -qE "^status:[[:space:]]*Blocked by .*\b${task_id}\b" "$other"; then
      echo "another source task ($(basename "$other")) is Blocked by $task_id"
      return 1
    fi
  done
  return 0
}

# --- target-side "blocked by the migrated task" lookup ---------------------

# mt-target-blocked-by <target-todo-dir> <task-id> — print the T<id> of the
# first target-repo task whose status is "Blocked by <task-id>", or nothing.
# This is the *legitimate* insert-before trigger: the migrated task becomes
# someone else's blocker once it lands in the target queue. It is distinct
# from (and not hard-failed by) mt-blocking-check, which only rejects a
# still-live dependency on the SOURCE side.
mt-target-blocked-by() {
  local todo_dir="$1" task_id="$2" other base
  for other in "$todo_dir"/*.md; do
    [ -f "$other" ] || continue
    if grep -qE "^status:[[:space:]]*Blocked by .*\b${task_id}\b" "$other"; then
      base="$(basename "$other")"
      # Canonical id is T + 8 digits + '-' + 6 digits; fall back to
      # "up to the first '-'" for non-canonical fixture-style ids (T2-*.md).
      if [[ "$base" =~ ^(T[0-9]{8}-[0-9]{6}) ]]; then
        echo "${BASH_REMATCH[1]}"
      else
        echo "${base%%-*}"
      fi
      return 0
    fi
  done
  return 0
}

# --- queue.md append-or-insert-before (Solution — reuses /stage's algorithm) -

# mt-queue-insert <queue-file> <task-id> <slug> <title> <blocks-task-id>
# Appends "- [T<id>](<slug>): <title>" to queue-file, unless blocks-task-id
# is non-empty and already queued — then inserts immediately before it.
mt-queue-insert() {
  local queue="$1" task_id="$2" slug="$3" title="$4" blocks="$5"
  local line="- [${task_id}](${slug}): ${title}"

  if [ ! -f "$queue" ]; then
    printf '# TODO Queue\n\n' > "$queue"
  fi

  if [ -n "$blocks" ] && grep -qE "^- \[${blocks}\]" "$queue"; then
    local tmp lineno
    tmp="$(mktemp)"
    lineno="$(grep -m1 -nE "^- \[${blocks}\]" "$queue" | cut -d: -f1)"
    # MT_QUEUE_NEW_LINE via ENVIRON, not `awk -v` — awk -v assignments are
    # escape-processed (a literal "\n" in a title would become a real
    # newline and split one queue entry into two lines).
    MT_QUEUE_NEW_LINE="$line" awk -v n="$lineno" \
      'NR==n { print ENVIRON["MT_QUEUE_NEW_LINE"] } { print }' "$queue" > "$tmp"
    mv "$tmp" "$queue"
  else
    printf '%s\n' "$line" >> "$queue"
  fi
}

# --- title extraction --------------------------------------------------------

# mt-task-title <task-file> <task-id> — the "# T<id>: <title>" heading text.
mt-task-title() {
  local file="$1" task_id="$2"
  awk -v id="$task_id" -v FS=": " '
    $0 ~ "^# "id":" { sub("^# "id": *", ""); print; exit }
  ' "$file"
}

# --- orchestrator ------------------------------------------------------------

# migrate-task <task-id> <target-repo> [--dry-run]
migrate-task() {
  local task_id="" target_arg="" dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      -*)
        echo "migrate-task: unrecognized flag: $1" >&2
        return 2
        ;;
      *)
        if [ -z "$task_id" ]; then
          task_id="$1"
        elif [ -z "$target_arg" ]; then
          target_arg="$1"
        else
          echo "migrate-task: unexpected extra argument: $1" >&2
          return 2
        fi
        shift
        ;;
    esac
  done
  if [ -z "$task_id" ] || [ -z "$target_arg" ]; then
    echo "usage: migrate-task <task-id> <target-repo> [--dry-run]" >&2
    return 2
  fi

  # Canonical id shape only (T + 8-digit date + '-' + 6-digit random, per
  # _taskid/new.sh) — rejects anything containing a path separator or other
  # traversal-relevant character BEFORE it ever reaches a glob. Without this,
  # a caller-controlled id like "../PARKING/T20260101-000005" resolves the
  # dev/TODO/"$task_id"-*.md glob straight out of dev/TODO/ into an arbitrary
  # file, which the rest of this function would then happily read and print.
  if [[ ! "$task_id" =~ ^T[0-9]{8}-[0-9]{6}$ ]]; then
    echo "migrate-task: '$task_id' is not a canonical task id (T<8 digits>-<6 digits>)" >&2
    return 2
  fi

  # Step 1: resolve source (cwd) and target repo.
  local matches source_file
  matches=(dev/TODO/"${task_id}"-*.md)
  if [ ! -f "${matches[0]:-}" ]; then
    echo "migrate-task: ${task_id} not found under dev/TODO/ in $(pwd)" >&2
    return 3
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    echo "migrate-task: ${task_id} matches ${#matches[@]} files under dev/TODO/ — expected exactly one: ${matches[*]}" >&2
    return 3
  fi
  source_file="${matches[0]}"
  local slug; slug="$(basename "$source_file")"
  local source_repo_root; source_repo_root="$(pwd)"

  local target_dir
  if [ -d "$target_arg" ]; then
    target_dir="$target_arg"
  else
    echo "migrate-task: remote target-repo slugs require 'gh' and a real clone — not exercised in this fixture path" >&2
    return 4
  fi

  # Step 2: collision-check against target.
  local collision_out
  if ! collision_out="$(mt-collision-check "$target_dir/dev" "$task_id")"; then
    echo "migrate-task: $collision_out" >&2
    return 5
  fi

  # Step 3: bidirectional-blocking check against source.
  local blocking_out
  if ! blocking_out="$(mt-blocking-check "$source_repo_root/dev/TODO" "$task_id" "$source_file")"; then
    echo "migrate-task: blocked — $blocking_out" >&2
    return 6
  fi

  # claimed_by guard — hard-fail rather than silently drop an in-progress claim.
  local claimed_by; claimed_by="$(mt-fm-get "$source_file" claimed_by)"
  if [ -n "$claimed_by" ]; then
    echo "migrate-task: claimed_by is non-empty ($claimed_by) — release the claim before migrating" >&2
    return 7
  fi

  local title; title="$(mt-task-title "$source_file" "$task_id")"
  # NOTE: the migrated task's own `blocks:` field is always empty by this
  # point — mt-blocking-check above hard-fails on a non-empty one. The
  # legitimate insert-before trigger is the OTHER direction: a task already
  # in the TARGET queue that is itself "Blocked by" the task being migrated.
  local target_blocks; target_blocks="$(mt-target-blocked-by "$target_dir/dev/TODO" "$task_id")"

  if [ "$dry_run" -eq 1 ]; then
    local staged queue_before queue_after
    staged="$(mktemp)"; queue_before="$(mktemp)"; queue_after="$(mktemp)"
    # shellcheck disable=SC2064  # intentional: expand the paths now, not at trap time
    trap "rm -f '$staged' '$queue_before' '$queue_after'" EXIT

    cp "$source_file" "$staged"
    mt-fm-delete "$staged" target-repo
    mt-fm-delete "$staged" target-path

    # T20260919-231319: genericize any known internal identifier in the
    # staged copy (substituting a mapped placeholder), or refuse outright
    # when a hit has no safe replacement — never land an unmapped internal
    # identifier in the target repo silently. This is the only "land
    # destination" code path that exists today (the live, non-dry-run flow
    # below is an unimplemented stub) — see the design task's Solution #6.
    local lint_id_script
    lint_id_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/repo-conventions/scripts/lint_identifiers.py"
    if command -v python3 >/dev/null 2>&1 && [ -f "$lint_id_script" ]; then
      if ! python3 "$lint_id_script" --changed "$staged" --fix; then
        echo "migrate-task: internal-identifier check refused the staged copy (see output above) — disposition the finding(s), then retry" >&2
        return 9
      fi
    fi

    echo "=== would add to ${target_dir}/dev/TODO/${slug} ==="
    diff -u /dev/null "$staged" || true

    if [ -f "$target_dir/dev/TODO/queue.md" ]; then
      cp "$target_dir/dev/TODO/queue.md" "$queue_before"
    else
      : > "$queue_before"
    fi
    cp "$queue_before" "$queue_after"
    mt-queue-insert "$queue_after" "$task_id" "$slug" "$title" "$target_blocks"
    echo "=== would update ${target_dir}/dev/TODO/queue.md ==="
    diff -u "$queue_before" "$queue_after" || true
    if [ -n "$target_blocks" ]; then
      echo "(inserted immediately before $target_blocks — it is Blocked by $task_id)"
    fi

    echo "=== would git mv source to dev/JOURNAL/<today>-${slug} ==="
    echo "(status: Done; ## Migrated section added; removed from source queue.md)"
    return 0
  fi

  echo "migrate-task: live (non-dry-run) mode opens real branches/PRs — not exercised in unit tests" >&2
  return 8
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  migrate-task "$@"
fi
