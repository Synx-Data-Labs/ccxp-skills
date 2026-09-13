#!/usr/bin/env bats
# Tests for quality-probe/scripts/probe.sh — the record+warn code-metrics probe
# (T20260609-204303 D2).
#
# The probe measures quality on a task's TOUCHED files and appends one record
# per task to an append-only scoreboard dev/quality/metrics.jsonl in the TARGET
# repo. Posture: record + warn, NEVER block — a missing tool records that field
# as null and logs a skip note to stderr, and the probe always exits 0 except on
# usage / IO errors.
#
# Pure parse functions (fed mock tool output on stdin) are tested directly by
# sourcing probe.sh. The tool-runner skip path stubs the tool off PATH.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE="$REPO_ROOT/quality-probe/scripts/probe.sh"
FIX="$SCRIPT_DIR/fixtures/quality-probe"

setup() {
  # A PATH-stub dir that symlinks ONLY the core utilities the probe needs
  # (bash, jq, awk, mktemp, …) but NOT the optional scanners (shellcheck,
  # jscpd, gitleaks, kcov). Running with PATH=$STUB_BIN therefore makes every
  # scanner appear "missing" while the script itself still runs — the exact
  # condition the skip path must handle.
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  local tool src
  for tool in bash sh jq awk gawk sed grep mktemp cat tail printf env rm mkdir dirname coreutils head wc; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$STUB_BIN/$tool"
  done
  # Build an isolated target repo so metrics.jsonl writes never touch the source.
  TARGET="$BATS_TEST_TMPDIR/target"
  mkdir -p "$TARGET"
}

# Helper: source the probe (side-effect-free; CLI runs only under the guard).
_load() { source "$PROBE"; }

# Helper: the last (appended) record line of the target scoreboard — a single
# clean JSON object, unmixed with the human summary / skip notes on stdout.
_last_record() { tail -n 1 "$TARGET/dev/quality/metrics.jsonl"; }

# ---------------------------------------------------------------------------
# Sourceable / structure
# ---------------------------------------------------------------------------

@test "probe.sh exists" {
  [ -f "$PROBE" ]
}

@test "probe.sh is sourceable without executing its main (function-wrapped)" {
  run bash -c "source '$PROBE'; type quality-probe >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# qp-shellcheck — parse `shellcheck -f gcc` output into severity counts
# ---------------------------------------------------------------------------

@test "qp-shellcheck parses gcc output into error/warning/info/style counts" {
  _load
  run bash -c "source '$PROBE'; qp-shellcheck < '$FIX/shellcheck-gcc.txt'"
  [ "$status" -eq 0 ]
  # gcc format: 1 error, 2 warnings, 1 note (note maps to info; style absent).
  [ "$output" = "1 2 1 0" ]
}

@test "qp-shellcheck reports all-zero on empty (clean) input" {
  _load
  run bash -c "source '$PROBE'; printf '' | qp-shellcheck"
  [ "$status" -eq 0 ]
  [ "$output" = "0 0 0 0" ]
}

# ---------------------------------------------------------------------------
# qp-size — pure bash/awk LOC + max function line count over touched *.sh
# ---------------------------------------------------------------------------

@test "qp-size computes file_loc and max_fn_lines over touched .sh files" {
  _load
  # touched.sh is 13 physical lines; its one function spans 6 lines (6..11).
  run bash -c "source '$PROBE'; qp-size '$FIX/touched.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "13 6" ]
}

@test "qp-size sums LOC across multiple files and keeps the max function span" {
  _load
  run bash -c "source '$PROBE'; qp-size '$FIX/touched.sh' '$FIX/touched.sh'"
  [ "$status" -eq 0 ]
  # 13 + 13 = 26 LOC; max single-function span is still 6.
  [ "$output" = "26 6" ]
}

# ---------------------------------------------------------------------------
# qp-dup — parse jscpd JSON for the duplication percentage
# ---------------------------------------------------------------------------

@test "qp-dup parses the duplication percentage from jscpd JSON" {
  _load
  run bash -c "source '$PROBE'; qp-dup < '$FIX/jscpd-report.json'"
  [ "$status" -eq 0 ]
  [ "$output" = "3.1" ]
}

# ---------------------------------------------------------------------------
# qp-secrets — count gitleaks findings
# ---------------------------------------------------------------------------

@test "qp-secrets counts gitleaks findings" {
  _load
  run bash -c "source '$PROBE'; qp-secrets < '$FIX/gitleaks-report.json'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "qp-secrets reports 0 for an empty findings array" {
  _load
  run bash -c "source '$PROBE'; printf '[]' | qp-secrets"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# qp-code-scanning — count OPEN alerts by severity, filtered to touched paths
# ---------------------------------------------------------------------------

@test "qp-code-scanning counts open alerts on touched files by severity" {
  _load
  # Alerts fixture: open error+warning on scripts/foo.sh (touched), open error
  # on scripts/untouched.sh (excluded), and a fixed alert on foo.sh (excluded).
  run bash -c "source '$PROBE'; qp-code-scanning 'scripts/foo.sh' < '$FIX/code-scanning-alerts.json'"
  [ "$status" -eq 0 ]
  [ "$output" = "1 1" ]
}

@test "qp-code-scanning excludes alerts on non-touched files" {
  _load
  run bash -c "source '$PROBE'; qp-code-scanning 'scripts/other.sh' < '$FIX/code-scanning-alerts.json'"
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

@test "qp-code-scanning does not crash on a non-array API response (disabled/unauthorized)" {
  _load
  # GitHub's /code-scanning/alerts returns an ERROR OBJECT (not an array) when
  # code scanning is disabled or the token lacks access. The parser must not
  # blow up with a jq 'Cannot index string' error.
  run bash -c "source '$PROBE'; printf '%s' '{\"message\":\"no analysis found\",\"documentation_url\":\"https://docs.github.com\"}' | qp-code-scanning 'scripts/foo.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "0 0" ]
}

# ---------------------------------------------------------------------------
# qp-coverage — parse kcov output; the skip (no kcov) path MUST be tested
# ---------------------------------------------------------------------------

@test "qp-coverage records null and skips when kcov is not installed" {
  _load
  # Run with a PATH that has no kcov; function must print 'null', log a skip
  # note to stderr, and exit 0 (never error).
  run env PATH="$STUB_BIN" bash -c "source '$PROBE'; qp-run-coverage '$REPO_ROOT' 2>/tmp/qp_cov_err; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"null"* ]]
  run cat /tmp/qp_cov_err
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"kcov"* ]]
}

# ---------------------------------------------------------------------------
# Tool-runner skip path: missing tool -> null + skip note + exit 0
# ---------------------------------------------------------------------------

@test "qp-run-shellcheck records null and skips when shellcheck is missing" {
  _load
  run env PATH="$STUB_BIN" bash -c "source '$PROBE'; qp-run-shellcheck '$FIX/touched.sh' 2>/tmp/qp_sc_err; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"null"* ]]
  run cat /tmp/qp_sc_err
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"shellcheck"* ]]
}

@test "qp-run-dup records null and skips when jscpd is missing" {
  _load
  run env PATH="$STUB_BIN" bash -c "source '$PROBE'; qp-run-dup '$TARGET' 'touched.sh' 2>/tmp/qp_dup_err; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"null"* ]]
  run cat /tmp/qp_dup_err
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"jscpd"* ]]
}

@test "qp-run-code-scanning logs 'unavailable' (not 'not installed') when the gh wrapper is absent" {
  _load
  # Code scanning is an API, not a local tool — its skip paths (wrapper absent,
  # slug unresolved, empty / non-array response, e.g. a 403 'Code Security must be
  # enabled') must read 'unavailable', not the misleading 'not installed'.
  run env QP_GH="$BATS_TEST_TMPDIR/nope.sh" bash -c "source '$PROBE'; qp-run-code-scanning '$TARGET' 'scripts/foo.sh' 2>/tmp/qp_cs_err; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"null"* ]]
  run cat /tmp/qp_cs_err
  [[ "$output" == *"code-scanning"* ]]
  [[ "$output" == *"unavailable"* ]]
  [[ "$output" != *"not installed"* ]]
}

@test "qp-run-secrets records null and skips when gitleaks is missing" {
  _load
  run env PATH="$STUB_BIN" bash -c "source '$PROBE'; qp-run-secrets '$TARGET' 2>/tmp/qp_sec_err; echo \$?"
  [ "$status" -eq 0 ]
  [[ "$output" == *"null"* ]]
  run cat /tmp/qp_sec_err
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"gitleaks"* ]]
}

# ---------------------------------------------------------------------------
# CLI: append a record to metrics.jsonl in the TARGET repo
# ---------------------------------------------------------------------------

@test "CLI appends a valid JSON line to target dev/quality/metrics.jsonl" {
  # No external scanners on PATH but keep jq + coreutils available: a clean PATH
  # plus the real bin dirs for jq/git. Use --files so no git diff is needed.
  run bash "$PROBE" --task T20260101-000001 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  [ -f "$TARGET/dev/quality/metrics.jsonl" ]
  # Exactly one record, valid JSON, with the expected keys.
  run wc -l < "$TARGET/dev/quality/metrics.jsonl"
  [ "$output" -eq 1 ]
  run jq -e '.task, .date, .files, .shellcheck, .delta' "$TARGET/dev/quality/metrics.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.task' "$TARGET/dev/quality/metrics.jsonl")" = "T20260101-000001" ]
  [ "$(jq -r '.date' "$TARGET/dev/quality/metrics.jsonl")" = "2026-06-18" ]
}

@test "CLI creates dev/quality/ idempotently (dir absent -> present)" {
  [ ! -d "$TARGET/dev/quality" ]
  run bash "$PROBE" --task T20260101-000002 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  [ -d "$TARGET/dev/quality" ]
  # A second run appends a second line, not clobbers.
  run bash "$PROBE" --task T20260101-000003 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  run wc -l < "$TARGET/dev/quality/metrics.jsonl"
  [ "$output" -eq 2 ]
}

@test "CLI --files scopes the record to the given file list" {
  run bash "$PROBE" --task T20260101-000004 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  run jq -e '.files | index("'"$FIX/touched.sh"'")' "$TARGET/dev/quality/metrics.jsonl"
  [ "$status" -eq 0 ]
}

@test "CLI --json prints the record line and still exits 0" {
  run bash "$PROBE" --task T20260101-000005 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18 --json
  [ "$status" -eq 0 ]
  # The record is the JSON object line printed to stdout under --json.
  local rec
  rec="$(grep -E '^\{"task"' <<<"$output")"
  run jq -e '.task == "T20260101-000005"' <<<"$rec"
  [ "$status" -eq 0 ]
}

@test "CLI records design_score when --design-score is given, null otherwise" {
  run bash "$PROBE" --task T20260101-000006 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18 --design-score 86
  [ "$status" -eq 0 ]
  [ "$(jq -r '.design_score' "$TARGET/dev/quality/metrics.jsonl")" = "86" ]

  run bash "$PROBE" --task T20260101-000007 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  [ "$(jq -r '.design_score' <<<"$(_last_record)")" = "null" ]
}

# ---------------------------------------------------------------------------
# delta — computed vs the LAST record in metrics.jsonl
# ---------------------------------------------------------------------------

@test "delta is empty {} when there is no prior record" {
  run bash "$PROBE" --task T20260101-000008 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  [ "$(jq -r '.delta | length' <<<"$(_last_record)")" -eq 0 ]
}

@test "delta is computed vs a seeded baseline record" {
  mkdir -p "$TARGET/dev/quality"
  # Seed a baseline with a different file_loc so a delta is forced.
  printf '%s\n' '{"task":"T0","date":"2026-06-01","files":["x.sh"],"shellcheck":{"error":0,"warning":0,"info":0,"style":0},"coverage_pct":null,"max_fn_lines":2,"file_loc":3,"dup_pct":null,"secrets":null,"code_scanning":null,"design_score":null,"delta":{}}' \
    > "$TARGET/dev/quality/metrics.jsonl"

  run bash "$PROBE" --task T20260101-000009 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  # file_loc went 3 -> 13, so delta.file_loc must be +10.
  [ "$(jq -r '.delta.file_loc' <<<"$(_last_record)")" = "10" ]
}

@test "regression in a metric emits a loud WARNING but still exits 0" {
  mkdir -p "$TARGET/dev/quality"
  # Baseline with 0 warnings; touched.sh will introduce shellcheck warnings,
  # OR a higher file_loc — force a regression via file_loc baseline of 1.
  printf '%s\n' '{"task":"T0","date":"2026-06-01","files":["x.sh"],"shellcheck":{"error":0,"warning":0,"info":0,"style":0},"coverage_pct":99.0,"max_fn_lines":2,"file_loc":1,"dup_pct":0,"secrets":0,"code_scanning":null,"design_score":null,"delta":{}}' \
    > "$TARGET/dev/quality/metrics.jsonl"

  run bash "$PROBE" --task T20260101-000010 --files "$FIX/touched.sh" \
      --repo-root "$TARGET" --date 2026-06-18
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"regress"* ]]
}

# ---------------------------------------------------------------------------
# Usage / IO errors -> non-zero (the only non-zero exits)
# ---------------------------------------------------------------------------

@test "missing --task prints usage and exits non-zero" {
  run bash "$PROBE" --files "$FIX/touched.sh" --repo-root "$TARGET"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* || "$output" == *"task"* ]]
}

@test "neither --range nor --files with no git repo errors cleanly" {
  # --repo-root points at a non-git dir and no --files given: the default range
  # diff cannot run -> a clean IO/usage error, non-zero, never a stack trace.
  run bash "$PROBE" --task T20260101-000011 --repo-root "$TARGET"
  [ "$status" -ne 0 ]
}

@test "no arguments prints usage and exits non-zero" {
  run bash "$PROBE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

# ---------------------------------------------------------------------------
# --range path: the record stores REPO-RELATIVE paths, and code-scanning gets
# the RESOLVED touched set. The suite previously only exercised --files, which
# let two path-handling bugs ship (absolute paths leaked into the scoreboard;
# code-scanning was fed the raw --files arg, empty under --range). Regression
# coverage for T20260609-204303 D2 (caught by the build-pipeline-repo pilot).
# ---------------------------------------------------------------------------

# Build a throwaway git repo: a base commit plus a `feat` branch that touches one
# script ($2, default scripts/new.sh). Echoes the base branch name on stdout.
_mk_git_repo() {
  local repo="$1" script="${2:-scripts/new.sh}"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name tester
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  local base; base="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  git -C "$repo" checkout -qb feat
  mkdir -p "$repo/$(dirname "$script")"
  printf '#!/usr/bin/env bash\nfoo() {\n  echo hi\n}\n' > "$repo/$script"
  git -C "$repo" add -A
  git -C "$repo" commit -qm feat
  printf '%s' "$base"
}

@test "CLI --range records repo-relative touched paths (never absolute)" {
  local repo="$BATS_TEST_TMPDIR/gitrepo"
  local base; base="$(_mk_git_repo "$repo" scripts/new.sh)"
  run bash "$PROBE" --task T20260101-000020 --range "$base...feat" \
      --repo-root "$repo" --date 2026-06-18
  [ "$status" -eq 0 ]
  local board="$repo/dev/quality/metrics.jsonl"
  # The touched script is recorded repo-relative, not as an absolute path.
  [ "$(jq -r '.files | index("scripts/new.sh")' "$board")" != "null" ]
  # And NO entry is absolute (an absolute path would leak the maintainer's $HOME).
  run jq -e '.files | any(startswith("/"))' "$board"
  [ "$status" -ne 0 ]
}

@test "CLI --range feeds the resolved touched set to code-scanning (scoped, not all-repo)" {
  local repo="$BATS_TEST_TMPDIR/gitrepo2"
  local base; base="$(_mk_git_repo "$repo" scripts/foo.sh)"
  # Origin so the owner/repo slug resolves; stub the gh wrapper to return the
  # alerts fixture (open error+warning on scripts/foo.sh; open error on
  # scripts/untouched.sh; a fixed alert on foo.sh). Touched = scripts/foo.sh, so
  # ONLY foo.sh's open alerts count -> "1 1". The pre-fix bug fed an empty list
  # (the raw --files arg, unset under --range), which matched no alert -> "0 0".
  git -C "$repo" remote add origin https://github.com/acme/widget.git
  local stub="$BATS_TEST_TMPDIR/gh-stub.sh"
  printf '#!/usr/bin/env bash\ncat %q\n' "$FIX/code-scanning-alerts.json" > "$stub"
  chmod +x "$stub"
  run env QP_GH="$stub" bash "$PROBE" --task T20260101-000021 --range "$base...feat" \
      --repo-root "$repo" --date 2026-06-18
  [ "$status" -eq 0 ]
  local board="$repo/dev/quality/metrics.jsonl"
  [ "$(jq -r '.code_scanning.error' "$board")" = "1" ]
  [ "$(jq -r '.code_scanning.warning' "$board")" = "1" ]
}

@test "CLI --range with no touched files records an empty files array" {
  local repo="$BATS_TEST_TMPDIR/gitrepo3"
  local base; base="$(_mk_git_repo "$repo" scripts/foo.sh)"
  run bash "$PROBE" --task T20260101-000022 --range "$base...$base" \
      --repo-root "$repo" --date 2026-06-18
  [ "$status" -eq 0 ]
  local board="$repo/dev/quality/metrics.jsonl"
  [ "$(jq -r '.files | length' "$board")" -eq 0 ]
}
