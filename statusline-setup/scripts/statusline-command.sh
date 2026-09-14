#!/usr/bin/env bash
# Claude Code statusLine command — surfaces the task claimed by THIS clone.
#
# Repo root, TODO dir, and clone-id are all derived from the SESSION cwd, so the
# same global (~/.claude/settings.json) statusLine works across every
# clone/session regardless of which folder Claude was launched in.
#
# The clone-id is NOT reimplemented here. It used to be (`$(hostname):$root`),
# coupled to task_claim.sh by nothing but a comment, which meant a format change
# there left this silently matching nothing — and `sl-claimed-task-label` prints
# nothing on a miss, so a stale copy renders exactly like "no task claimed"
# (T20260911-698434). It now sources the single definition instead.
#
# _session/_lib.sh is deliberately NOT sourced: it runs `set -uo pipefail` and
# loads ~/.claude/.env at source time, and this runs on every prompt render.
# claimant-id.sh is side-effect-free for exactly this caller.

_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _sl_cand in "$_SL_DIR/../../_session/claimant-id.sh" \
                "$HOME/.claude/skills/_session/claimant-id.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_sl_cand" ] && { . "$_sl_cand"; break; }
done
unset _sl_cand

# Resolve the repo root from a session cwd (fall back to cwd if not a git repo).
sl-repo-root() {
  local cwd="$1"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd"
}

sl-clone-id() {
  # Must equal `_tc_claimant_id` for this clone or the statusline silently shows
  # no task; tests/statusline_setup.bats pins that equality directly.
  local repo_root="$1"
  if declare -F claimant_id >/dev/null 2>&1; then
    claimant_id "$repo_root"
  else
    # Lib not found (unusual install layout). Emit nothing rather than a
    # wrong-format guess: a guess would match no task anyway, and the statusline
    # must never fail the prompt.
    printf ''
  fi
}

# Current git branch for repo_root, or empty (detached HEAD / not a repo).
# symbolic-ref (not `branch --show-current`) so this also works pre-first-commit,
# when HEAD is an unborn symbolic ref with no commit behind it yet.
sl-branch-name() {
  local repo_root="$1"
  git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null || true
}

# Find the task file whose frontmatter `claimed_by:` matches this clone-id and
# print "<task-id>: <title>" (or just "<task-id>" if no title), else nothing.
sl-claimed-task-label() {
  local todo_dir="$1" clone_id="$2"
  [ -d "$todo_dir" ] || return 0

  # Escape regex-special chars in the id (realistically just '.') and anchor
  # the tail so a longer sibling path can't match as a prefix.
  local esc_id="${clone_id//\\/\\\\}"
  esc_id="${esc_id//./\\.}"
  local claimed_file
  claimed_file=$(grep -rlE "^claimed_by:[[:space:]]+${esc_id}([[:space:]]|$)" "$todo_dir" 2>/dev/null | head -1)
  [ -n "$claimed_file" ] || return 0

  # Task ID from the filename (e.g. T20260427-242654).
  local task_id task_title
  task_id=$(basename "$claimed_file" .md | grep -oE 'T[0-9]+-[0-9]+')
  # Title from the first "# T<id>: Title" / "# T<id> Title" heading — strip the
  # leading "# T<id>" + optional ": "/" " so we don't double the ID below.
  task_title=$(grep -m1 '^# T' "$claimed_file" 2>/dev/null | sed -E 's/^# T[0-9]+-[0-9]+:? +//; s/^# //')

  if [ -n "$task_id" ] && [ -n "$task_title" ]; then
    printf '%s: %s' "$task_id" "$task_title"
  elif [ -n "$task_id" ]; then
    printf '%s' "$task_id"
  fi
}

# Join non-empty parts with " | " (array-expansion IFS only uses its first
# char, so build the separator explicitly).
sl-join() {
  local out="" p
  for p in "$@"; do
    [ -z "$p" ] && continue
    if [ -z "$out" ]; then out="$p"; else out="$out | $p"; fi
  done
  printf '%s' "$out"
}

statusline-command() {
  local input cwd remaining
  input=$(cat)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // ""')
  remaining=$(printf '%s' "$input" | jq -r '.context_window.remaining_percentage // 100')
  [ -n "$cwd" ] || cwd="$PWD"

  local repo_root clone_id todo_dir task_label
  repo_root=$(sl-repo-root "$cwd")
  clone_id=$(sl-clone-id "$repo_root")
  todo_dir="$repo_root/dev/TODO"
  task_label=$(sl-claimed-task-label "$todo_dir" "$clone_id")

  local ctx_part="" branch_part="" task_part branch_name
  if [ -n "$remaining" ]; then
    ctx_part="ctx: $(printf '%.0f' "$remaining")% left"
  fi
  branch_name=$(sl-branch-name "$repo_root")
  if [ -n "$branch_name" ]; then
    branch_part="branch: $branch_name"
  fi
  if [ -n "$task_label" ]; then
    task_part="TASK: $task_label"
  else
    task_part="no claimed task"
  fi

  sl-join "$ctx_part" "$branch_part" "$task_part"
}

# Run only when executed directly (not when sourced), matching the
# quality-probe/scripts/probe.sh convention so BATS can source this file and
# unit-test the helper functions without invoking the stdin-reading main.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  statusline-command
fi
