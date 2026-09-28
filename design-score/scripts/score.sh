#!/usr/bin/env bash
# score.sh — deterministic scorer for a /drive design doc (task file).
#
# Scores a task file written against repo-conventions/templates/design-doc.md
# on a 0–100 scale across 7 structural checks plus a placeholder penalty, and
# exits 0 iff the score clears the threshold (default 70). It is the /drive
# Phase 2 → Phase 3 hard gate (T20260609-204303 D3): a design must clear the
# bar before any implementation begins. Deterministic only — no LLM rubric.
#
# Usage:
#   score.sh <task-file> [--kind code|docs] [--threshold N] [--json]
#
# Output:
#   default       per-check breakdown + total + PASS/FAIL (human-readable)
#   --json        {"score":N,"threshold":N,"pass":bool,"kind":"code|docs",
#                  "checks":{...}}
#
# Exit: 0 if score >= threshold, 1 otherwise (and on usage/IO errors).
#
# Sourceable: defines functions only; the CLI entrypoint runs solely under the
# direct-execution guard at the bottom (repo guidelines).

set -euo pipefail

# --- usage ------------------------------------------------------------------

design-score-usage() {
  cat <<'EOF'
Usage:
  score.sh <task-file> [--kind code|docs] [--threshold N] [--json]

Scores a /drive design doc against the design-doc template. Exits 0 if the
score reaches the threshold (default 70), 1 otherwise.

Options:
  --kind code|docs   Override change-kind auto-detection.
  --threshold N      Pass mark (default 70).
  --json             Emit machine-readable JSON instead of the breakdown.
EOF
}

# --- body helpers -----------------------------------------------------------

# Print the document body (everything after the closing frontmatter '---').
# If there is no frontmatter, print the whole file.
ds-body() {
  local file="$1"
  awk '
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { in_fm=0; body=1; next }
    in_fm { next }
    { print }
  ' "$file"
}

# Print the YAML frontmatter block (between the first two '---' lines).
ds-frontmatter() {
  local file="$1"
  awk '
    NR==1 && $0=="---" { in_fm=1; next }
    in_fm && $0=="---" { exit }
    in_fm { print }
  ' "$file"
}

# Print body with fenced code blocks (``` … ```), inline-code spans (`…`), and
# HTML comments removed, so prose-only scans (placeholders) do not see
# scaffold/code content — including a doc that merely *discusses* the marker
# tokens (`TODO`, `???`, `<...>`) inside inline code.
ds-body-prose() {
  local file="$1"
  # shellcheck disable=SC2016  # the backticks in the perl program are literal
  ds-body "$file" | awk '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    { print }
  ' | perl -pe 's/`[^`]*`//g' | perl -0777 -pe 's/<!--.*?-->//gs'
}

# Capture ds-body/ds-frontmatter into a variable, THEN feed a here-string to
# the consumer — never `ds-body "$file" | consumer`. Rationale (found while
# debugging C2 undercounting §Common headings on a real ~450-line bilingual
# task doc, T20260719-219322): the script runs under `set -o pipefail`
# (top of file). A consumer that exits as soon as it finds its match — `grep
# -q`, or an awk `{ ...; exit }` — closes its end of the pipe early. On a
# document too large to fit in one pipe-buffer write, `ds-body`'s awk is
# still mid-write when that happens, gets SIGPIPE, and exits 141 — which
# `pipefail` then reports as the WHOLE pipeline's exit status instead of the
# consumer's real (successful) one. Small fixture files never hit this (the
# whole body fits in one buffered write, so the producer always finishes
# before the consumer could exit early) — which is why `tests/design_score.bats`
# didn't catch it. A `body="$(ds-body "$file")"` capture runs the producer to
# completion (command substitution always does) before the consumer starts at
# all, so there is no live pipe left for an early exit to break.

# Return the text of a "## <name>" section (up to the next "## " heading).
# $2 is an ERE alternation of acceptable heading names, e.g. "Plan|Scope".
ds-section() {
  local file="$1" names="$2" body
  body="$(ds-body "$file")"
  awk -v names="$names" '
    BEGIN { re = "^## +(" names ")( |$|[^A-Za-z])" }
    /^## / {
      if (capturing) { exit }
      if ($0 ~ re) { capturing=1; next }
    }
    capturing { print }
  ' <<<"$body"
}

# True (0) if a "## <name>" heading exists in the body. awk instead of the
# original `grep -qiE`, mirroring ds-section above for one shared code path;
# toupper() on both sides restores the case-insensitivity `grep -i` gave,
# portably (no IGNORECASE — that's a gawk-only extension, not in BSD/mawk/nawk).
ds-has-section() {
  local file="$1" names="$2" body
  body="$(ds-body "$file")"
  awk -v names="$names" '
    BEGIN { re = "^## +(" toupper(names) ")( |$|[^A-Za-z])" }
    { if (toupper($0) ~ re) { found=1; exit } }
    END { exit !found }
  ' <<<"$body"
}

# True (0) if the given text contains at least one evidence anchor:
#   file:line | 7–40-hex SHA | fenced code/command block | PR #N
ds-has-anchor() {
  local text="$1"
  # file:line  (path-ish token followed by :digits)
  if grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+:[0-9]+' <<<"$text"; then return 0; fi
  # 7–40 hex SHA (word-bounded)
  if grep -qiE '\b[0-9a-f]{7,40}\b' <<<"$text"; then return 0; fi
  # PR / issue ref #N
  if grep -qE '#[0-9]+' <<<"$text"; then return 0; fi
  # fenced code / command block
  if grep -qE '^[[:space:]]*```' <<<"$text"; then return 0; fi
  # inline code that looks like a command/path  `... `
  # shellcheck disable=SC2016  # backticks are literal regex chars, not expansion
  if grep -qE '`[^`]*[/.][^`]*`' <<<"$text"; then return 0; fi
  return 1
}

# --- the seven checks -------------------------------------------------------

# C1: frontmatter completeness — 20 (estimation/status/source/related 4 each;
# priority-WITH-RATIONALE 4 — the value must carry text beyond the bare level).
ds-check-c1() {
  local file="$1" fm pts=0
  fm="$(ds-frontmatter "$file")"
  grep -qE '^estimation:[[:space:]]*\S' <<<"$fm" && pts=$((pts+4))
  grep -qE '^status:[[:space:]]*\S'     <<<"$fm" && pts=$((pts+4))
  grep -qE '^source:[[:space:]]*\S'     <<<"$fm" && pts=$((pts+4))
  grep -qE '^related:[[:space:]]*\S'    <<<"$fm" && pts=$((pts+4))
  # priority must have a rationale: a '—' or '-' delimiter followed by words.
  if grep -qE '^priority:[[:space:]]*\S+.*[—-][[:space:]]*[A-Za-z]' <<<"$fm"; then
    pts=$((pts+4))
  fi
  printf '%d' "$pts"
}

# C2: §Common section presence — 28 (7 body sections × 4). TLDR is mandatory
# here (not a bonus) — a design doc without a skimmable one-pager summary
# fails to serve its primary reader (maintainer scanning the queue).
ds-check-c2() {
  local file="$1" pts=0
  ds-has-section "$file" 'TLDR'           && pts=$((pts+4))
  ds-has-section "$file" 'Problem'        && pts=$((pts+4))
  ds-has-section "$file" 'Plan|Scope|Solution' && pts=$((pts+4))
  ds-has-section "$file" 'Test plan'      && pts=$((pts+4))
  ds-has-section "$file" 'Done criteria'  && pts=$((pts+4))
  ds-has-section "$file" 'Closed'         && pts=$((pts+4))
  ds-has-section "$file" 'Skills invoked' && pts=$((pts+4))
  printf '%d' "$pts"
}

# C3: §Code-only handling — 10.
#   code-class: Root cause 5 + Repo file references 5.
#   docs-class: full 10, BUT −5 if stubbed code-only sections are present.
ds-check-c3() {
  local file="$1" kind="$2" pts=0
  if [[ "$kind" == "code" ]]; then
    ds-has-section "$file" 'Root cause'          && pts=$((pts+5))
    ds-has-section "$file" 'Repo file references' && pts=$((pts+5))
  else
    pts=10
    if ds-has-section "$file" 'Root cause' || ds-has-section "$file" 'Repo file references'; then
      pts=$((pts-5))   # padding penalty: code-only sections in a docs task
    fi
  fi
  printf '%d' "$pts"
}

# C4: test plan has ≥1 checkbox — 6.
ds-check-c4() {
  local file="$1"
  # Same pipefail/SIGPIPE reasoning as ds-section/ds-has-section above: capture
  # first, `grep -q` a here-string, never a live pipe from ds-section's output.
  if grep -qE '^[[:space:]]*-[[:space:]]*\[[ xX]\]' <<<"$(ds-section "$file" 'Test plan')"; then
    printf '6'
  else
    printf '0'
  fi
}

# True (0) if a done-criterion line cites a test name, file:line, 7–40-hex SHA,
# PR #N, or skill ref.
ds-criterion-mapped() {
  local line="$1"
  grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+:[0-9]+' <<<"$line" && return 0
  grep -qiE '\b[0-9a-f]{7,40}\b' <<<"$line" && return 0
  grep -qE '#[0-9]+' <<<"$line" && return 0
  grep -qiE '\.(bats|py|sh|ts)\b' <<<"$line" && return 0
  grep -qiE '(test|spec)[[:space:]_./-]' <<<"$line" && return 0
  # shellcheck disable=SC2016  # backticks are literal regex chars, not expansion
  grep -qiE '/(skill|skills)/|`/[a-z-]+`' <<<"$line" && return 0
  return 1
}

# C5: done-criteria mapping — 16 × (fraction of done-criteria checkbox items
# that cite a test name, file:line, 7–40-hex SHA, PR #N, or skill ref).
ds-check-c5() {
  local file="$1" sec total=0 mapped=0 line
  sec="$(ds-section "$file" 'Done criteria')"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[\ xX]\] ]] || continue
    total=$((total+1))
    if ds-criterion-mapped "$line"; then
      mapped=$((mapped+1))
    fi
  done <<<"$sec"
  if [[ "$total" -eq 0 ]]; then printf '0'; return; fi
  # round(16 * mapped/total)
  printf '%d' $(( (16 * mapped + total/2) / total ))
}

# C6: evidence-anchor density — 18 × (fraction of present prose sections among
# {Problem, Plan/Scope, Root cause(code-class only)} that contain ≥1 anchor).
ds-check-c6() {
  local file="$1" kind="$2" total=0 anchored=0 txt
  if ds-has-section "$file" 'Problem'; then
    total=$((total+1)); txt="$(ds-section "$file" 'Problem')"
    ds-has-anchor "$txt" && anchored=$((anchored+1))
  fi
  if ds-has-section "$file" 'Plan|Scope|Solution'; then
    total=$((total+1)); txt="$(ds-section "$file" 'Plan|Scope|Solution')"
    ds-has-anchor "$txt" && anchored=$((anchored+1))
  fi
  if [[ "$kind" == "code" ]] && ds-has-section "$file" 'Root cause'; then
    total=$((total+1)); txt="$(ds-section "$file" 'Root cause')"
    ds-has-anchor "$txt" && anchored=$((anchored+1))
  fi
  if [[ "$total" -eq 0 ]]; then printf '0'; return; fi
  printf '%d' $(( (18 * anchored + total/2) / total ))
}

# C7: alternatives-considered-and-rejected present near the Plan/Scope/Solution — 6.
ds-check-c7() {
  local file="$1" txt
  txt="$(ds-section "$file" 'Plan|Scope|Solution')"
  if grep -qiE 'reject|alternative' <<<"$txt"; then
    printf '6'
  else
    printf '0'
  fi
}

# Placeholder penalty: −4 each for TBD/TODO/FIXME/???/<...> in prose,
# EXCLUDING fenced code blocks and <!-- ... --> HTML comments.
ds-check-placeholder() {
  local file="$1" prose count
  prose="$(ds-body-prose "$file")"
  count=$(grep -oiE '\bTBD\b|\bTODO\b|\bFIXME\b|\?\?\?|<[^<>]*\.\.\.[^<>]*>' <<<"$prose" | wc -l | tr -d ' ')
  printf '%d' $(( count * -4 ))
}

# --- change-kind auto-detect ------------------------------------------------

# code-class if the doc has a Root cause / Repo file references heading OR the
# body references code paths; else docs-class.
ds-detect-kind() {
  local file="$1" body
  if ds-has-section "$file" 'Root cause' || ds-has-section "$file" 'Repo file references'; then
    printf 'code'; return
  fi
  body="$(ds-body "$file")"
  if grep -qE 'scripts/|\.github/workflows|[A-Za-z0-9_./-]+\.(sh|py|ts)\b' <<<"$body"; then
    printf 'code'; return
  fi
  printf 'docs'
}

# --- orchestrator -----------------------------------------------------------

design-score() {
  local file="" kind="" threshold=70 json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)      kind="${2:-}"; shift 2 ;;
      --threshold) threshold="${2:-}"; shift 2 ;;
      --json)      json=1; shift ;;
      -h|--help)   design-score-usage; return 0 ;;
      -*)          echo "Error: unknown option '$1'" >&2; design-score-usage >&2; return 1 ;;
      *)           file="$1"; shift ;;
    esac
  done

  if [[ -z "$file" ]]; then
    design-score-usage >&2
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    echo "Error: task file not found: $file" >&2
    return 1
  fi
  if [[ "$kind" != "" && "$kind" != "code" && "$kind" != "docs" ]]; then
    echo "Error: --kind must be 'code' or 'docs'" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed." >&2
    return 1
  fi
  case "$threshold" in
    ''|*[!0-9]*) echo "Error: --threshold must be a non-negative integer" >&2; return 1 ;;
  esac

  [[ -z "$kind" ]] && kind="$(ds-detect-kind "$file")"

  # Each check's own ceiling — a relative weight, not a slice hand-tuned to
  # sum to 100. Adding an 8th check later means adding one line here (its
  # function + its max) and folding it into max_sum; nothing else needs
  # rebalancing, because raw/max is normalized to a 0-100 percentage below
  # rather than summed directly. (Plain scalars, not an associative array —
  # keeps this bash-3.2-compatible like the rest of the script.)
  local c1_max=20 c2_max=28 c3_max=10 c4_max=6 c5_max=16 c6_max=18 c7_max=6
  local max_sum=$(( c1_max + c2_max + c3_max + c4_max + c5_max + c6_max + c7_max ))

  local c1 c2 c3 c4 c5 c6 c7 pen raw pct total
  c1="$(ds-check-c1 "$file")"
  c2="$(ds-check-c2 "$file")"
  c3="$(ds-check-c3 "$file" "$kind")"
  c4="$(ds-check-c4 "$file")"
  c5="$(ds-check-c5 "$file")"
  c6="$(ds-check-c6 "$file" "$kind")"
  c7="$(ds-check-c7 "$file")"
  pen="$(ds-check-placeholder "$file")"

  raw=$(( c1 + c2 + c3 + c4 + c5 + c6 + c7 ))
  # round(100 * raw / max_sum) — always on a 0-100 scale regardless of how
  # many points the individual checks' ceilings happen to sum to.
  pct=$(( (100 * raw + max_sum/2) / max_sum ))
  total=$(( pct + pen ))
  [[ "$total" -lt 0 ]] && total=0   # floor at 0

  local pass="false" rc=1
  if [[ "$total" -ge "$threshold" ]]; then pass="true"; rc=0; fi

  if [[ "$json" -eq 1 ]]; then
    jq -n \
      --argjson score "$total" \
      --argjson threshold "$threshold" \
      --argjson pass "$pass" \
      --arg kind "$kind" \
      --argjson c1 "$c1" --argjson c2 "$c2" --argjson c3 "$c3" \
      --argjson c4 "$c4" --argjson c5 "$c5" --argjson c6 "$c6" \
      --argjson c7 "$c7" --argjson pen "$pen" \
      '{score:$score, threshold:$threshold, pass:$pass, kind:$kind,
        checks:{C1:$c1, C2:$c2, C3:$c3, C4:$c4, C5:$c5, C6:$c6, C7:$c7,
                placeholder:$pen}}'
  else
    local verdict="FAIL"; [[ "$pass" == "true" ]] && verdict="PASS"
    cat <<EOF
design-score: $file  (kind: $kind)

  C1  Frontmatter completeness ........ ${c1}/${c1_max}
  C2  §Common section presence ........ ${c2}/${c2_max}
  C3  §Code-only handling ............. ${c3}/${c3_max}
  C4  Test plan has a checkbox ........ ${c4}/${c4_max}
  C5  Done-criteria mapping .......... ${c5}/${c5_max}
  C6  Evidence-anchor density ........ ${c6}/${c6_max}
  C7  Alternatives-rejected ........... ${c7}/${c7_max}
  ------------------------------------------------
  Raw .................................. ${raw}/${max_sum}  → ${pct}/100
      Placeholder penalty ............ ${pen}
  ------------------------------------------------
  Total .............................. ${total}/100   (threshold ${threshold})

  $verdict
EOF
  fi

  return "$rc"
}

# Run only when executed directly (not when sourced). The :- guards keep this
# safe under `set -u` when sourced in a context that has not populated
# BASH_SOURCE (e.g. `bash -c 'source …'`).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  design-score "$@"
fi
