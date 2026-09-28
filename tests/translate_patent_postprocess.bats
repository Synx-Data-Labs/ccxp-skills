#!/usr/bin/env bats
# Tests for translate-patent/scripts/postprocess.py — the deterministic
# post-processor that folds the 11 patent-specific rendering fixes hand-
# applied to the defrag patent's files on 2026-06-04/05 back into
# translate-patent (T20260422-113041).
#
# postprocess.py is a Python script (not sourced); invoked directly, mirroring
# tests/lint_frozen.bats's precedent for calling repo-conventions'
# lint_tasks.py from BATS (command -v python3 >/dev/null || skip).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/translate-patent/scripts/postprocess.py"
FIX="$SCRIPT_DIR/fixtures/translate-patent"

setup() {
  command -v python3 >/dev/null || skip "python3 unavailable"
  [ -f "$SCRIPT" ] || skip "postprocess.py not found"
}

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

@test "postprocess.py exists" {
  [ -f "$SCRIPT" ]
}

@test "missing input file errors cleanly with non-zero exit" {
  run python3 "$SCRIPT" "$FIX/does-not-exist.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# Item 6 + 7: claim-number escaping + continuation dedent
# ---------------------------------------------------------------------------

@test "EN claims: claim numbers are escaped (1. -> 1\\.)" {
  run python3 "$SCRIPT" "$FIX/claims_en.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *'1\. A method comprising:'* ]]
  [[ "$output" == *'2\. The method of claim 1, wherein'* ]]
  [[ "$output" == *'3\. The method of claim 1, further comprising'* ]]
  # unescaped forms must be gone
  [[ "$output" != *$'\n1. A method'* ]]
}

@test "EN claims: indented continuation lines are dedented flush-left" {
  run python3 "$SCRIPT" "$FIX/claims_en.md" --lang en
  [ "$status" -eq 0 ]
  # the continuation line must appear with NO leading whitespace
  [[ "$output" == *$'\nperforming a first step; and\n'* ]]
  [[ "$output" == *$'\nthe first step includes scanning a plurality of blocks.\n'* ]]
  # must NOT still be indented (would render as a code block)
  [[ "$output" != *$'\n    performing a first step'* ]]
}

@test "ZH claims: claim numbers are escaped and continuations dedented" {
  run python3 "$SCRIPT" "$FIX/claims_zh.md" --lang zh
  [ "$status" -eq 0 ]
  [[ "$output" == *'1\. 一种方法，包括：'* ]]
  [[ "$output" == *$'\n执行第一步骤；以及\n'* ]]
  [[ "$output" != *$'\n    执行第一步骤'* ]]
}

@test "claim escaping is idempotent (second run is a no-op)" {
  run python3 "$SCRIPT" "$FIX/claims_en.md" --lang en
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang en
  [ "$output" = "$first" ]
}

# ---------------------------------------------------------------------------
# Item 13: PUA-bullet stripping
# ---------------------------------------------------------------------------

@test "PUA bullets: labeled item becomes a bold lead-in" {
  run python3 "$SCRIPT" "$FIX/pua_bullets.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *'**Label A:** description of label A'* ]]
  [[ "$output" == *'**Second Label:** another labeled item'* ]]
}

@test "PUA bullets: bare bullet becomes a plain paragraph (no bullet glyph)" {
  run python3 "$SCRIPT" "$FIX/pua_bullets.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *'just a bare bullet without colon'* ]]
  # no PUA codepoint (U+E000-U+F8FF) should survive anywhere in the output.
  # Built via chr()/ord() rather than a literal PUA char or \uXXXX escape in
  # this .bats file, to avoid any editor/pipeline mangling of an
  # invisible-glyph character range (see postprocess.py's own PUA_RE comment).
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/translate-patent/scripts')
import postprocess as pp
text = open('$FIX/pua_bullets.md', encoding='utf-8').read()
out = pp.postprocess_text(text, 'en')
lo, hi = 0xE000, 0xF8FF
assert not any(lo <= ord(c) <= hi for c in out), 'PUA char survived'
print('clean')
"
  [ "$status" -eq 0 ]
  [[ "$output" == "clean" ]]
}

# ---------------------------------------------------------------------------
# Item 15: global figure renumbering (descending order, both spacing
# variants, in-text references)
# ---------------------------------------------------------------------------

@test "ZH figures: appendix figures shift +1, abstract drawing untouched" {
  run python3 "$SCRIPT" "$FIX/figures_zh.md" --lang zh
  [ "$status" -eq 0 ]
  # abstract drawing caption (图 1, spaced variant) is unchanged
  [[ "$output" == *'#### 图 1：抽象结构图'* ]]
  # appendix figures shifted: 图1 -> 图2, 图2 -> 图3 (unspaced variant)
  [[ "$output" == *'#### 图2：结构框图'* ]]
  [[ "$output" == *'#### 图3：流程图'* ]]
  # no stray un-shifted appendix "图1" remains
  [[ "$output" != *'#### 图1：结构框图'* ]]
}

@test "ZH figures: in-text references are renumbered too, not just captions" {
  run python3 "$SCRIPT" "$FIX/figures_zh.md" --lang zh
  [ "$status" -eq 0 ]
  [[ "$output" == *'如图2所示，装置包括如下部件'* ]]
  [[ "$output" == *'如图3所述，进一步说明如下，参见图3中的流程'* ]]
}

@test "EN figures: appendix figures shift +1, abstract drawing untouched" {
  run python3 "$SCRIPT" "$FIX/figures_en.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *'#### Figure 1: Abstract structural diagram'* ]]
  [[ "$output" == *'#### Figure 2: Structural block diagram'* ]]
  [[ "$output" == *'#### Figure 3: Flow diagram'* ]]
  [[ "$output" == *'As shown in Figure 2, the apparatus'* ]]
  [[ "$output" == *'As further described in Figure 3, see the flow in Figure 3 below'* ]]
}

@test "figure renumbering is idempotent (second run does not double-shift)" {
  run python3 "$SCRIPT" "$FIX/figures_zh.md" --lang zh
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang zh
  [ "$output" = "$first" ]
  # sanity: the appendix must NOT have shifted a second time to 图3/图4
  [[ "$output" != *'#### 图4：流程图'* ]]
}

# ---------------------------------------------------------------------------
# Item 11: figure pagination-split
# ---------------------------------------------------------------------------

@test "pagination: a two-box flowchart splits into two fenced blocks" {
  run python3 "$SCRIPT" "$FIX/pagination_split.md" --lang en
  [ "$status" -eq 0 ]
  # two separate closing+opening fence pairs now exist around the split
  local fence_count
  fence_count="$(grep -c '^```$' <<<"$output")"
  [ "$fence_count" -ge 4 ]
  # each half keeps its own box intact
  [[ "$output" == *'│ Step description              │     101'* ]]
  [[ "$output" == *'│ Next step description         │     102'* ]]
  # the second box's top border starts its own new fenced block
  [[ "$output" == *$'```\n┌───────────────────────────────┐\n│ Next step description'* ]]
}

@test "pagination: side-by-side two-box line is NOT split (negative case)" {
  run python3 "$SCRIPT" "$FIX/pagination_no_split.md" --lang en
  [ "$status" -eq 0 ]
  # exactly one fenced block survives (open+close = 2 fence lines)
  local fence_count
  fence_count="$(grep -c '^```$' <<<"$output")"
  [ "$fence_count" -eq 2 ]
  [[ "$output" == *'┌──────────┐   ┌──────────┐'* ]]
}

@test "pagination-split is idempotent (second run does not re-split)" {
  run python3 "$SCRIPT" "$FIX/pagination_split.md" --lang en
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang en
  [ "$output" = "$first" ]
}

# ---------------------------------------------------------------------------
# Item 5: filing-part + section heading promotion
# ---------------------------------------------------------------------------

@test "ZH headings: all four part headings promoted to '# '" {
  run python3 "$SCRIPT" "$FIX/headings_zh.md" --lang zh
  [ "$status" -eq 0 ]
  grep -qxF '# 说明书摘要' <<<"$output"
  grep -qxF '# 摘要附图' <<<"$output"
  grep -qxF '# 权利要求书' <<<"$output"
  grep -qxF '# 说明书' <<<"$output"
}

@test "ZH headings: all five section titles promoted to '## '" {
  run python3 "$SCRIPT" "$FIX/headings_zh.md" --lang zh
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n## 技术领域\n'* ]]
  [[ "$output" == *$'\n## 背景技术\n'* ]]
  [[ "$output" == *$'\n## 发明内容\n'* ]]
  [[ "$output" == *$'\n## 附图说明\n'* ]]
  [[ "$output" == *$'\n## 具体实施方式\n'* ]]
}

@test "EN headings: all four part headings promoted to '# '" {
  run python3 "$SCRIPT" "$FIX/headings_en.md" --lang en
  [ "$status" -eq 0 ]
  grep -qxF '# Abstract' <<<"$output"
  grep -qxF '# Abstract Drawing' <<<"$output"
  grep -qxF '# Claims' <<<"$output"
  grep -qxF '# Specification' <<<"$output"
}

@test "EN headings: all five section titles promoted to '## '" {
  run python3 "$SCRIPT" "$FIX/headings_en.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n## Technical Field\n'* ]]
  [[ "$output" == *$'\n## Background Art\n'* ]]
  [[ "$output" == *$'\n## Summary of the Invention\n'* ]]
  [[ "$output" == *$'\n## Description of Drawings\n'* ]]
  [[ "$output" == *$'\n## Detailed Description of Embodiments\n'* ]]
}

# ---------------------------------------------------------------------------
# Item 5, part 1 / regression: filing-part heading INSERTION on a genuinely
# raw, unlabeled document -- the four part headings never exist as literal
# text in a raw CN patent extraction, so promote_headings() alone can never
# create them (this was the actual attorney-facing "no set of claims" bug:
# escape_claim_numbers()/dedent_claim_continuations()/renumber_figures() all
# silently no-op when their '# 权利要求书' / '# 摘要附图' anchors don't exist).
# These fixtures have NO part-level headings anywhere, modeled in miniature
# on the real defrag patent's structure (abstract -> abstract-drawing figure
# -> claims list -> repeated title -> spec sections -> appendix figures).
# ---------------------------------------------------------------------------

@test "ZH raw doc: all five headings get inserted with no pre-existing literal text" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_zh.md" --lang zh
  [ "$status" -eq 0 ]
  grep -qxF '# 说明书摘要' <<<"$output"
  grep -qxF '# 摘要附图' <<<"$output"
  grep -qxF '# 权利要求书' <<<"$output"
  grep -qxF '# 说明书' <<<"$output"
  grep -qxF '# 附图' <<<"$output"
  # '# 说明书摘要' must be the very first line
  [ "$(head -n1 <<<"$output")" = "# 说明书摘要" ]
}

@test "ZH raw doc: claim escaping and dedent now fire (the regression this fixes)" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_zh.md" --lang zh
  [ "$status" -eq 0 ]
  # claim 2 (period-numbered) is escaped and its continuation dedented flush-left
  [[ "$output" == *'2\. 根据权利要求1所述的方法'* ]]
  [[ "$output" == *$'\n将小文件合并为缓存块。\n'* ]]
  [[ "$output" != *$'\n    将小文件合并为缓存块'* ]]
}

@test "ZH raw doc: figure renumbering now fires (abstract=图1, appendix=图2/图3)" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_zh.md" --lang zh
  [ "$status" -eq 0 ]
  [[ "$output" == *'#### 图 1：小文件合并方法的流程图'* ]]
  [[ "$output" == *'#### 图2：小文件合并方法的流程图'* ]]
  [[ "$output" == *'#### 图3：小文件合并系统的结构图'* ]]
  # in-text references in 附图说明 + 具体实施方式 renumbered too, not just captions
  [[ "$output" == *'图2示出了本申请实施例的一种小文件合并方法的流程图'* ]]
  [[ "$output" == *'图3示出了本申请实施例的一种小文件合并系统的结构图'* ]]
  [[ "$output" == *'具体地参照图2，图2示出了'* ]]
  [[ "$output" == *'具体地参照图3，图3示出了'* ]]
}

@test "ZH raw doc: '# 说明书' lands before the repeated invention-title line" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_zh.md" --lang zh
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n# 说明书\n\n小文件合并方法及系统\n'* ]]
}

@test "ZH raw doc: full run is idempotent (second run inserts nothing new)" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_zh.md" --lang zh
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang zh
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  # sanity: exactly one of each part heading, not duplicated
  [ "$(grep -cxF '# 说明书' <<<"$output")" -eq 1 ]
  [ "$(grep -cxF '# 权利要求书' <<<"$output")" -eq 1 ]
}

@test "EN raw doc: all five headings get inserted with no pre-existing literal text" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_en.md" --lang en
  [ "$status" -eq 0 ]
  grep -qxF '# Abstract' <<<"$output"
  grep -qxF '# Abstract Drawing' <<<"$output"
  grep -qxF '# Claims' <<<"$output"
  grep -qxF '# Specification' <<<"$output"
  grep -qxF '# Drawings' <<<"$output"
  [ "$(head -n1 <<<"$output")" = "# Abstract" ]
}

@test "EN raw doc: claim escaping and figure renumbering now fire" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_en.md" --lang en
  [ "$status" -eq 0 ]
  [[ "$output" == *'2\. The method according to claim 1'* ]]
  [[ "$output" == *$'\nmerging the small files into cache blocks.\n'* ]]
  [[ "$output" != *$'\n    merging the small files'* ]]
  [[ "$output" == *'#### Figure 1: Flowchart of the small file merging method'* ]]
  [[ "$output" == *'#### Figure 2: Flowchart of the small file merging method'* ]]
  [[ "$output" == *'#### Figure 3: Structural diagram of the small file merging system'* ]]
  [[ "$output" == *'Specifically referring to Figure 2, Figure 2 shows'* ]]
  [[ "$output" == *'Specifically referring to Figure 3, Figure 3 shows'* ]]
}

@test "EN raw doc: full run is idempotent (second run inserts nothing new)" {
  run python3 "$SCRIPT" "$FIX/raw_unlabeled_en.md" --lang en
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang en
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(grep -cxF '# Specification' <<<"$output")" -eq 1 ]
  [ "$(grep -cxF '# Claims' <<<"$output")" -eq 1 ]
}

@test "heading promotion is idempotent (already-promoted heading untouched)" {
  run python3 "$SCRIPT" "$FIX/headings_en.md" --lang en
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang en
  [ "$output" = "$first" ]
}

# ---------------------------------------------------------------------------
# Language auto-detection
# ---------------------------------------------------------------------------

@test "auto-detect: a majority-CJK doc is treated as zh without --lang" {
  run python3 "$SCRIPT" "$FIX/claims_zh.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'1\. 一种方法，包括：'* ]]
}

@test "auto-detect: a majority-Latin doc is treated as en without --lang" {
  run python3 "$SCRIPT" "$FIX/claims_en.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'1\. A method comprising:'* ]]
}

# ---------------------------------------------------------------------------
# CLI output modes: --in-place / -o / stdout
# ---------------------------------------------------------------------------

@test "-o writes the result to the given path, stdout stays empty" {
  local out="$BATS_TEST_TMPDIR/out.md"
  run python3 "$SCRIPT" "$FIX/claims_en.md" --lang en -o "$out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$out" ]
  grep -q '1\\. A method comprising:' "$out"
}

@test "--in-place overwrites the input file" {
  local tmp="$BATS_TEST_TMPDIR/inplace.md"
  cp "$FIX/claims_en.md" "$tmp"
  run python3 "$SCRIPT" "$tmp" --lang en --in-place
  [ "$status" -eq 0 ]
  grep -q '1\\. A method comprising:' "$tmp"
}

@test "--in-place and -o are mutually exclusive" {
  run python3 "$SCRIPT" "$FIX/claims_en.md" --lang en --in-place -o "$BATS_TEST_TMPDIR/x.md"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Full-pipeline idempotency (the repo-wide "running twice = same output" rule)
# ---------------------------------------------------------------------------

@test "full pipeline: running postprocess.py twice on its own output is a no-op" {
  run python3 "$SCRIPT" "$FIX/idempotent.md" --lang zh
  [ "$status" -eq 0 ]
  local first="$output"
  echo "$first" > "$BATS_TEST_TMPDIR/once.md"
  run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/once.md" --lang zh
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "full pipeline: combined fixture gets every transform applied together" {
  run python3 "$SCRIPT" "$FIX/idempotent.md" --lang zh
  [ "$status" -eq 0 ]
  grep -qxF '# 说明书摘要' <<<"$output"               # part heading promoted
  [[ "$output" == *'1\. 一种方法，包括：'* ]]          # claim escaped
  [[ "$output" == *$'\n执行第一步骤；以及\n'* ]]         # continuation dedented
  [[ "$output" == *'#### 图2：结构框图'* ]]           # figure renumbered
  [[ "$output" == *'如图2所示'* ]]                    # in-text ref renumbered
  local fence_count
  fence_count="$(grep -c '^```$' <<<"$output")"
  [ "$fence_count" -ge 6 ]                            # the 101/102 figure split into 2 blocks
}
