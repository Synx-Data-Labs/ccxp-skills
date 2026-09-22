---
name: proof-read
description: Use when a markdown doc needs a sentence-level consistency check (flags, does not fix) — term drift, undefined jargon vs glossary, word↔ASCII-figure mismatches, broken refs, CN↔EN
disable-model-invocation: false
argument-hint: <md-file> [<parallel-md-file>] [--glossary <tsv>] [--glossary-md <glossary.md>] [--report <path>]
---

Proof-read one or two markdown documents for self- and cross-consistency. The skill **surfaces findings**; it does not auto-edit. Human judgment decides how to resolve each finding.

## Argument

`$ARGUMENTS` contains:

- **Mode A (single doc):** `/proof-read path/to/doc.md`
- **Mode B (parallel docs):** `/proof-read path/to/cn.md path/to/en.md`
- Optional `--glossary <tsv>` — seed term mappings (TSV `cn<TAB>en`). If omitted, the skill infers a glossary from the doc(s).
- Optional `--glossary-md <path>` — the canonical coined-term glossary to run the undefined-jargon check (3f) against (default: `../glossary.md`). Distinct from `--glossary`, which is the CN↔EN TSV.
- Optional `--report <path>` — write the findings report to this path instead of printing. Default: print + also save next to the input as `<basename>.proof-read-report.md`.

If no args are given, ask the user which doc(s) to check.

## Philosophy

- **Report, don't fix.** Findings are grouped by severity; the human (or a follow-up skill) applies edits. This keeps the skill composable and safe.
- **Cite lines.** Every finding includes `file:line` so the human can jump directly to the context.
- **Prefer false positives over false negatives.** Missing a real issue is worse than flagging a non-issue; the human dismisses non-issues cheaply.
- **Terseness.** The report is a checklist, not prose. One line per finding wherever possible.

## Workflow

Execute in order. Stop and report if an input is invalid or unreadable.

### 1. Resolve and read inputs

- Resolve each path (relative or absolute). Verify files exist and are readable UTF-8 markdown.
- Read the full content of each file with line numbers.
- Detect mode from arg count: 1 file → Mode A, 2 files → Mode B. Any other count → error.

### 2. Build the document model

For each input file, parse into:

- **Section tree** — heading hierarchy (`#`, `##`, `###`). Record heading text and line number.
- **Sentence list per section** — split on sentence boundaries (`。` / `.` / `!` / `?` for CJK + Latin). Preserve line numbers.
- **Fenced code blocks** — every <code>```…```</code> block. For each, detect whether it looks like an ASCII figure (contains box-drawing chars `┌ ┐ └ ┘ ─ │` or arrows `► ◄ ▲ ▼`) or a code/shell block (starts with a shebang, or contains typical code tokens).
- **Figure labels** — for each ASCII figure, extract all numeric labels (e.g. `101`, `203-1`, `205`), all boxed text snippets, and any arrow connections (source → target).
- **References** — scan prose for `Figure N`, `图 N`, `Step N`, `步骤 N`, `Module N`, `模块 N`, **and ranges** (`Figs. N-M`, `Figures N to M`, `图N-图M`, `图N至图M`). Record (reference, line, target); a range is recorded as **one entry carrying both endpoints** `(N, M)` — never split into two separate single-figure entries. Exhaustive — every occurrence in the doc, not a sample.

### 3. Mode A: self-consistency checks

Run all of the following against the single input:

#### a. Term consistency (within-doc)

- Build a frequency-weighted list of repeated multi-word terms (2+ tokens, appearing ≥ 3 times).
- Detect near-duplicate terms that may be drift: case variants, singular/plural, synonyms with the same antecedent (e.g. "cache block" vs "cache chunk").
- Flag each suspected drift with the line pairs where both variants appear.

#### b. Word ↔ ASCII-figure alignment

For each ASCII figure detected in step 2:

- Every numeric label in the figure (e.g. `205`) must be mentioned in the prose by some discoverable form ("Module 205", "步骤 205", etc.). Flag labels the prose doesn't mention.
- Every prose reference to a figure element (e.g. "Module 103") must correspond to a label inside the referenced figure. Flag dangling references.
- Box text inside the figure should share key terms with the prose section that discusses it. Flag figure text whose key nouns don't appear anywhere in the same ±50-line window.

#### c. Broken figure / section references

- `Figure N` where no `**Figure N:**` header exists — flag.
- `图 N` where no corresponding figure exists — flag.
- Cross-section references (`see Section 3.2`) that don't resolve in the heading tree — flag.

#### d. Language intrusions

- In a file expected to be one language (inferred from majority character class), flag unexpected chunks of the other language. E.g. a 20+ character CJK run inside a file that is 95% Latin.
- Known exception: code blocks, proper nouns, and figure-label quote sections. The skill uses a relaxed threshold in those contexts.

#### e. Sentence-level scan

For each sentence:

- Flag sentences ending without punctuation (except in figure code blocks and headings).
- Flag sentences whose numeric content contradicts earlier sentences (e.g. "16 KB" vs "32 KB" for the same entity — heuristic; requires a glossary or inference).
- Flag obviously truncated sentences (end with incomplete clauses, mid-word cutoff).

#### f. Undefined-jargon check (against the glossary)

Cross-check the doc's coined terms and acronyms against the canonical glossary (`--glossary-md`, default `../glossary.md`). If neither is present, **skip this check with a logged note** — never error.

- Collect candidate jargon: ALL-CAPS acronyms (≥ 2 chars, e.g. `IPM`, `WF`, `SBOM`) plus the repeated coined multi-word terms step 3a already builds.
- A candidate is **covered** if it appears as a glossary entry (a `**term**` line in the glossary doc) OR is expanded/defined inline in the doc on or before first use (e.g. "Iteration Planning Meeting (IPM)").
- Flag each uncovered candidate as **Info** — "undefined jargon: `<term>` — expand on first use, or add it to `glossary.md`." Whitelist common English/tech acronyms (`CI`, `PR`, `API`, `URL`, `JSON`, `YAML`, `HTTP`, `SQL`, …) and the doc's own heading words.
- This extends the within-doc drift detection (3a) outward to the fleet-wide canonical vocabulary, so coined terms can't silently diverge across repos.

#### g. Wall-of-text / bullet-preference check

Soft-enforces the `private-skills-repo/engineering-standards.md` "Markdown writing style" convention (prefer bullets over long prose paragraphs) — a style preference, not a structural rule, so this check is always **Info**-severity and never blocks:

- For each paragraph (a run of prose lines with no list marker, heading, or code fence), count sentences.
- Flag a paragraph as **Info** — "wall-of-text: N-sentence paragraph with no bullets — consider breaking into a list (see `engineering-standards.md` § Markdown writing style)" — when it exceeds **4 sentences** with zero list items within 3 lines above its first line or 3 lines below its last line (i.e. measured from the paragraph's own span, not a fixed point inside it).
- Known exceptions (never flagged): every paragraph inside a `## Root cause` or `## Why` section (not just the first — a multi-paragraph root-cause narrative is still one undecomposable story), quoted text (`>` blockquotes), and code/figure blocks (already excluded by the "prose lines" definition above).
- This is deliberately a nudge, not a gate — the same "report, don't fix" philosophy as every other check in this skill; a human decides whether the paragraph is a legitimate exception.

### 4. Mode B: parallel-doc consistency

Run these in addition to Mode A applied to each side:

#### a. Section alignment

- Compare heading trees between CN and EN. Flag:
  - Section count mismatches
  - Heading-order mismatches
  - A CN section whose EN counterpart has zero sentences (or vice versa)

#### b. Sentence-count parity per section

For each aligned section, compute sentence counts. Flag sections where |CN − EN| / max(CN, EN) > 0.25 (more than 25% difference) — suggests content loss or expansion in translation.

#### c. Numeric parity

- Extract every numeric token from both sides (percentages, sizes, durations, ratios, counts).
- For each value that appears in one side, confirm it appears in the corresponding section of the other side. Flag one-sided numbers. Whitelist: 1, 2, 10 (common generic integers) unless they carry units.

#### d. Glossary consistency

- Infer a CN↔EN glossary from aligned sentence pairs (first sentence of each section is usually the most reliable anchor).
- Scan the rest of the doc; flag:
  - A CN term with multiple EN translations across the doc (drift)
  - An EN term that back-translates to multiple CN terms (drift in the other direction)
- If the user passed `--glossary`, use that as the authoritative mapping and flag any deviations.

#### e. Figure parity

- Both sides should have the same number of ASCII figures with the same structural shape:
  - Same number of boxes
  - Same number of arrows
  - Same set of numeric labels (101, 102, …, 205)
  - Same arrow topology (box A → box B should correspond on both sides)
- Flag any structural mismatches with specific labels.

#### f. Figure-reference number diff (CN↔EN)

Catches off-by-one and other reference-number drift that (e) "Figure parity" and (c) "Numeric
parity" can miss. (e) compares **ASCII-diagram structure** — box/arrow/label counts pulled from
fenced code blocks — a completely different artifact from prose figure citations; it has no
visibility into prose text at all. (c) diffs numeric tokens per aligned section without pairing
them to specific figure citations, so a shifted reference can dodge it if some unrelated number
in the section still happens to line up. A uniform off-by-one shift across a range (e.g. CN
`图2-图5` → EN "Figs. 1-4") is exactly the kind of drift neither check is positioned to catch.
(T20260804-151091: this is the defect class that slipped through undetected on one patent while
being caught on another, because the prior implementation only compared citations adjacent to a
figure heading rather than diffing every occurrence.)

- From the References list built in step 2 (now including ranges), take EVERY occurrence on both
  sides — do not sample or restrict to references adjacent to a figure heading.
- **Each reference is one entry** — a single reference is the numeral itself (`5`); a range is
  the pair of its endpoints (`(2, 5)`), never decomposed into two separate single-figure entries.
  (Decomposing a range would let it spuriously "match" unrelated single references to its
  endpoint numbers elsewhere in the section.)
- Within each section already aligned by (4a), build the **multiset** of CN reference entries and
  the multiset of EN reference entries — order-independent, duplicates counted (two separate
  "Figure 3" mentions count as two entries of that value).
- **Compare the two multisets, not a positional pairing** — prose can legitimately reorder figure
  mentions across a translation (e.g. a section citing the same two figures twice each may not
  cite them in the same order on both sides), so pairing by document position produces spurious
  flags on a correct translation. Multiset comparison is order-independent by construction and
  needs no separate handling for a reference-count difference — a dropped, added, or renumbered
  reference always shows up as an unequal multiset:
  - **Equal multisets** — no flag, regardless of order.
  - **Unequal multisets** — **Error**: "figure-reference number mismatch in this section: CN
    cites `{<CN multiset>}` (e.g. line N), EN cites `{<EN multiset>}` (e.g. line M) — sets don't
    match." Cite one representative line per side — the first occurrence of a value/range present
    on only one side.

### 5. Emit findings report

Write a markdown report with this shape:

```markdown
# Proof-read report

**Mode:** A (single doc) / B (parallel)
**Inputs:**
- `<cn.md>` (<N> sentences in <M> sections)
- `<en.md>` (…)  <!-- Mode B only -->

**Summary:**
- Errors: N (blocks publication)
- Warnings: N (review recommended)
- Info: N (context / potential drift)

---

## Errors

### E1. <short title>
- **Where:** `file:line`
- **What:** one-sentence description
- **Why it matters:** one-sentence consequence
- **Suggested check:** one-sentence human action

### E2. …

## Warnings

### W1. …

## Info

### I1. …

---

## Glossary inferred (Mode B)

| CN | EN | Occurrences |
|---|---|---|
| 缓存块 | cache block | 42 |
| 合并块 | merged block | 37 |
| … | | |
```

Severity rubric:

- **Error** — will confuse a reader or break a reference (broken Figure link, missing numeric parity, figure-reference number mismatch, figure/prose contradiction).
- **Warning** — inconsistency that a reviewer should spot-check (term drift, sentence-count skew).
- **Info** — potential drift worth knowing but not actionable (rare-term variants, 1-2 one-sided numbers).

### 6. Final output

Report to the user:

- Report location (path)
- Severity counts (`X errors, Y warnings, Z info`)
- Top 5 findings by severity, inlined
- If **0 errors**, say "clean"; the human can still scan warnings/info at leisure.

## Composability

This skill is designed to be invoked from other skills (e.g. `translate-patent` calls `/proof-read` after extraction and after translation). When invoked programmatically, the caller should:

- Pass `--report <deterministic-path>` so the output is predictable
- Check the exit code: `0` = no errors, `1` = errors present (caller decides whether to block or continue)

## Out of scope

- **Auto-fixing.** This skill only surfaces. A future `fix-findings` skill (not yet filed) would consume the report and propose edits.
- **Grammar.** Grammar checking is a different discipline — use LanguageTool or an LLM grammar-check pass. This skill focuses on structural and consistency defects.
- **Non-markdown inputs.** DOCX, HTML, PDF are out of scope. If the caller has those, convert to markdown first (e.g. via `translate-patent`'s pandoc step).
- **Languages other than CN + EN.** Easy to extend later; not needed for the defrag patent pipeline v1.

## Important notes

- Use the `Read` tool for all file reads; do not shell out with `cat`.
- When computing heading trees and sentence splits, prefer deterministic parsing over LLM inference — the reader will re-run this skill and expects stable output across runs.
- **Do not edit the input files.** Ever. If the user wants auto-fix, they can run an edit pass afterward.
- When inferring a glossary in Mode B without `--glossary`, cap the inference at the top 30 most-frequent aligned terms — beyond that, precision drops.
- If the doc contains obvious garbage (binary content, encoding errors), fail fast with a clear error rather than producing a noisy report.
- Output report encoding is UTF-8; CJK characters must render correctly in the report.
