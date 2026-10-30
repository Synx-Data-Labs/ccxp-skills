#!/usr/bin/env bash
# tests/test_helper.bash — shared BATS setup, `load`ed by test files across
# tests/, _docs/, and _slack/ (T20261016-316464).
#
# Before this file existed, the suite had zero shared helper: every file
# recomputed its own REPO_ROOT, many hand-rolled the same throwaway
# git-fixture-repo bootstrap, a few shadowed `gh`/`git` with a fixture binary
# via an identical PATH-shim ceremony, and a few isolated CLAIMANT_STATE_DIR
# the same way. This file centralizes those shapes so a future change to any
# of them touches one file instead of N. Pure DRY extraction — no assertion
# or behavior change for any caller.
#
# Not every file with a superficially similar pattern was converted to use
# these helpers — see the task file (dev/JOURNAL or dev/TODO,
# T20261016-316464) for the two deliberate exclusions and why forcing them
# through a shared helper would have been a correctness risk, not a cleanup.

# REPO_ROOT — every test file needs the repo root. $BATS_TEST_DIRNAME is set
# by bats before `load` runs the body of this file, and every .bats file in
# this repo lives exactly one directory below the repo root (tests/, _docs/,
# _slack/), so this resolves correctly regardless of which of those a given
# test file lives in.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO_ROOT

# git_identity <dir> [email] [name]
# Sets a deterministic git identity on an already-`git init`'d repo at <dir>,
# and disables commit signing so a host's global `commit.gpgsign=true`
# can never make a test's commit hang or fail. Replaces the
# `git config user.email` + `git config user.name` (+, where present,
# `git config commit.gpgsign false`) pair/triple duplicated across the
# suite's git-fixture setups. Deliberately does NOT run `git init` itself —
# callers vary on init flags (bare vs normal, `-b <branch>`, trailing `.`)
# and keep that line inline.
git_identity() {
  local dir="$1" email="${2:-t@example.com}" name="${3:-tester}"
  git -C "$dir" config user.email "$email"
  git -C "$dir" config user.name "$name"
  git -C "$dir" config commit.gpgsign false
}

# use_fake_bin <fixture-script> <binary-name>
# Copies <fixture-script> onto a fresh, PATH-prepended directory as
# <binary-name>, so it shadows the real binary for the rest of the test.
# Safe to call more than once per test (each call reuses the same
# $BATS_TEST_TMPDIR/fakebin directory and just adds another binary to it) —
# exactly what git.bats needs for both a fake `gh` and a fake `git`.
use_fake_bin() {
  local fixture="$1" name="$2"
  FAKEBIN="${FAKEBIN:-$BATS_TEST_TMPDIR/fakebin}"
  mkdir -p "$FAKEBIN"
  cp "$fixture" "$FAKEBIN/$name"
  chmod +x "$FAKEBIN/$name"
  export FAKEBIN
  case ":$PATH:" in
    *":$FAKEBIN:"*) ;;  # already on PATH from an earlier call this test
    *) export PATH="$FAKEBIN:$PATH" ;;
  esac
}

# isolate_claimant_state [subdir]
# Points CLAIMANT_STATE_DIR at a throwaway directory under
# $BATS_TEST_TMPDIR so claim-identity tests never read the developer's real
# state or write outside the sandbox. [subdir] defaults to "claimant-state";
# pass a different name only when a test also needs a second, distinct
# state dir in the same file.
isolate_claimant_state() {
  export CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/${1:-claimant-state}"
}

# ---------------------------------------------------------------------------
# Shared fakes for skill-script tests (Phase 0 of the scripts-backed-skills
# plan). Everything below is offline: no network, no real clock, no ssh/gpg.
# Reuses $FAKEBIN / use_fake_bin's PATH-prepend convention.
# ---------------------------------------------------------------------------

# _fakebin_dir — ensure the shared PATH-prepended fake-binary directory exists.
_fakebin_dir() {
  FAKEBIN="${FAKEBIN:-$BATS_TEST_TMPDIR/fakebin}"
  mkdir -p "$FAKEBIN"
  export FAKEBIN
  case ":$PATH:" in
    *":$FAKEBIN:"*) ;;
    *) export PATH="$FAKEBIN:$PATH" ;;
  esac
}

# make_fixture_repo [dir] [-- queue-entry...]
# Throwaway git repo on branch `main` with a deterministic identity, the
# dev/TODO layout and an empty-but-valid dev/TODO/queue.md, one initial
# commit. Prints the repo path (default $BATS_TEST_TMPDIR/repo) and leaves the
# caller's cwd alone. Extra args after `--` are appended verbatim as queue
# lines (without `--` they are ignored), e.g. make_fixture_repo "$d" -- '- [T20250101-000001](a.md): A'.
make_fixture_repo() {
  local dir="${1:-$BATS_TEST_TMPDIR/repo}"
  [ "${1:-}" = "--" ] && dir="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$dir/dev/TODO" "$dir/dev/JOURNAL"
  git -C "$dir" init -q -b main
  git_identity "$dir"
  printf '# TODO Queue\n\nOrdered priority queue. Top = highest priority. One line per task.\n\n' \
    > "$dir/dev/TODO/queue.md"
  local seen=0 arg
  for arg in "$@"; do
    if [ "$seen" = 1 ]; then printf '%s\n' "$arg" >> "$dir/dev/TODO/queue.md"; fi
    [ "$arg" = "--" ] && seen=1
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "init"
  printf '%s\n' "$dir"
}

# fake_gh <fixtures-dir>
# Installs a `gh` shim on PATH. Every invocation:
#   1. forced failure: when the argv line matches the extended regex in
#      $FAKE_GH_FAIL it logs "FAILED <argv>" and exits 1 (simulates a gh/API
#      failure for that call);
#   2. otherwise a call that is served is logged as the bare argv line
#      (space-joined, quoting is not preserved) to $FAKE_GH_LOG;
#   3. otherwise prints <fixtures-dir>/<key>.json (or .txt) to stdout, where
#      <key> is the argv with every run of non-[A-Za-z0-9] characters collapsed
#      to `_` (so `gh pr list --state open` -> `pr_list_state_open`), and
#      exits with the contents of <key>.rc if present (default 0);
#   4. an unmapped argv exits 97 and logs "UNMAPPED <argv>" so a test can never
#      pass by silently hitting nothing. Failed and unmapped calls are never
#      logged as bare argv, so assert_calls '^pr merge' cannot pass on a call
#      that did not succeed; assert '^FAILED pr merge' to check an attempt.
# When FAKE_GH_STDIN=1 a served call's stdin is appended to "$FAKE_GH_LOG.stdin"
# (e.g. `gh pr comment --body-file -`); otherwise stdin is never read, because an
# inherited, never-closed stdin would hang the test.
# A fixture may also be a prefix match: <fixtures-dir>/<key-prefix>.json is
# used when no exact key exists and the prefix is the longest that matches.
fake_gh() {
  local fixtures="$1"
  _fakebin_dir
  export FAKE_GH_FIXTURES="$fixtures"
  export FAKE_GH_LOG="${FAKE_GH_LOG:-$BATS_TEST_TMPDIR/gh-calls.log}"
  : > "$FAKE_GH_LOG"
  cat > "$FAKEBIN/gh" <<'SHIM'
#!/usr/bin/env bash
line="$*"
if [ -n "${FAKE_GH_FAIL:-}" ] && printf '%s' "$line" | grep -Eq -- "$FAKE_GH_FAIL"; then
  echo "FAILED $line" >> "$FAKE_GH_LOG"
  echo "fake gh: forced failure for: $line" >&2
  exit 1
fi
key="$(printf '%s' "$line" | sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//')"
best=""
for f in "$FAKE_GH_FIXTURES"/*.json "$FAKE_GH_FIXTURES"/*.txt; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"; base="${base%.*}"
  case "$key" in
    "$base"|"$base"_*) [ "${#base}" -gt "${#best}" ] && best="$base" && bestfile="$f" ;;
  esac
done
if [ -z "$best" ]; then
  echo "fake gh: UNMAPPED invocation: $line (key: $key)" >&2
  echo "UNMAPPED $line" >> "$FAKE_GH_LOG"
  exit 97
fi
printf '%s\n' "$line" >> "$FAKE_GH_LOG"
if [ "${FAKE_GH_STDIN:-0}" = 1 ]; then cat >> "$FAKE_GH_LOG.stdin"; fi
cat "$bestfile"
if [ -f "$FAKE_GH_FIXTURES/$best.rc" ]; then exit "$(cat "$FAKE_GH_FIXTURES/$best.rc")"; fi
exit 0
SHIM
  chmod +x "$FAKEBIN/gh"
}

# fake_claude [stdout-text]
# Installs a `claude` shim that logs its argv to $FAKE_CLAUDE_LOG (stdin is
# captured to "$FAKE_CLAUDE_LOG.stdin" only when FAKE_CLAUDE_STDIN=1, because
# reading an inherited, never-closed stdin would hang the test) and prints $FAKE_CLAUDE_OUTPUT
# (default: the optional argument, else "ok"). Exit status: $FAKE_CLAUDE_RC.
fake_claude() {
  _fakebin_dir
  export FAKE_CLAUDE_OUTPUT="${1:-${FAKE_CLAUDE_OUTPUT:-ok}}"
  export FAKE_CLAUDE_LOG="${FAKE_CLAUDE_LOG:-$BATS_TEST_TMPDIR/claude-calls.log}"
  : > "$FAKE_CLAUDE_LOG"
  cat > "$FAKEBIN/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"
if [ "${FAKE_CLAUDE_STDIN:-0}" = 1 ]; then cat >> "$FAKE_CLAUDE_LOG.stdin"; fi
printf '%s\n' "$FAKE_CLAUDE_OUTPUT"
exit "${FAKE_CLAUDE_RC:-0}"
SHIM
  chmod +x "$FAKEBIN/claude"
}

# pin_now <ISO-8601-UTC>   e.g. pin_now 2026-10-30T12:00:00Z
# Exports NOW (and NOW_EPOCH) and installs a `date` shim so `date`,
# `date -u`, `date +FMT` and `date -u +FMT` report the pinned instant.
# Any other form (date -d ..., date -v ..., date -r ..., date -I, --iso-8601)
# passes straight through to the REAL date, so GNU and BSD arithmetic keep
# working but those forms see the real clock: scripts under test should take
# their date via `date +FMT` or honor $NOW.
# Scripts that take their own clock should honor $NOW; the shim covers the
# ones that do not.
pin_now() {
  local iso="$1" real epoch
  real="$(command -v date)"
  epoch="$("$real" -u -d "$iso" +%s 2>/dev/null \
    || "$real" -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s)"
  _fakebin_dir
  export NOW="$iso" NOW_EPOCH="$epoch" REAL_DATE="$real"
  cat > "$FAKEBIN/date" <<'SHIM'
#!/usr/bin/env bash
utc=""; fmt=""; extra=0
for a in "$@"; do
  case "$a" in
    -u) utc=-u ;;
    +*) fmt="$a" ;;
    *) extra=1 ;;
  esac
done
if [ "$extra" = 1 ]; then exec "$REAL_DATE" "$@"; fi
if "$REAL_DATE" -u -d "@$NOW_EPOCH" +%s >/dev/null 2>&1; then
  exec "$REAL_DATE" $utc -d "@$NOW_EPOCH" ${fmt:+"$fmt"}
fi
exec "$REAL_DATE" $utc -r "$NOW_EPOCH" ${fmt:+"$fmt"}
SHIM
  chmod +x "$FAKEBIN/date"
}

# assert_calls <log> <extended-regex>
# Passes when some line of <log> matches; otherwise prints the log and fails.
assert_calls() {
  if ! grep -Eq -- "$2" "$1" 2>/dev/null; then
    echo "expected a call matching /$2/ in $1; got:" >&2
    cat "$1" >&2 2>/dev/null || echo "(no log)" >&2
    return 1
  fi
}

# refute_calls <log> <extended-regex> — the negation (also passes on no log).
refute_calls() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then
    echo "unexpected call matching /$2/ in $1:" >&2
    cat "$1" >&2
    return 1
  fi
}
