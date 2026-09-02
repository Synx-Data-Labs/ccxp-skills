#!/usr/bin/env bats
# Tests for repo-conventions/scripts/lint_refs.py — the CLI-level, gh-stubbed
# integration coverage (pure regex/replacement logic is unit-tested in
# repo-conventions/scripts/test_lint_refs.py). Covers: issue-vs-PR type
# correction against a stubbed `gh api` response, fenced-code-block skip,
# and a cross-repo (unresolvable) T-id being left bare — per T20260616-130977's
# test plan.
#
# gh is stubbed via two DI seams so both resolution paths (T-id -> issue via
# _taskid/url.sh's TASKID_GH, typed #N -> gh api via LINT_REFS_GH) hit the
# same fixture: no real network calls, hermetic like taskid_url.bats.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINT_REFS_PY="$REPO_ROOT/repo-conventions/scripts/lint_refs.py"

  cd "$BATS_TEST_TMPDIR"
  git init -q .
  git remote add origin https://github.com/your-org/ccxp-skills.git
  mkdir -p dev/TODO dev/JOURNAL bin

  # gh stub: `issue list --search "<id> in:title,body" --json number --jq ...`
  # prints just the resolved number (or nothing) — same contract the real gh
  # invocation's --jq filter would produce. `api repos/.../issues/<n>` prints
  # the issue JSON, tagged with pull_request when <n> is actually a PR.
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  for i in "$@"; do
    if [ "$prev" = "--search" ]; then search="$i"; fi
    prev="$i"
  done
  case "$search" in
    *T20260611-000001*) echo 900 ;;
    *) ;;  # no match -> unresolvable (simulates a cross-repo T-id)
  esac
  exit 0
elif [ "$1" = "api" ]; then
  case "$2" in
    */issues/250) echo '{"number":250,"pull_request":{"url":"x"}}' ;;
    */issues/99) echo '{"number":99}' ;;
    *) echo '{}' ;;
  esac
  exit 0
fi
exit 1
STUB
  chmod +x bin/gh
  export TASKID_GH="$BATS_TEST_TMPDIR/bin/gh"
  export LINT_REFS_GH="$BATS_TEST_TMPDIR/bin/gh"
}

run_lint_refs() {
  python3 "$LINT_REFS_PY" "$@"
}

@test "typed 'issue #N' is corrected to PR when gh api says it's a pull request" {
  cat > dev/TODO/T20260611-000002-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000002: Demo

See issue #250 for context.
EOF
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF '[PR #250](https://github.com/your-org/ccxp-skills/pull/250)' dev/TODO/T20260611-000002-demo.md
  ! grep -q 'issue #250' dev/TODO/T20260611-000002-demo.md
}

@test "typed 'PR #N' resolves to an issue link when gh api says it's a plain issue" {
  cat > dev/TODO/T20260611-000003-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000003: Demo

Fixed by PR #99.
EOF
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF '[issue #99](https://github.com/your-org/ccxp-skills/issues/99)' dev/TODO/T20260611-000003-demo.md
}

@test "a typed ref inside a fenced code block is left untouched" {
  cat > dev/TODO/T20260611-000004-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000004: Demo

```
grep PR #250 somewhere
```
EOF
  cp dev/TODO/T20260611-000004-demo.md "$BATS_TEST_TMPDIR/lint_refs_before.md"
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  diff "$BATS_TEST_TMPDIR/lint_refs_before.md" dev/TODO/T20260611-000004-demo.md
}

@test "an unresolvable (cross-repo) T-id is left bare, not linked to a fallback search URL" {
  cat > dev/TODO/T20260611-000005-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000005: Demo

Blocked by T20260601-999999 in another repo.
EOF
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF 'Blocked by T20260601-999999 in another repo.' dev/TODO/T20260611-000005-demo.md
  ! grep -q 'search?q=' dev/TODO/T20260611-000005-demo.md
}

@test "a resolvable T-id links to the stable issue-mirror URL" {
  cat > dev/TODO/T20260611-000006-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000006: Demo

See T20260611-000001 for the mapping mechanism.
EOF
  touch dev/TODO/T20260611-000001-other.md
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF '[T20260611-000001](https://github.com/your-org/ccxp-skills/issues/900)' dev/TODO/T20260611-000006-demo.md
}

@test "read-only mode (no --fix) exits non-zero when a linkable ref is unlinked" {
  cat > dev/TODO/T20260611-000007-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000007: Demo

Fixed by PR #99.
EOF
  run run_lint_refs --all .
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlinked reference"* ]]
  ! grep -q '\[issue #99\]' dev/TODO/T20260611-000007-demo.md
}

@test "read-only mode exits 0 when nothing is unlinked" {
  cat > dev/TODO/T20260611-000008-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000008: Demo

Nothing to link here.
EOF
  run run_lint_refs --all .
  [ "$status" -eq 0 ]
}

@test "a typed ref with no per-line qualifier is still left bare when the file's own target-repo is different" {
  # this fixture repo's own origin is ccxp-skills (see setup()) -- declare a
  # DIFFERENT target-repo so the two don't coincidentally match.
  cat > dev/TODO/T20260611-000013-demo.md <<'EOF'
---
status: Done
estimation: 2h
target-repo: 'your-org/hub-repo'
---

# T20260611-000013: Demo

Today PR #134 landed the fix.
EOF
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF 'Today PR #134 landed the fix.' dev/TODO/T20260611-000013-demo.md
  ! grep -q 'ccxp-skills/pull/134' dev/TODO/T20260611-000013-demo.md
}

@test "a typed ref qualified with a different repo's name is left bare, not linked to the wrong repo" {
  cat > dev/TODO/T20260611-000010-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000010: Demo

Shipped as example-website.com PR #39 last week.
EOF
  export KNOWN_SIBLING_REPOS="example-website.com"
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF 'Shipped as example-website.com PR #39 last week.' dev/TODO/T20260611-000010-demo.md
  ! grep -q 'hub-repo/pull/39' dev/TODO/T20260611-000010-demo.md
}

@test "a wiki-style [[T-id]] ref is not corrupted into a nested link" {
  cat > dev/TODO/T20260611-000011-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000011: Demo

See [[T20260611-000001]] for background.
EOF
  touch dev/TODO/T20260611-000001-other.md
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF 'See [[T20260611-000001]] for background.' dev/TODO/T20260611-000011-demo.md
}

@test "a T-id embedded in a bare filename is not spliced into the path" {
  cat > dev/TODO/T20260611-000012-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000012: Demo

Merged into dev/JOURNAL/2026-06-09-T20260611-000001-some-slug.md already.
EOF
  touch dev/TODO/T20260611-000001-other.md
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  grep -qF 'Merged into dev/JOURNAL/2026-06-09-T20260611-000001-some-slug.md already.' dev/TODO/T20260611-000012-demo.md
}

@test "fixing a file's own H1 self-reference doesn't break lint_tasks.py's structural check" {
  cat > dev/TODO/T20260611-000001-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000001: Demo

See T20260611-000001 again in the body, plus a PR #99.
EOF
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  head -8 dev/TODO/T20260611-000001-demo.md | grep -qxF '# T20260611-000001: Demo'
  grep -qF '[T20260611-000001](https://github.com/your-org/ccxp-skills/issues/900) again' dev/TODO/T20260611-000001-demo.md
  run python3 "$REPO_ROOT/repo-conventions/scripts/lint_tasks.py" --all .
  [ "$status" -eq 0 ]
}

@test "running --fix twice produces no further diff (idempotent)" {
  cat > dev/TODO/T20260611-000009-demo.md <<'EOF'
---
status: Open
estimation: 1h
---

# T20260611-000009: Demo

Fixed by PR #250, tracked as T20260611-000001.
EOF
  touch dev/TODO/T20260611-000001-other.md
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  cp dev/TODO/T20260611-000009-demo.md "$BATS_TEST_TMPDIR/lint_refs_after_first.md"
  run run_lint_refs --fix --all .
  [ "$status" -eq 0 ]
  diff "$BATS_TEST_TMPDIR/lint_refs_after_first.md" dev/TODO/T20260611-000009-demo.md
}
