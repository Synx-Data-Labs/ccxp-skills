#!/usr/bin/env bats
# Tests for T20261020-242723 — a structural regression guardrail against
# nested-shebang invocation of `_gh/gh.sh` / `_gh/git.sh`.
#
# Context: a suspected macOS kernel memory leak (`data.kalloc.1024` zone) is
# documented to be triggered by a script launching another script via
# IMPLICIT shebang resolution (bare `./script` or `script`, relying on
# PATH + the kernel parsing that script's own `#!` line and re-exec'ing the
# named interpreter) — never by explicit interpreter invocation
# (`bash script`/`sh script`/`source script`), which execs the interpreter
# directly and simply hands it the script as a `$1` argument or reads it
# into the current shell; the kernel's shebang-recursion code path is never
# reached for the invoked script in that case.
#
# T20261020-242723's investigation found `_gh/gh.sh`/`_gh/git.sh`'s entire
# call graph already clean of this pattern: every repo-wide caller uses
# explicit `bash <path> ...`, and the wrappers' own internals either
# `source` each other (a bash builtin — no exec, no shebang parsing at all)
# or exec the real COMPILED `gh`/`git` binaries (no shebang line to parse).
# These tests are the structural guardrail that keeps it that way — they
# fail if a future change reintroduces a bare/implicit invocation.
#
# Scope (mirrors tests/gh-wrapper-usage.bats's own documented scope-cut):
# scans `*.sh` files only — real shell call sites, not SKILL.md prose
# (manually audited by this task's investigation; a generic prose scanner
# would false-positive on doc lines like "`_gh/gh.sh` — gh wrapper that
# ...", which mention the path without invoking it) and not `*.py` (this
# repo's one Python caller, `repo-conventions/scripts/lint_refs.py`'s
# `gh_argv()`, resolves the wrapper into a variable and returns
# `["bash", str(GH_SH)]` — already explicit — so the literal path text it
# touches appears only in docstrings/glob patterns, which a text scanner
# can't reliably distinguish from real Python invocation syntax without a
# real parser; out of proportion for this guardrail, same spirit as the
# SKILL.md scope-cut). Nested-shebang is specifically a *shell* mechanism
# (the kernel re-execing a script's own `#!` line), so `.sh` is where the
# real risk lives.
#
# Lines inside a bash heredoc body (`<<EOF` / `<<'EOF'` / `<<-EOF` ... the
# matching closing delimiter) are skipped — a heredoc's content is DATA fed
# to whatever reads its stdin (e.g. `mode.sh`'s `python3 - <<'PY'` block,
# which embeds a markdown template string that happens to mention
# "`_gh/gh.sh`" as prose for a *different* repo's docs), never itself an
# executed shell statement in the file doing the heredoc. Known limitation:
# a future *bad* bare invocation hidden inside a heredoc body would also be
# invisible to this scanner — an accepted tradeoff for this guardrail's
# scope, not a general-purpose static analyzer.
#
# The scan itself is pure path/text logic (find + grep, no gh/git network
# calls), so it runs directly against both the real repo tree and a
# throwaway fixture tree under $BATS_TEST_TMPDIR.

load test_helper

# _scan_bare_wrapper_invocations <root>
#
# Echoes one "relative/path:lineno:content" per line under <root>'s *.sh
# files (excluding tests/** and the wrappers themselves) that references
# `_gh/gh.sh` or `_gh/git.sh` in a way that is NEITHER:
#   (a) a safe direct invocation — `bash`/`sh`/`source` appears before the
#       path on the same line (e.g. `bash "$HERE/../_gh/gh.sh" "$@"`), nor
#   (b) a safe deferred reference — the path appears only as a quoted
#       string value (a variable assignment, e.g.
#       `wrapper="$DIR/../_gh/gh.sh"`, including one with nested
#       quoting/command substitution as long as nothing meaningful follows
#       the path on the line, e.g.
#       `GH_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../_gh/gh.sh"`), or an
#       `[ -f ...]`/`[ -x ...]` existence test — not itself an invocation;
#       the actual invocation of such a variable happens on a different
#       line, which this scanner catches independently if it's ever bare,
#       nor
#   (c) a comment-only line (first non-whitespace char '#'), nor
#   (d) inside a heredoc body (see the scope note above).
# Empty output means clean.
_scan_bare_wrapper_invocations() {
  local root="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    case "$rel" in
      tests/*) continue ;;
      _gh/gh.sh|_gh/git.sh) continue ;;
    esac
    local lineno=0 heredoc_delim="" line trimmed
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno+1))
      if [ -n "$heredoc_delim" ]; then
        [ "$line" = "$heredoc_delim" ] && heredoc_delim=""
        continue
      fi
      if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
        heredoc_delim="${BASH_REMATCH[1]}"
      fi
      case "$line" in
        *_gh/gh.sh*|*_gh/git.sh*) ;;
        *) continue ;;
      esac
      trimmed="${line#"${line%%[![:space:]]*}"}"
      case "$trimmed" in
        '#'*) continue ;;  # comment-only line
      esac
      # Safe shape 1: explicit bash/sh/source precedes the path on this line.
      if grep -qE '(^|[^A-Za-z0-9_])(bash|sh|source)[[:space:]]+.*_gh/(gh|git)\.sh' <<<"$line"; then
        continue
      fi
      # Safe shape 2: a deferred reference — quoted assignment RHS with no
      # embedded quotes, or an -f/-x existence test — not itself an
      # invocation.
      if grep -qE '="[^"]*_gh/(gh|git)\.sh"|\[[[:space:]]+-[fx][[:space:]]+"[^"]*_gh/(gh|git)\.sh"' <<<"$line"; then
        continue
      fi
      # Safe shape 2b: a deferred reference via a variable-assignment
      # STATEMENT (the whole line is "[local ]NAME=...path...", nothing
      # meaningful trails the path but closing quote/brace/paren
      # punctuation) — covers nested quoting / command substitution in the
      # RHS that shape 2's simple quoted-string match can't parse, e.g.
      # `QP_GH="${QP_GH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_gh/gh.sh}"`.
      if grep -qE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*_gh/(gh|git)\.sh[)}"'"'"']*[[:space:]]*$' <<<"$line"; then
        continue
      fi
      printf '%s:%s:%s\n' "$rel" "$lineno" "$line"
    done < "$f"
  done < <(find "$root" \( -path '*/.git' -o -path '*/.claude/worktrees' \) -prune -o -type f -name '*.sh' -print | sort)
}

# _scan_git_sh_internal_source <file>
#
# Within _gh/git.sh itself (the only wrapper with an internal same-directory
# reference — `source "$_gh_git_dir/gh.sh"`, which textually reads just
# "gh.sh" since the directory is already carried in a variable, so the
# generic `_gh/(gh|git)\.sh` pattern above can't see it): asserts every
# non-comment line referencing bare `gh.sh` is preceded by `source` on that
# same line. Catches a regression like replacing the `source` call with a
# bare/exec'd invocation of the sibling file.
_scan_git_sh_internal_source() {
  local file="$1"
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local lineno="${entry%%:*}" line trimmed
    line="${entry#*:}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;;
    esac
    if grep -qE '(^|[^A-Za-z0-9_])source[[:space:]]+.*gh\.sh' <<<"$line"; then
      continue
    fi
    printf '%s:%s:%s\n' "$file" "$lineno" "$line"
  done < <(grep -nE '(^|[^A-Za-z0-9_])gh\.sh([^A-Za-z0-9_]|$)' "$file" 2>/dev/null)
}

@test "every repo-wide _gh/gh.sh and _gh/git.sh reference is an explicit bash/sh/source invocation or a deferred (variable/test) reference" {
  run _scan_bare_wrapper_invocations "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'bare/implicit wrapper invocation site(s):\n%s\n' "$output" >&2; false; }
}

@test "the known real caller sites are actually present (the scan isn't vacuously passing)" {
  run _scan_bare_wrapper_invocations "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # These assert the scanner is actually looking at real files — a vacuous
  # empty $REPO_ROOT glob would also print nothing, which is NOT the same
  # as "scanned and found everything safe".
  grep -qE '_gh/gh\.sh' "$REPO_ROOT/_session/_lib.sh"
  grep -qE '_gh/gh\.sh' "$REPO_ROOT/_taskid/url.sh"
  grep -qE '_gh/gh\.sh' "$REPO_ROOT/verify-site/scripts/verify.sh"
}

@test "_gh/git.sh's internal pull-in of gh.sh is via source, not a bare/exec'd invocation" {
  run _scan_git_sh_internal_source "$REPO_ROOT/_gh/git.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # And the safe line is actually there (scan isn't vacuous).
  grep -qE '^source "\$_gh_git_dir/gh\.sh"' "$REPO_ROOT/_gh/git.sh"
}

@test "neither _gh/gh.sh nor _gh/git.sh references any OTHER sibling .sh script" {
  # The investigation (T20261020-242723) found gh.sh/git.sh's only
  # subprocess calls are to git/gh/awk/sed/mktemp — no sibling repo script.
  # Guard against a future change quietly adding one via bare invocation:
  # the only non-comment `.sh` reference allowed in either file is git.sh's
  # own `source "$_gh_git_dir/gh.sh"` line.
  # gh.sh: every .sh-referencing line must be a comment.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local line="${entry#*:}" trimmed
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) ;;
      *) echo "unexpected non-comment .sh reference in gh.sh: $entry" >&2; return 1 ;;
    esac
  done < <(grep -nE '\.sh\b' "$REPO_ROOT/_gh/gh.sh")

  # git.sh: every .sh-referencing line must be a comment OR the one known
  # source line.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local line="${entry#*:}" trimmed
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) ;;
      'source "$_gh_git_dir/gh.sh"') ;;
      *) echo "unexpected non-comment .sh reference in git.sh: $entry" >&2; return 1 ;;
    esac
  done < <(grep -nE '\.sh\b' "$REPO_ROOT/_gh/git.sh")
}

@test "a fixture with a bare (no-bash) wrapper invocation is caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-bare"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
"$HERE/../_gh/gh.sh" pr view "$1"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:2:"* ]]
}

@test "a fixture with a ./_gh/git.sh invocation (implicit shebang resolution) is caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-dotslash"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
./_gh/git.sh push -u origin "$1"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:2:"* ]]
}

@test "a fixture with explicit bash invocation of the wrapper passes clean" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-good"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/good.sh" <<'EOF'
#!/usr/bin/env bash
bash "$HERE/../_gh/gh.sh" pr view "$1"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture with a nested-quoting assignment (shape 2b) passes clean" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-nested-assign"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/good.sh" <<'EOF'
#!/usr/bin/env bash
GH_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../_gh/gh.sh"
QP_GH="${QP_GH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/_gh/gh.sh}"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture nested-quoting assignment line that ALSO bare-invokes afterward is still caught" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-nested-assign-bad"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
FOO=1; "$DIR/_gh/gh.sh" "$@"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:2:"* ]]
}

@test "a fixture heredoc body mentioning the wrapper as prose is skipped (not a real invocation)" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-heredoc"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/good.sh" <<'EOF'
#!/usr/bin/env bash
python3 - <<'PY'
TEAM_BLOCK = """
Merge method — via the wrapper `_gh/gh.sh` (no bash prefix mentioned here).
"""
PY
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture bare invocation AFTER a heredoc closes is still caught (heredoc skip doesn't leak past its delimiter)" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-heredoc-then-bad"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
cat <<EOT
some unrelated heredoc body
EOT
"$DIR/_gh/gh.sh" "$@"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"somewhere/bad.sh:5:"* ]]
}

@test ".claude/worktrees/** (nested agent worktree checkouts) are excluded from the scan" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-worktrees"
  mkdir -p "$FIXTURE_ROOT/.claude/worktrees/agent-xyz/somewhere"
  cat > "$FIXTURE_ROOT/.claude/worktrees/agent-xyz/somewhere/bad.sh" <<'EOF'
#!/usr/bin/env bash
"$DIR/_gh/gh.sh" "$@"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture with a deferred variable reference (assigned, then invoked via bash elsewhere) passes clean" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-deferred"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/good.sh" <<'EOF'
#!/usr/bin/env bash
wrapper="$DIR/../_gh/gh.sh"
if [ -f "$wrapper" ]; then
  bash "$wrapper" "$@"
fi
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture -x existence test on the wrapper path alone (no bare invocation) passes clean" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-test-only"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/good.sh" <<'EOF'
#!/usr/bin/env bash
if [ -x "$DIR/../_gh/gh.sh" ]; then
  bash "$DIR/../_gh/gh.sh" "$@"
fi
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a comment-only mention of a bare wrapper invocation is not treated as a call site" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-comment"
  mkdir -p "$FIXTURE_ROOT/somewhere"
  cat > "$FIXTURE_ROOT/somewhere/doc.sh" <<'EOF'
#!/usr/bin/env bash
# do NOT do: "$DIR/_gh/gh.sh" "$@"  (bare — triggers kernel shebang parsing)
bash "$DIR/_gh/gh.sh" "$@"
EOF

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the wrappers' own tests/ directory and the wrapper files themselves are excluded from the scan" {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/fixture-excluded"
  mkdir -p "$FIXTURE_ROOT/tests" "$FIXTURE_ROOT/_gh"
  printf '#!/usr/bin/env bash\n"$DIR/_gh/gh.sh" "$@"\n' > "$FIXTURE_ROOT/tests/fake.bats.sh"
  printf '#!/usr/bin/env bash\n# _gh/gh.sh self-reference, excluded by name\n"$DIR/gh.sh" "$@"\n' > "$FIXTURE_ROOT/_gh/gh.sh"
  printf '#!/usr/bin/env bash\nsource "$DIR/gh.sh"\n' > "$FIXTURE_ROOT/_gh/git.sh"

  run _scan_bare_wrapper_invocations "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a fixture git.sh-style file exec'ing gh.sh bare (not via source) is caught by the internal-source check" {
  FIXTURE_FILE="$BATS_TEST_TMPDIR/bad-git.sh"
  cat > "$FIXTURE_FILE" <<'EOF'
#!/usr/bin/env bash
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$_dir/gh.sh"
EOF

  run _scan_git_sh_internal_source "$FIXTURE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bad-git.sh:3:"* ]]
}

@test "a fixture git.sh-style file sourcing gh.sh passes the internal-source check clean" {
  FIXTURE_FILE="$BATS_TEST_TMPDIR/good-git.sh"
  cat > "$FIXTURE_FILE" <<'EOF'
#!/usr/bin/env bash
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_dir/gh.sh"
EOF

  run _scan_git_sh_internal_source "$FIXTURE_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
