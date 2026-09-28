#!/usr/bin/env bats
# Tests for _session/task-state.sh — one-shot unified state query (T20260719-204917).
#
# Pure logic (frontmatter get, id extraction, rendering) is exercised by
# sourcing the script directly (the CLI dispatch is BASH_SOURCE-guarded, so
# sourcing is side-effect-free). I/O is hermetic: a throwaway git repo in
# $BATS_TEST_TMPDIR supplies branches + the dev/ fixture tree; `gh` is
# injected via the TASKID_GH seam already defined by _taskid/url.sh (the same
# DI point taskid_url.bats uses) — task-state.sh calls `taskid-gh` for PR
# lookups, so no new seam was needed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_session/task-state.sh"

  cd "$BATS_TEST_TMPDIR"
  git init -q .
  git config user.email t@t; git config user.name t
  git remote add origin https://github.com/your-org/build-pipeline-repo.git

  mkdir -p dev/TODO dev/PARKING dev/JOURNAL

  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "[]"
STUB
  chmod +x bin/gh
  export TASKID_GH="$BATS_TEST_TMPDIR/bin/gh"
}

_mk_task_file() {
  # $1 path  $2 status  $3 claimed_by  $4 blocks  $5 related  $6 blocked-by
  cat > "$1" <<EOF
---
estimation: 1h
status: ${2:-Open}
claimed_by: ${3:-}
blocks: ${4:-}
related: ${5:-}
blocked-by: ${6:-}
---

# demo
EOF
}

# --- frontmatter read (pure) --------------------------------------------------

@test "ts_fm_get reads a frontmatter field and returns empty for an unset one" {
  f="$BATS_TEST_TMPDIR/t.md"; _mk_task_file "$f" Coding "me:here"
  [ "$(ts_fm_get "$f" status)" = "Coding" ]
  [ "$(ts_fm_get "$f" claimed_by)" = "me:here" ]
  [ -z "$(ts_fm_get "$f" priority)" ]
}

@test "ts_fm_get ignores body lines that look like frontmatter fields" {
  f="$BATS_TEST_TMPDIR/t.md"
  printf -- '---\nstatus: Open\nestimation: 1h\n---\n\nstatus: decoy body line\n' > "$f"
  [ "$(ts_fm_get "$f" status)" = "Open" ]
}

# --- id extraction (pure) -----------------------------------------------------

@test "ts_extract_ids pulls distinct ids from free-form prose fields, excluding self" {
  run ts_extract_ids "T20260629-281129" "Blocked by T20260718-300856" \
    "T20260718-300856 already done; T20260718-274226 too" "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260718-300856"* ]]
  [[ "$output" == *"T20260718-274226"* ]]
  [[ "$output" != *"T20260629-281129"* ]]
}

@test "ts_extract_ids dedupes repeated mentions across fields" {
  run ts_extract_ids "T1-self" "T20260718-300856 blocks this" "" "T20260718-300856" ""
  # exactly one line of output
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "ts_extract_ids returns nothing for none/[]/empty prose" {
  run ts_extract_ids "T20260629-281129" "Open" "none" "[]" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- one-line status of a referenced id --------------------------------------

@test "ts_one_line_status reports a found task's status and claimant" {
  mkdir -p dev/TODO
  _mk_task_file dev/TODO/T20260718-300856-demo.md Coding "host:/clone"
  run ts_one_line_status T20260718-300856
  [ "$status" -eq 0 ]
  [[ "$output" == "T20260718-300856: Coding (claimed_by host:/clone)"* ]]
}

@test "ts_one_line_status reports unclaimed without a claimed_by suffix" {
  mkdir -p dev/TODO
  _mk_task_file dev/TODO/T20260718-300856-demo.md Open ""
  run ts_one_line_status T20260718-300856
  [ "$output" = "T20260718-300856: Open" ]
}

@test "ts_one_line_status reports not-found for an id absent from this repo" {
  run ts_one_line_status T99999999-999999
  [ "$output" = "T99999999-999999: (not found in this repo)" ]
}

# --- branch lookup -------------------------------------------------------------

@test "ts_branch_lookup finds a remote branch named after the task id" {
  git commit -q --allow-empty -m init
  git update-ref refs/remotes/origin/t20260718-300856-fix-isolation HEAD
  run ts_branch_lookup T20260718-300856
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin/t20260718-300856-fix-isolation"* ]]
}

@test "ts_branch_lookup returns empty when no branch references the id" {
  git commit -q --allow-empty -m init
  git update-ref refs/remotes/origin/unrelated-branch HEAD
  run ts_branch_lookup T20260718-300856
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- PR lookup (gh stubbed via TASKID_GH) -------------------------------------

@test "ts_pr_lookup_json returns the stubbed gh JSON verbatim" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo '[{"number":2287,"state":"MERGED","title":"demo","url":"https://x/2287","updatedAt":"2026-07-19T00:00:00Z"}]'
STUB
  run ts_pr_lookup_json T20260629-281129
  [ "$status" -eq 0 ]
  [[ "$output" == *"2287"* ]]
}

@test "ts_render_text prints PR rows without crashing (regression: no backslash-in-f-string)" {
  # Python <3.12 raises SyntaxError on a backslash inside an f-string
  # expression (`f"{p[\"x\"]}"`) — this render path must not use that idiom.
  # A prior version passed the JSON-lookup test above but broke here, since
  # the crash was inside the PRINTING code, not the lookup.
  prs_json='[{"number":2287,"state":"MERGED","title":"add manifest","url":"https://x/2287"}]'
  run ts_render_text "T1" "" "" "" "" "$prs_json" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"#2287 [MERGED] add manifest (https://x/2287)"* ]]
}

@test "ts_pr_lookup_json degrades to an empty array when gh fails" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  run ts_pr_lookup_json T20260629-281129
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# --- end-to-end main (text + json) --------------------------------------------

@test "ts_main text output includes file, status, claimed_by, and no-PR/no-branch markers" {
  mkdir -p dev/TODO
  _mk_task_file dev/TODO/T20260629-281129-demo.md Coding "me:here"
  git commit -q --allow-empty -m init
  run ts_main T20260629-281129
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:     Coding"* ]]
  [[ "$output" == *"claimed_by: me:here"* ]]
  [[ "$output" == *"branches:   (none)"* ]]
  [[ "$output" == *"PRs:        (none)"* ]]
}

@test "ts_main renders the 1-level blocking chain for a Blocked-by status" {
  mkdir -p dev/TODO
  _mk_task_file dev/TODO/T20260629-281129-demo.md "Blocked by T20260718-300856" "" "" "" ""
  _mk_task_file dev/TODO/T20260718-300856-blocker.md Coding "me:here"
  git commit -q --allow-empty -m init
  run ts_main T20260629-281129
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocking chain (1 level):"* ]]
  [[ "$output" == *"T20260718-300856: Coding (claimed_by me:here)"* ]]
}

@test "ts_main --json emits valid JSON with the expected keys" {
  mkdir -p dev/TODO
  _mk_task_file dev/TODO/T20260629-281129-demo.md Coding "me:here"
  git commit -q --allow-empty -m init
  run ts_main T20260629-281129 --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["id"] == "T20260629-281129"
assert d["status"] == "Coding"
assert d["claimed_by"] == "me:here"
assert d["branches"] == []
assert d["prs"] == []
'
}

@test "ts_main on an id not in this repo still runs and reports file (not found)" {
  git commit -q --allow-empty -m init
  run ts_main T99999999-999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"file:       (not found in this repo)"* ]]
}
