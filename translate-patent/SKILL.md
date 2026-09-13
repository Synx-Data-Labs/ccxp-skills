---
name: translate-patent
description: Use when the user explicitly asks to translate a patent DOCX from Chinese to English (extract, translate, ASCII-diagram the images)
disable-model-invocation: false
argument-hint: <path-to-docx> [--target-lang en] [--cn-only|--en-only] [--no-proofread] [--no-pdf]
---

Translate a Chinese patent DOCX into attorney-ready CN+EN markdown (and PDF) with text-based diagrams on both sides.

## Argument

`$ARGUMENTS` contains:

- A path to a `.docx` file: `/translate-patent confidential/legal/patent/zh/draft.docx`
- Optional `--target-lang` (default: `en`): `/translate-patent draft.docx --target-lang en`
- Optional `--cn-only` — produce only the Chinese-side deliverables (CN MD, CN PDF, CN self-consistency proof-read); skip English translation and everything that depends on it (EN MD/PDF, Mode B proof-read). Mutually exclusive with `--en-only`.
- Optional `--en-only` — skip only the CN-side *final deliverables* (standalone CN PDF, standalone CN proof-read report). CN extraction and CN-side ASCII-figure generation (steps 1-6) still run internally regardless — the English translation's ASCII figures are derived from the CN figures (step 7), so CN generation is a hard prerequisite, not an optional stage. Mutually exclusive with `--cn-only`.
- Optional `--no-proofread` — skip step 9 (`/proof-read`) entirely.
- Optional `--no-pdf` — skip step 10 (`/md-to-pdf`) entirely.
- If no path given, prompt the user for one.

## Workflow

Execute these steps in order. Stop and report if any step fails.

### 1. Locate and validate input

- Resolve the DOCX path (relative to project root or absolute)
- Verify the file exists and has `.docx` extension
- Determine the output directory:
  - If the DOCX is inside a `zh/` folder, create a sibling `en/` folder
  - Otherwise, create an `en/` folder next to the DOCX
- If the `en/` folder already has a translated `.md` file, ask the user before overwriting
- `--cn-only`: the `en/` sibling-directory check above is skipped (no English output will be written). `--en-only`: the CN-side directory is still created and used internally — see the `--en-only` note under `## Argument`.

### 2. Extract content with pandoc

```bash
cd "<docx-parent-dir>"
pandoc "<filename>.docx" -t markdown --extract-media=media -o "<filename>.md"
```

- This produces a `.md` file and a `media/` folder with extracted images
- If pandoc is not installed, tell the user: `brew install pandoc`

### 3. Clean up pandoc output

- Flatten nested media paths (e.g., `media/media/image1.png` → `media/image1.png`)

  ```bash
  # If media/media/ exists, move files up one level
  if [ -d media/media ]; then
    mv media/media/* media/
    rmdir media/media
  fi
  ```

- Update image references in the `.md` file to match flattened paths
- Remove pandoc artifacts: `{width="..." height="..."}` attributes from image references
- Remove Windows-style absolute paths from image alt text (e.g., `C:/Users/...`)

### 4. Inventory images

- Read each extracted image file using the Read tool (to see it visually)
- For each image, note:
  - What it depicts (flowchart, architecture diagram, data flow, etc.)
  - All text labels, numbers, arrows, and their relationships
  - The logical flow direction (top-to-bottom, left-to-right, etc.)
- This inventory drives accurate ASCII diagram generation in step 5

### 5. Generate CN-side ASCII diagrams

Figures are generated **CN-first** — this is the single source of truth for both languages (see step 7). For each image identified in step 4, replace its `![]()` reference in the Chinese `.md` with a text-based diagram using box-drawing characters.

**Box-drawing character set:**

- Boxes: `┌ ┐ └ ┘ ─ │`
- Arrows: `► ◄ ▲ ▼ ─ │ ┬ ┴ ├ ┤`
- Flow: `▼` for downward, `►` for rightward

**Rules:**

- Match the logical structure of the original image exactly
- Include all labels, reference numbers, and annotations
- Use consistent box widths within a diagram (pad shorter labels with spaces)
- Align columns cleanly — boxes in the same column should have the same width
- Keep lines within 72 characters wide where possible
- Wrap in triple-backtick code blocks
- Emit the caption as a `####` heading immediately before the diagram: `#### 图 N：<caption>` — a real heading, not a bold paragraph. This is required for `patent-pdf-extra.css`'s `h4` caption rules (step 10) to have any effect.

**Example flowchart style:**

```
┌───────────────────────────────┐
│ Step description              │     101
└───────────────┬───────────────┘
                │
                ▼
┌───────────────────────────────┐
│ Next step description         │     102
└───────────────────────────────┘
```

**Example system architecture style:**

```
  Input A          Input B
     │                │
     ▼                ▼
┌──────────┐   ┌──────────┐
│ Module 1 │──►│ Module 2 │
└──────────┘   └────┬─────┘
                    │
                    ▼
               ┌──────────┐
               │ Module 3 │
               └──────────┘
```

### 6. Review and clean up CN ASCII diagrams

**This is a mandatory review pass.** After generating all CN diagrams, go back and check each one:

1. **Alignment audit** — Verify all box edges line up vertically. Characters in the same column must be the same character across all lines. Look for off-by-one alignment errors.
2. **Arrow continuity** — Every arrow must connect from a box edge to another box edge or label. No floating arrows.
3. **Label completeness** — Every label and reference number from the original image must appear in the ASCII diagram.
4. **Consistent box widths** — Boxes at the same hierarchical level should have the same width.
5. **Render test** — Read the final `.md` file and visually inspect each diagram in the Read tool output. If any diagram looks broken, fix it.
6. **Compare with original** — Re-read each original image and compare side-by-side with the ASCII version. Fix any discrepancies.

If any issues are found, edit the diagram and re-check. Do not skip this step. The English side (step 7) reuses these figures rather than re-deriving them, so a defect here propagates to both languages — get it right once, here.

### 7. Translate markdown to English

Skip this step (and all remaining EN-side work) if `--cn-only` was passed.

- Read the full cleaned-up, ASCII-figured Chinese `.md` file (post steps 5-6)
- Translate to English, preserving:
  - Patent claim structure and numbering (权利要求 → Claims)
  - Technical terminology consistency throughout the document
  - Section headings (技术领域 → Technical Field, 背景技术 → Background Art, 发明内容 → Summary of the Invention, 附图说明 → Description of Drawings, 具体实施方式 → Detailed Description of Embodiments)
  - Reference numbers (101, 102, 201, 203-1, etc.)
  - All performance metrics and numerical values exactly as stated
- For each CN ASCII figure from step 5, **carry it into the English MD and translate only the box-label text** — do not regenerate the diagram from the source image independently. Emit the caption as a `#### Figure N: <english caption>` heading (translated from the CN `#### 图 N：` heading, same heading level).
- Write the translated `.md` to the `en/` directory with an English filename
- Copy original images to `en/media/` as reference

### 8. Post-process CN and EN markdown

Run `translate-patent/scripts/postprocess.py` on the CN `.md`:

```bash
python3 translate-patent/scripts/postprocess.py "<cn.md>" --lang zh --in-place
```

Unless `--cn-only` was passed, also run it on the EN `.md`:

```bash
python3 translate-patent/scripts/postprocess.py "<en.md>" --lang en --in-place
```

This applies, per language, in one deterministic pass:

- filing-part + in-spec section heading promotion (the four `#` part headings plus the five `##` section headings)
- global figure renumbering (descending replace order, so the abstract drawing stays 图1/Figure 1 and appendix figures continue 图2, 图3, …)
- figure pagination-split at single-box top borders (so `/md-to-pdf` never severs a box mid-border)
- Word PUA-bullet stripping (tofu bullets from DOCX extraction)
- claim-number escaping (`1.` → `1\.`, so markdown doesn't renumber the claim set) and claim-continuation dedent (so an escaped, indented continuation line doesn't become an unwrapped code block)

`--lang` is passed explicitly here (rather than relying on the script's auto-detect) since the caller already knows which file is which. The script itself supports omitting `--lang` and auto-detecting from CJK-vs-Latin character-class majority, for standalone use. The script is idempotent — re-running it on an already-processed file is a no-op — so it is safe to re-run this step alone (e.g. after a manual edit) without re-running the whole skill.

### 9. Proof-read

Skip this step entirely if `--no-proofread` was passed.

- Invoke `/proof-read` Mode A on the post-processed CN MD alone (self-consistency), unless `--en-only` was passed — `--en-only` skips the standalone CN proof-read report per its definition under `## Argument`.
- Unless `--cn-only` was passed, invoke `/proof-read` Mode B on the CN + EN MDs together (cross-language consistency, including the figure-parity check).
- Findings are surfaced only — do not auto-edit based on the report, per `/proof-read`'s own contract (`proof-read/SKILL.md` § Out of scope).

### 10. Generate PDFs

Skip this step entirely if `--no-pdf` was passed.

Invoke `/md-to-pdf` on the post-processed CN MD (unless `--en-only` was passed):

```bash
/md-to-pdf "<cn.md>" --extra-css translate-patent/patent-pdf-extra.css
```

And on the post-processed EN MD (unless `--cn-only` was passed):

```bash
/md-to-pdf "<en.md>" --extra-css translate-patent/patent-pdf-extra.css
```

Each PDF is produced next to its MD: `<lang>/<basename>.pdf`. `/md-to-pdf` runs its own font/weasyprint preflight (`md-to-pdf/SKILL.md` step 7) — do not reimplement that check here.

### 11. Final output

Report to the user:

- Source: `<path to original DOCX>`
- Extracted Chinese MD: `<path>`
- Translated English MD: `<path>` (omit if `--cn-only`)
- Images: `<count>` original images, `<count>` ASCII diagrams generated (CN-side count; EN reuses the same figures)
- Reference images copied to: `en/media/` (omit if `--cn-only`)
- Post-process status per language run (step 8): CN `<ok|skipped>`, EN `<ok|skipped|n/a — --cn-only>`
- Proof-read (step 9, omit entirely if `--no-proofread`): report path(s), and error/warning/info counts per report
- CN PDF path (step 10, omit if `--no-pdf` or `--en-only`)
- EN PDF path (step 10, omit if `--no-pdf` or `--cn-only`)

Note: The original images in `en/media/` are kept as reference. The translated `.md` uses ASCII diagrams instead of image references, on both the CN and EN side.
