#!/usr/bin/env bats
# Tests for the caller-side `GH_TOKEN=`/`GITHUB_TOKEN=` allowlist check
# (T20260925-219021).
#
# Context: `_gh/gh.sh`/`_gh/git.sh` are the only sanctioned way to call
# `gh`/authenticated `git` — they pick the right account and set a
# process-scoped `GH_TOKEN` internally. A script that instead sets
# `GH_TOKEN=` (or `GITHUB_TOKEN=` — `gh` honors either) itself before
# shelling out bypasses that account-picking (the exact bug
# `_session/_lib.sh`'s wrapper-present branch had — fixed alongside this
# test, same task). Both names are checked in every form this repo's
# shell/Python sources actually use to set an env var: a shell
# assignment, a Python dict literal (either quote style), a subscript
# assignment (`os.environ[...] = ...`), or `os.putenv(...)` — a check
# that only caught one spelling would give false confidence (caught by
# independent review of PR #175, 2026-09-29). Three sites are documented,
# deliberate exceptions, not violations:
#   - `ccxp/scripts/epic-status.sh` (5 sites) — cross-repo reads against
#     `$ROADMAP_TARGET_REPO`, a different repo than `$PWD`; `gh.sh main()`
#     has no `--repo` override, so this script sources `gh.sh` for its
#     account-picking primitives directly instead (see its own header).
#   - `_session/_lib.sh`'s no-wrapper CI-only fallback line — a GHA runner
#     sparse-cloning just `_session/` has exactly one token and no account
#     ambiguity.
#   - `actions/sync-tasks/sync.py`'s `env = {**os.environ, "GH_TOKEN": TOKEN}`
#     — a GHA-runner-only, keyring-less exception.
#
# Scope: this checks the caller-side-`GH_TOKEN=`-assignment half of the
# Problem statement only (see the task's Alternatives rejected for why a
# general bare-`gh`-call detector is out of scope).
#
# The scan itself (_scan_gh_token_sites) is pure path/text logic (find + grep
# + a comment-line filter) — no `gh`/git network calls, so it runs directly
# against both the real repo tree and a throwaway fixture tree under
# $BATS_TEST_TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# _scan_gh_token_sites <root>
#
# Echoes one "relative/path:lineno:content" per caller-side `GH_TOKEN=`/
# `GITHUB_TOKEN=` (shell — `gh` honors both, _session/_lib.sh's own
# comment says so) or a Python assignment of either name — dict-literal
# (`"GH_TOKEN":`/`'GH_TOKEN':`), subscript (`os.environ["GH_TOKEN"] =`),
# or `os.putenv("GH_TOKEN", ...)` — under <root>'s *.sh/*.py files,
# excluding:
#   - tests/**, dev/JOURNAL/**, dev/TODO/** (fixtures/journal prose/task
#     prose, not real callers)
#   - _gh/gh.sh, _gh/git.sh (the wrappers themselves — they set GH_TOKEN
#     internally on purpose; that's their whole job)
#   - comment-only lines (first non-whitespace char '#') — a doc comment
#     that merely MENTIONS the pattern (e.g. epic-status.sh's own header
#     explaining why it does this) isn't itself a call site.
# Empty output means clean. Pure directory-tree logic (`find`/`grep`, no
# git), so it works against a plain fixture tree with no `.git` too.
_scan_gh_token_sites() {
  local root="$1" f rel line lineno content trimmed
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    case "$rel" in
      tests/*|dev/JOURNAL/*|dev/TODO/*) continue ;;
      _gh/gh.sh|_gh/git.sh) continue ;;
    esac
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      lineno="${line%%:*}"
      content="${line#*:}"
      trimmed="${content#"${content%%[![:space:]]*}"}"
      case "$trimmed" in
        '#'*) continue ;;
      esac
      printf '%s:%s:%s\n' "$rel" "$lineno" "$content"
    done < <(grep -nE "(GH_TOKEN|GITHUB_TOKEN)=|[\"'](GH_TOKEN|GITHUB_TOKEN)[\"']:|os\.environ\[[\"'](GH_TOKEN|GITHUB_TOKEN)[\"']\][[:space:]]*=|os\.putenv\([\"'](GH_TOKEN|GITHUB_TOKEN)[\"']" "$f" 2>/dev/null)
  done < <(find "$root" -type f \( -name '*.sh' -o -name '*.py' \) | sort)
}

@test "the repo's only caller-side GH_TOKEN= sites are the three allowlisted ones" {
  run _scan_gh_token_sites "$REPO_ROOT"
  [ "$status" -eq 0 ]

  local bad=""
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    case "$hit" in
      ccxp/scripts/epic-status.sh:*) ;;
      _session/_lib.sh:*) ;;
      actions/sync-tasks/sync.py:*) ;;
      *) bad="$bad
$hit" ;;
    esac
  done <<< "$output"

  [ -z "$bad" ] || { printf 'unauthorized GH_TOKEN= site(s):%s\n' "$bad" >&2; false; }
}

@test "every allowlisted site is actually present (the allowlist isn't vacuously satisfied)" {
  run _scan_gh_token_sites "$REPO_ROOT"
  [ "$status" -eq 0 ]

  local n
  n="$(printf '%s\n' "$output" | grep -c '^ccxp/scripts/epic-status\.sh:')"
  [ "$n" -eq 5 ]
  n="$(printf '%s\n' "$output" | grep -c '^_session/_lib\.sh:')"
  [ "$n" -eq 1 ]
  n="$(printf '%s\n' "$output" | grep -c '^actions/sync-tasks/sync\.py:')"
  [ "$n" -eq 1 ]
}

@test "a fixture with a new unauthorized GH_TOKEN= assignment fails the check" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
tok="$(gh auth token)"
GH_TOKEN="$tok" gh pr view "$1"
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:3:"* ]]
}

@test "a fixture Python dict-literal GH_TOKEN assignment is also caught outside the allowlist" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-py"
  mkdir -p "$FIXTURE_ROOT/scripts"
  cat > "$FIXTURE_ROOT/scripts/bad.py" <<'EOF'
import os, subprocess
env = {**os.environ, "GH_TOKEN": os.environ["SOME_OTHER_TOKEN"]}
subprocess.run(["gh", "pr", "view"], env=env)
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/bad.py:2:"* ]]
}

@test "a fixture GITHUB_TOKEN= shell assignment is caught outside the allowlist" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-githubtoken"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
GITHUB_TOKEN="$(gh auth token --user someuser)" gh pr view "$1"
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:2:"* ]]
}

@test "a fixture Python single-quoted dict-literal GH_TOKEN assignment is caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-py-singlequote"
  mkdir -p "$FIXTURE_ROOT/scripts"
  cat > "$FIXTURE_ROOT/scripts/bad.py" <<'EOF'
import os, subprocess
env = {**os.environ, 'GH_TOKEN': os.environ['SOME_OTHER_TOKEN']}
subprocess.run(["gh", "pr", "view"], env=env)
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/bad.py:2:"* ]]
}

@test "a fixture os.environ subscript-assignment GH_TOKEN/GITHUB_TOKEN is caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-py-subscript"
  mkdir -p "$FIXTURE_ROOT/scripts"
  cat > "$FIXTURE_ROOT/scripts/bad.py" <<'EOF'
import os, subprocess
os.environ["GH_TOKEN"] = os.environ["SOME_OTHER_TOKEN"]
os.environ['GITHUB_TOKEN'] = os.environ['SOME_OTHER_TOKEN']
subprocess.run(["gh", "pr", "view"])
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/bad.py:2:"* ]]
  [[ "$output" == *"scripts/bad.py:3:"* ]]
}

@test "a fixture os.putenv GH_TOKEN/GITHUB_TOKEN is caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-py-putenv"
  mkdir -p "$FIXTURE_ROOT/scripts"
  cat > "$FIXTURE_ROOT/scripts/bad.py" <<'EOF'
import os, subprocess
os.putenv("GH_TOKEN", os.environ["SOME_OTHER_TOKEN"])
os.putenv('GITHUB_TOKEN', os.environ['SOME_OTHER_TOKEN'])
subprocess.run(["gh", "pr", "view"])
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/bad.py:2:"* ]]
  [[ "$output" == *"scripts/bad.py:3:"* ]]
}

@test "GH_TOKEN= sites under tests/, dev/JOURNAL/, dev/TODO/, or the wrapper scripts are correctly excluded" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-excluded"
  mkdir -p "$FIXTURE_ROOT/tests" "$FIXTURE_ROOT/dev/JOURNAL" "$FIXTURE_ROOT/dev/TODO" "$FIXTURE_ROOT/_gh"
  printf '#!/usr/bin/env bash\nGH_TOKEN="$tok" gh pr view\n' > "$FIXTURE_ROOT/tests/fake.sh"
  printf '#!/usr/bin/env bash\nGH_TOKEN="$tok" gh pr view\n' > "$FIXTURE_ROOT/dev/JOURNAL/note.sh"
  printf '#!/usr/bin/env bash\nGH_TOKEN="$tok" gh pr view\n' > "$FIXTURE_ROOT/dev/TODO/note.sh"
  printf '#!/usr/bin/env bash\nGH_TOKEN="$tok" gh pr view\n' > "$FIXTURE_ROOT/_gh/gh.sh"
  printf '#!/usr/bin/env bash\nGH_TOKEN="$tok" exec git "$@"\n' > "$FIXTURE_ROOT/_gh/git.sh"

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a comment-only mention of GH_TOKEN= is not treated as a call site" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-repo-comment"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/doc.sh" <<'EOF'
#!/usr/bin/env bash
# explains why this file invokes `GH_TOKEN=... gh api ...` below (comment only)
gh pr view "$1"
EOF

  run _scan_gh_token_sites "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
