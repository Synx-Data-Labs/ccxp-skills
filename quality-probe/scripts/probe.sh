#!/usr/bin/env bash
# probe.sh — record+warn code-quality probe over a task's TOUCHED files
# (T20260609-204303 D2).
#
# Measures quality metrics on the files a task changed (NOT the repo's legacy
# debt) and appends one record per task to an append-only scoreboard
# `dev/quality/metrics.jsonl` in the TARGET repo, so quality trend is visible.
#
# Posture: RECORD + WARN, never block. A missing tool records that field as
# `null` and logs a `skip: <tool> not installed` note to stderr — it NEVER
# errors. The probe always exits 0 except on usage / IO errors. On a metric
# regression vs the last record it emits a loud `WARNING: <metric> regressed`
# line and records the delta, but still exits 0.
#
# Usage:
#   probe.sh --task <T-id> (--range <git-range> | --files <csv>)
#            [--repo-root <path>] [--date YYYY-MM-DD]
#            [--design-score N] [--json]
#
# Touched files: from --files (csv) or `git -C <repo-root> diff --name-only
# <range>` (default range origin/main...HEAD). --repo-root defaults to cwd.
#
# Probes (each tool-missing -> field null + skip note, never error):
#   sc (shellcheck) -> {error,warning,info,style} over touched *.sh
#   size            -> {file_loc, max_fn_lines} over touched *.sh (pure bash/awk)
#   jscpd           -> dup_pct over touched files
#   gitleaks        -> secrets count
#   kcov            -> coverage_pct over the bats suite (best-effort)
#   code-scanning   -> open GitHub code-scanning alerts by severity, touched-only
#
# Record shape (one line in metrics.jsonl):
#   {"task":"T…","date":"YYYY-MM-DD","files":[…],
#    "shellcheck":{"error":0,"warning":2,"info":0,"style":0},
#    "coverage_pct":71.4,"max_fn_lines":48,"file_loc":260,"dup_pct":3.1,
#    "secrets":0,"code_scanning":{"error":0,"warning":1},"design_score":86,
#    "delta":{…}}
#
# Sourceable: defines functions only; the CLI entrypoint runs solely under the
# direct-execution guard at the bottom (repo guidelines). Testable functions
# take date as a param — no nondeterministic `date` inside them.

set -euo pipefail

# Path to the gh wrapper used for the code-scanning probe (overridable for tests).
QP_GH="${QP_GH:-$HOME/.claude/skills/_gh/gh.sh}"

# --- usage ------------------------------------------------------------------

quality-probe-usage() {
  cat <<'EOF'
Usage:
  probe.sh --task <T-id> (--range <git-range> | --files <csv>)
           [--repo-root <path>] [--date YYYY-MM-DD]
           [--design-score N] [--json]

Measures code quality on a task's touched files and appends one record to
<repo-root>/dev/quality/metrics.jsonl. Record + warn — always exits 0 except
on usage / IO errors.

Options:
  --task T-id        Task id for the record (required).
  --range <range>    git diff range for touched files (default origin/main...HEAD).
  --files <csv>      Explicit comma-separated touched-file list (overrides --range).
  --repo-root <path> Target repo root (default: cwd). Scoreboard lives here.
  --date YYYY-MM-DD  Record date (default: today).
  --design-score N   Design-score to record (default: null).
  --json             Print the record to stdout.
EOF
}

# Log a probe skip. Reason defaults to "not installed" (a missing local tool);
# code scanning is an API, so it passes "unavailable" (wrapper absent, slug
# unresolved, or an empty / non-array response such as a 403 GHAS-off).
qp-log-skip() { printf 'skip: %s %s\n' "$1" "${2:-not installed}" >&2; }

# ---------------------------------------------------------------------------
# Pure parse functions — fed mock/real tool output on stdin or as args.
# No `command -v`, no `date`, no I/O beyond stdin so BATS can pin them.
# ---------------------------------------------------------------------------

# qp-shellcheck: parse `shellcheck -f gcc` output (on stdin) into four
# space-separated counts: "error warning info style".
#
# Note: gcc format collapses shellcheck's info+style into a single `note:`
# label, so this maps note -> info and reports style as 0 (gcc cannot surface
# it). Documented in SKILL.md. Deterministic.
qp-shellcheck() {
  awk '
    / error: /   { e++ }
    / warning: / { w++ }
    / note: /    { i++ }
    / style: /   { s++ }
    END { printf "%d %d %d %d", e+0, w+0, i+0, s+0 }
  '
}

# qp-size: pure bash/awk LOC + max function line-span over the given *.sh files.
# Prints "file_loc max_fn_lines". file_loc = summed physical lines; max_fn_lines
# = the largest single-function span (opening `name() {` line to its matching
# `}` at the same or lower brace depth), inclusive, across all files.
qp-size() {
  awk '
    function flush_fn() {
      if (in_fn && (NR_close - NR_open + 1) > max) max = NR_close - NR_open + 1
      in_fn = 0
    }
    FNR == 1 { } # per-file reset handled by total line count below
    { total++ }
    # Detect a function header: optional `function ` then NAME() {  (one line).
    !in_fn && /^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\(\)|function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_-]*).*\{[[:space:]]*$/ {
      in_fn = 1; NR_open = total; depth = 1; NR_close = total; next
    }
    in_fn {
      # Count braces on the line to track nesting; close at depth 0.
      line = $0
      o = gsub(/\{/, "{", line)
      c = gsub(/\}/, "}", line)
      depth += o - c
      NR_close = total
      if (depth <= 0) flush_fn()
    }
    END { flush_fn(); printf "%d %d", total+0, max+0 }
  ' "$@"
}

# qp-dup: parse jscpd JSON (stdin) -> duplication percentage.
qp-dup() {
  jq -r '.statistics.total.percentage // 0'
}

# qp-secrets: count gitleaks findings from its JSON report (stdin).
qp-secrets() {
  jq -r 'if type=="array" then length else 0 end'
}

# qp-code-scanning: count OPEN code-scanning alerts on touched files by
# severity. Args: the touched-file list (one arg, comma-separated OR repeated).
# Reads the alerts JSON array on stdin. Prints "error warning".
#   - state must be "open"
#   - most_recent_instance.location.path must be one of the touched files
#     (matched by suffix so repo-relative vs absolute both work)
qp-code-scanning() {
  local touched="$1"
  # Guard: GitHub returns an error/message OBJECT (not an array) when code
  # scanning is disabled or the token lacks access — never index into that.
  jq -r --arg touched "$touched" '
    if type != "array" then "0 0" else
      ($touched | split(",")) as $files
      | [ .[]
          | select(.state == "open")
          | (.most_recent_instance.location.path) as $p
          | select($p != null and ($files | any(. as $f | $f != "" and ($f == $p or ($p | endswith($f)) or ($f | endswith($p))))))
          | .rule.severity ] as $sev
      | "\(($sev | map(select(. == "error")) | length)) \(($sev | map(select(. == "warning")) | length))"
    end
  '
}

# ---------------------------------------------------------------------------
# Tool-runner functions — check the tool is on PATH; if absent, print `null`,
# log a skip note, and return 0 (never error). Otherwise run the tool and pipe
# its output through the matching pure parser. Output is a JSON fragment.
# ---------------------------------------------------------------------------

# Filter a newline list to existing *.sh files (touched-only, .sh-only).
qp-sh-files() {
  local f
  for f in "$@"; do
    [[ "$f" == *.sh && -f "$f" ]] && printf '%s\n' "$f"
  done
}

# qp-run-shellcheck: emit a JSON object {error,warning,info,style} or `null`.
qp-run-shellcheck() {
  local files=("$@") sh_files counts
  if ! command -v shellcheck >/dev/null 2>&1; then
    qp-log-skip shellcheck; printf 'null'; return 0
  fi
  mapfile -t sh_files < <(qp-sh-files "${files[@]}")
  if [[ ${#sh_files[@]} -eq 0 ]]; then
    printf '{"error":0,"warning":0,"info":0,"style":0}'; return 0
  fi
  # The tool exits non-zero when it finds issues; that is expected, not fatal.
  counts="$(shellcheck -f gcc "${sh_files[@]}" 2>/dev/null | qp-shellcheck || true)"
  read -r e w i s <<<"$counts"
  printf '{"error":%d,"warning":%d,"info":%d,"style":%d}' "${e:-0}" "${w:-0}" "${i:-0}" "${s:-0}"
}

# qp-run-size: emit "file_loc max_fn_lines" (pure bash/awk; never skips).
# Args: touched files. Prints two space-separated ints (0 0 if no .sh touched).
qp-run-size() {
  local files=("$@") sh_files
  mapfile -t sh_files < <(qp-sh-files "${files[@]}")
  if [[ ${#sh_files[@]} -eq 0 ]]; then printf '0 0'; return 0; fi
  qp-size "${sh_files[@]}"
}

# qp-run-dup: emit a dup percentage (number) or `null`. Args: repo-root, then
# touched files (jscpd runs over the repo; we surface the total percentage).
qp-run-dup() {
  local repo_root="$1"; shift
  local tmp pct
  if ! command -v jscpd >/dev/null 2>&1; then
    qp-log-skip jscpd; printf 'null'; return 0
  fi
  tmp="$(mktemp -d)"
  if jscpd "$repo_root" --silent --reporters json --output "$tmp" >/dev/null 2>&1 \
     && [[ -f "$tmp/jscpd-report.json" ]]; then
    pct="$(qp-dup < "$tmp/jscpd-report.json")"
    rm -rf "$tmp"
    printf '%s' "${pct:-null}"
  else
    rm -rf "$tmp"
    qp-log-skip jscpd; printf 'null'
  fi
}

# qp-run-secrets: emit a secret-finding count (number) or `null`. Arg: repo-root.
qp-run-secrets() {
  local repo_root="$1" tmp count
  if ! command -v gitleaks >/dev/null 2>&1; then
    qp-log-skip gitleaks; printf 'null'; return 0
  fi
  tmp="$(mktemp)"
  if gitleaks detect --source "$repo_root" --report-format json --report-path "$tmp" --no-banner >/dev/null 2>&1 \
     || [[ -s "$tmp" ]]; then
    count="$(qp-secrets < "$tmp" 2>/dev/null || echo 0)"
    rm -f "$tmp"
    printf '%s' "${count:-0}"
  else
    rm -f "$tmp"
    qp-log-skip gitleaks; printf 'null'
  fi
}

# qp-run-coverage: emit a line-coverage percentage (number) or `null`. Arg:
# repo-root. Best-effort — kcov over the bats suite; will usually skip.
qp-run-coverage() {
  local repo_root="$1" tmp pct
  if ! command -v kcov >/dev/null 2>&1; then
    qp-log-skip kcov; printf 'null'; return 0
  fi
  if [[ ! -d "$repo_root/tests" ]]; then
    qp-log-skip kcov; printf 'null'; return 0
  fi
  tmp="$(mktemp -d)"
  if kcov --include-path="$repo_root" "$tmp" bats "$repo_root"/tests/*.bats >/dev/null 2>&1 \
     && [[ -f "$tmp/kcov-merged/coverage.json" ]]; then
    pct="$(jq -r '.percent_covered // .covered // empty' "$tmp/kcov-merged/coverage.json" 2>/dev/null || true)"
    rm -rf "$tmp"
    printf '%s' "${pct:-null}"
  else
    rm -rf "$tmp"
    qp-log-skip kcov; printf 'null'
  fi
}

# qp-run-code-scanning: emit a JSON object {error,warning} or `null`. Args:
# repo-root, touched-csv. Reads GitHub code-scanning alerts via the gh wrapper.
qp-run-code-scanning() {
  local repo_root="$1" touched="$2" alerts e w
  if [[ ! -x "$QP_GH" && ! -f "$QP_GH" ]]; then
    qp-log-skip code-scanning unavailable; printf 'null'; return 0
  fi
  # Resolve owner/repo from the target repo's origin.
  local slug
  slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||')" || true
  if [[ -z "$slug" || "$slug" != */* ]]; then
    qp-log-skip code-scanning unavailable; printf 'null'; return 0
  fi
  alerts="$( (cd "$repo_root" && bash "$QP_GH" api "/repos/$slug/code-scanning/alerts" --paginate) 2>/dev/null || true)"
  if [[ -z "$alerts" ]]; then
    # disabled / unauthorized / none — skip, don't error.
    qp-log-skip code-scanning unavailable; printf 'null'; return 0
  fi
  if ! jq -e 'type == "array"' <<<"$alerts" >/dev/null 2>&1; then
    # Non-array response = an error/message object (code scanning disabled or the
    # token lacks security_events access). Skip cleanly — do NOT miscount as 0/0.
    qp-log-skip code-scanning unavailable; printf 'null'; return 0
  fi
  read -r e w <<<"$(qp-code-scanning "$touched" <<<"$alerts")"
  printf '{"error":%d,"warning":%d}' "${e:-0}" "${w:-0}"
}

# ---------------------------------------------------------------------------
# Record assembly + delta + warnings
# ---------------------------------------------------------------------------

# qp-last-record: print the last JSON line of the scoreboard, or empty if none.
qp-last-record() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  tail -n 1 "$file" 2>/dev/null || true
}

# qp-flatten: flatten the metric fields of a record into "key value" lines for
# numeric comparison. Nested objects become key_subkey. Skips nulls and the
# non-numeric fields (task,date,files,delta).
qp-flatten() {
  jq -r '
    to_entries[]
    | select(.key | IN("task","date","files","delta") | not)
    | if (.value | type) == "object" then
        (.value | to_entries[] | "\(.key) \(.value)") as $kv
        | ($kv | split(" ")) as $p
        | "\(.key)_\($p[0]) \($p[1])"
      elif (.value | type) == "number" then
        "\(.key) \(.value)"
      else empty end
  '
}

# qp-compute-delta: given current + prior record JSON, emit a JSON object of
# numeric diffs (current - prior) for shared numeric keys. Empty {} if no prior.
qp-compute-delta() {
  local cur="$1" prior="$2"
  if [[ -z "$prior" ]]; then printf '{}'; return 0; fi
  local cur_flat prior_flat
  cur_flat="$(qp-flatten <<<"$cur")"
  prior_flat="$(qp-flatten <<<"$prior")"
  # Join on key; emit "key delta" then fold into JSON via jq.
  awk '
    NR==FNR { prior[$1]=$2; next }
    ($1 in prior) {
      d = $2 - prior[$1]
      if (d != 0) printf "%s %s\n", $1, d
    }
  ' <(printf '%s\n' "$prior_flat") <(printf '%s\n' "$cur_flat") \
  | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1]|tonumber)}] | add // {}'
}

# qp-warnings: given the delta JSON, print a loud WARNING line per regressed
# metric. Direction: coverage_pct & design_score -> lower is worse; everything
# else -> higher is worse.
qp-warnings() {
  local delta="$1"
  jq -r '
    to_entries[]
    | .key as $k | .value as $v
    | if ($k == "coverage_pct" or $k == "design_score") then
        (if $v < 0 then "\($k) \($v)" else empty end)
      else
        (if $v > 0 then "\($k) \($v)" else empty end)
      end
  ' <<<"$delta" | while read -r metric dv; do
    [[ -z "$metric" ]] && continue
    printf 'WARNING: %s regressed (delta %s)\n' "$metric" "$dv"
  done
}

# ---------------------------------------------------------------------------
# orchestrator
# ---------------------------------------------------------------------------

quality-probe() {
  local task="" range="" files_csv="" repo_root="" rec_date="" design_score="null" json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)         task="${2:-}"; shift 2 ;;
      --range)        range="${2:-}"; shift 2 ;;
      --files)        files_csv="${2:-}"; shift 2 ;;
      --repo-root)    repo_root="${2:-}"; shift 2 ;;
      --date)         rec_date="${2:-}"; shift 2 ;;
      --design-score) design_score="${2:-}"; shift 2 ;;
      --json)         json=1; shift ;;
      -h|--help)      quality-probe-usage; return 0 ;;
      -*)             echo "Error: unknown option '$1'" >&2; quality-probe-usage >&2; return 1 ;;
      *)              echo "Error: unexpected argument '$1'" >&2; quality-probe-usage >&2; return 1 ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed." >&2; return 1
  fi
  if [[ -z "$task" ]]; then
    echo "Error: --task is required." >&2; quality-probe-usage >&2; return 1
  fi
  [[ -z "$repo_root" ]] && repo_root="$PWD"
  if [[ ! -d "$repo_root" ]]; then
    echo "Error: --repo-root not a directory: $repo_root" >&2; return 1
  fi
  # --date defaults to today ONLY here in the entrypoint (testable fns take it).
  [[ -z "$rec_date" ]] && rec_date="$(date +%F)"

  # Resolve touched files into TWO views:
  #   files       — the canonical RECORD view: repo-relative (from `git diff`) or
  #                 exactly as passed via --files. NEVER rewritten to absolute —
  #                 that would leak the maintainer's $HOME into the scoreboard and
  #                 break code-scanning's location.path match (both repo-relative).
  #   probe_files — the on-disk view: absolute, so the file-reading probes find
  #                 each file regardless of the process cwd. Derived below.
  local -a files=()
  if [[ -n "$files_csv" ]]; then
    IFS=',' read -r -a files <<<"$files_csv"
  else
    [[ -z "$range" ]] && range="origin/main...HEAD"
    local diff_out
    if ! diff_out="$(git -C "$repo_root" diff --name-only "$range" 2>/dev/null)"; then
      echo "Error: cannot compute touched files (no --files and 'git diff $range' failed in $repo_root)." >&2
      return 1
    fi
    mapfile -t files < <(printf '%s' "$diff_out")
  fi
  # Drop empty entries from the record view.
  local -a clean=(); local f
  for f in "${files[@]}"; do [[ -n "$f" ]] && clean+=("$f"); done
  files=("${clean[@]}")

  # On-disk view: resolve each path to absolute (already-absolute paths pass
  # through) so shellcheck/size read the file from any cwd.
  local -a probe_files=(); local p
  for p in "${files[@]}"; do
    if [[ "$p" = /* ]]; then probe_files+=("$p"); else probe_files+=("$repo_root/$p"); fi
  done

  # Run the probes. File-reading probes (shellcheck, size, dup) take the absolute
  # probe_files; code-scanning takes the repo-relative set (matches location.path).
  local shellcheck_json size_out file_loc max_fn dup secrets coverage cs_json files_rel_csv
  shellcheck_json="$(qp-run-shellcheck "${probe_files[@]}")"
  size_out="$(qp-run-size "${probe_files[@]}")"
  read -r file_loc max_fn <<<"$size_out"
  dup="$(qp-run-dup "$repo_root" "${probe_files[@]}")"
  secrets="$(qp-run-secrets "$repo_root")"
  coverage="$(qp-run-coverage "$repo_root")"
  files_rel_csv="$(IFS=,; printf '%s' "${files[*]}")"
  cs_json="$(qp-run-code-scanning "$repo_root" "$files_rel_csv")"

  # Build the files JSON array.
  local files_arr
  if [[ ${#files[@]} -eq 0 ]]; then
    files_arr='[]'
  else
    files_arr="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
  fi

  # Validate design_score (numeric or null).
  case "$design_score" in
    null) : ;;
    ''|*[!0-9]*) echo "Error: --design-score must be a non-negative integer" >&2; return 1 ;;
  esac

  # Assemble the record WITHOUT delta first.
  local base
  base="$(jq -n \
    --arg task "$task" \
    --arg date "$rec_date" \
    --argjson files "$files_arr" \
    --argjson shellcheck "$shellcheck_json" \
    --argjson coverage_pct "$coverage" \
    --argjson max_fn_lines "$max_fn" \
    --argjson file_loc "$file_loc" \
    --argjson dup_pct "$dup" \
    --argjson secrets "$secrets" \
    --argjson code_scanning "$cs_json" \
    --argjson design_score "$design_score" \
    '{task:$task, date:$date, files:$files, shellcheck:$shellcheck,
      coverage_pct:$coverage_pct, max_fn_lines:$max_fn_lines, file_loc:$file_loc,
      dup_pct:$dup_pct, secrets:$secrets, code_scanning:$code_scanning,
      design_score:$design_score}')"

  # Compute delta vs the last record in the scoreboard.
  local scoreboard="$repo_root/dev/quality/metrics.jsonl"
  local prior delta
  prior="$(qp-last-record "$scoreboard")"
  delta="$(qp-compute-delta "$base" "$prior")"

  local record
  record="$(jq -c --argjson delta "$delta" '. + {delta:$delta}' <<<"$base")"

  # Append to the scoreboard (idempotent dir/file creation).
  if ! mkdir -p "$repo_root/dev/quality" 2>/dev/null; then
    echo "Error: cannot create $repo_root/dev/quality" >&2; return 1
  fi
  if ! printf '%s\n' "$record" >> "$scoreboard"; then
    echo "Error: cannot append to $scoreboard" >&2; return 1
  fi

  # Human summary + loud warnings on regression.
  local warns
  warns="$(qp-warnings "$delta")"
  printf 'quality-probe: %s (%s) — %d file(s); shellcheck=%s dup=%s secrets=%s cov=%s code_scanning=%s design=%s\n' \
    "$task" "$rec_date" "${#files[@]}" \
    "$(jq -c . <<<"$shellcheck_json")" "$dup" "$secrets" "$coverage" \
    "$(jq -c . <<<"$cs_json")" "$design_score"
  if [[ -n "$warns" ]]; then printf '%s\n' "$warns"; fi

  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$record"
  fi

  return 0
}

# Run only when executed directly (not when sourced). The :- guards keep this
# safe under `set -u` when sourced in a context that has not populated
# BASH_SOURCE (e.g. `bash -c 'source …'`).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  quality-probe "$@"
fi
