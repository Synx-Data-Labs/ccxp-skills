---
name: md-to-pdf
description: Convert markdown to PDF with scaled images, preserved line breaks, and CJK/special character support
disable-model-invocation: false
argument-hint: <path-to-md> [--img-width 60] [--output path.pdf] [--extra-css path]
---

Convert a markdown file to a well-formatted PDF. Handles documents that may mix English and CJK (e.g. Chinese legal documents, bilingual notes, mostly-English memos with occasional CJK).

## Features

- **Line breaks preserved**: every newline in the `.md` becomes a line break in the PDF (not joined into a paragraph)
- **Images scaled**: images are capped at 60% page width by default (configurable)
- **Special characters**: emoji rendered via Apple Color Emoji; CJK punctuation normalized; smart quotes straightened; symbols outside Latin+GB coverage (e.g. `↔`) forced to Apple Symbols so they never hit the `.LastResort` boxed-"?" glyph
- **Portable typography**: Latin-first font stack (Helvetica/Arial) with CJK fallback (Hiragino Sans GB / PingFang SC). Browsers and weasyprint do per-glyph fallback, so English glyphs use Latin fonts and CJK glyphs use CJK fonts. Result: prints cleanly in Adobe Reader / Windows / office printers, which struggle with CID-only CJK font subsets when those are forced for Latin text.
- **Table rows never split across a page break**: `tr { break-inside: avoid }` in the default CSS. A row that doesn't fit on the current page moves to the next page whole rather than splitting mid-row. `<thead>` still repeats on every page a table spans (browser/weasyprint default table layout behavior).

## Argument

`$ARGUMENTS` contains:

- A path to a `.md` file (relative or absolute). If omitted, prompt the user.
- `--img-width N` — max image width as % of page (default: 60)
- `--output path.pdf` — output path (default: same name as input with `.pdf` extension, same directory)
- `--extra-css <path>` — path to an additional CSS file appended after the default CSS in step 4's `<style>` block (optional; lets callers like `translate-patent` extend/override without forking this skill)

## Workflow

### 1. Parse arguments and validate

- Resolve the `.md` path. Verify the file exists.
- Parse `--img-width` (default 60), `--output` (default: replace `.md` → `.pdf`), and `--extra-css` (default: none).
- If `--extra-css` is given, verify that file exists (fail fast, same as the `.md` input check).
- If the output PDF already exists, tell the user before overwriting.

### 2. Pre-process the markdown

Create a temporary copy of the markdown file with these fixes applied:

**a) Fix special characters:**

- Replace curly/smart quotes (`""''`) with straight quotes (`"`, `'`)
- Normalize CJK fullwidth punctuation that may have been mangled (e.g., `，` `。` `：` `；` `？` `！` — leave them as-is if they're correct; fix mojibake if present)
- Strip zero-width spaces, byte-order marks, and other invisible Unicode (U+200B, U+FEFF, U+00A0 → regular space)

**b) Wrap stack-uncovered symbols (macOS `.LastResort` workaround):**

- On macOS, fontconfig's `.LastResort` font claims ALL codepoints, so a symbol missing from every named font in the CSS stack renders as a boxed "?" — **even if a later font in the stack covers it** (`.LastResort` outranks it in fontconfig's per-glyph sort). Known case: `↔` U+2194 — Helvetica has no arrows, and the GB-charset CJK fonts (Hiragino Sans GB / PingFang SC) cover `←↑→↓` but NOT `↔`.
- Fix in preprocessing by wrapping such characters in an explicit single-font span (verified: Apple Symbols covers them and renders correctly when named alone):

  ```python
  import re
  text = re.sub(r'[↔⇄⇆⇌⇋⟷∈∉∀∃⊕⊗≡∴∵]',
                lambda m: f'<span style="font-family: Apple Symbols">{m.group(0)}</span>', text)
  ```

- Do NOT wrap chars already covered by the stack: `— × ①②③ § ≠ ≤ ≥ → ← ↑ ↓ ¥` and emoji (Apple Color Emoji handles those).
- Skip this replacement inside fenced code blocks (raw HTML would show literally).
- Step 7's `pdffonts` `.LastResort` check is the authoritative verification — if it still appears, scan the source for the culprit char and add it to this wrap list.
- **pandoc `+emoji` gotcha**: pandoc's `emoji` extension appends an invisible U+FE0E (text-style variation selector) to emoji-capable symbols like `↔` in its HTML output. The resulting `↔+FE0E` cluster fails font shaping in EVERY font (including Apple Symbols, even inside the wrap span) and falls to `.LastResort`. Fix: strip `︎` from the generated HTML in step 4 (the same Python pass that injects CSS): `h = h.replace('︎', '')`. Leave `️` (emoji-style selector) alone — Apple Color Emoji handles those clusters.

**c) Scale image references:**

- For any image reference like `![alt](path)` or `<img src="...">`, leave the markdown as-is — image sizing is handled by CSS in step 3.
- If an image path is absolute and starts with the markdown file's directory, convert it to a relative path so weasyprint can find it.

Write the pre-processed markdown to a temp file (e.g., `/tmp/md-to-pdf-<hash>.md`).

### 3. Convert to HTML with pandoc

```bash
pandoc --from markdown+hard_line_breaks+emoji \
       --to html5 \
       --standalone \
       --metadata title="" \
       -o /tmp/md-to-pdf-<hash>.html \
       /tmp/md-to-pdf-<hash>.md
```

Key: `hard_line_breaks` makes every newline a `<br>`, which is the core line-break-preservation feature.

### 4. Post-process the HTML: strip VS15 + inject CSS

After pandoc generates the HTML, do both of these in one Python pass:

**a) Strip text-style variation selectors (U+FE0E)** that pandoc's `+emoji` extension appends to emoji-capable symbols like `↔` (see the gotcha in step 2b — the `↔+FE0E` cluster fails shaping in every font and falls to `.LastResort`):

```python
h = h.replace('︎', '')   # strip VS15; leave ️ (emoji-style) alone
```

**b) Inject this CSS into the `<head>` (before `</head>`):**

```css
@page {
  size: A4;
  margin: 2cm 2.5cm;
}
body {
  /* Latin first → CJK fallback → symbol fallback. weasyprint resolves
     per-glyph: English uses Helvetica/Arial (universally printable), CJK
     falls through to Hiragino/PingFang. Do NOT put CJK fonts first — Latin
     glyphs would get embedded as CID/Identity-H subsets and many printers /
     Adobe Reader (Windows) render those as blank pages.
     "Apple Symbols" + "Arial Unicode MS" at the end catch symbols the
     earlier fonts lack (e.g. ↔ U+2194: Helvetica has no arrows, and the
     GB-charset CJK fonts cover ←↑→↓ but NOT ↔) — without them weasyprint
     falls to .LastResort, which renders as a boxed "?". */
  font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, "Hiragino Sans GB", "PingFang SC", "Heiti SC", "Microsoft YaHei", "Apple Symbols", "Arial Unicode MS", sans-serif;
  font-size: 11pt;
  line-height: 1.7;
  color: #1a1a1a;
}
img {
  max-width: IMG_WIDTH%;
  height: auto;
  display: block;
  margin: 0.5em auto;
}
table {
  border-collapse: collapse;
  width: 100%;
  font-size: 10pt;
  margin: 1em 0;
}
tr {
  page-break-inside: avoid;
  break-inside: avoid;
}
th, td {
  border: 1px solid #999;
  padding: 4px 8px;
  text-align: left;
  vertical-align: top;
}
th {
  background: #f0f0f0;
  font-weight: bold;
}
h1, h2, h3, h4 {
  page-break-after: avoid;
  margin-top: 1.5em;
}
h1 { font-size: 18pt; border-bottom: 2px solid #333; padding-bottom: 4px; }
h2 { font-size: 15pt; border-bottom: 1px solid #ccc; padding-bottom: 3px; }
h3 { font-size: 13pt; }
blockquote {
  border-left: 3px solid #999;
  margin-left: 0;
  padding: 0.3em 1em;
  color: #555;
  background: #fafafa;
}
code {
  font-family: "SF Mono", "Menlo", "Hiragino Sans GB", "Heiti SC", "PingFang SC", "Apple Symbols", "Arial Unicode MS", monospace;
  font-size: 9pt;
  background: #f5f5f5;
  padding: 1px 4px;
  border-radius: 2px;
}
pre {
  background: #f5f5f5;
  padding: 0.8em;
  overflow-x: auto;
  font-size: 9pt;
  border-radius: 4px;
}
pre code {
  background: none;
  padding: 0;
}
```

Replace `IMG_WIDTH` with the `--img-width` value (default 60).

**c) Append `--extra-css`, if given:** after the default CSS block above, read that file's content and append it verbatim inside the same `<style>` block (after the defaults, so cascade order lets it extend/override). Do this in the same Python pass as (a) the VS15-strip and (b) the CSS-injection above — do not add a second pass or a separate `<style>` block.

### 5. Convert HTML to PDF with weasyprint

```bash
weasyprint /tmp/md-to-pdf-<hash>.html "<output-path>"
```

Set the working directory to the markdown file's parent directory so relative image paths resolve correctly.

### 6. Clean up and report

- Remove the temp `.md` and `.html` files.
- Report the output path and file size to the user.
- If there were any warnings from weasyprint (missing fonts, broken images), summarize them.

### 7. Sanity-check the embedded fonts (REQUIRED)

Run `pdffonts <output.pdf>` and check two things:

1. **Primary font is Latin**: confirm the primary embedded font is Helvetica / Helvetica-Neue / Arial — NOT Hiragino-Sans-GB or another CJK font. If the primary is CJK, the PDF will print blank on Adobe Reader (Windows) and many office printers even though it looks fine in macOS Preview. This is the most common reason a generated PDF "loses all characters when printed."
2. **No `.LastResort` font**: if `pdffonts` lists a `.LastResort` entry, some character was not resolvable by the font stack and will render as a boxed "?" glyph. Find the culprit by scanning the source `.md` for uncommon symbols, e.g.:

   ```python
   import unicodedata
   for ch in sorted(set(open('input.md', encoding='utf-8').read())):
       o = ord(ch)
       if o < 128 or 0x4E00 <= o <= 0x9FFF or 0x3000 <= o <= 0x303F or 0xFF00 <= o <= 0xFFEF:
           continue
       print(f'U+{o:04X} {ch!r} {unicodedata.name(ch, "?")}')
   ```

   Then fix by adding the char to the step-2b wrap list (NOT by appending a font to the CSS stack — `.LastResort` outranks late-stack fonts in fontconfig's per-glyph sort, so that doesn't work on macOS) and confirm the step-4a VS15 strip ran. Regenerate and re-run `pdffonts` until `.LastResort` is gone, then visually spot-check the page containing the char (render with `pdftoppm -png` and Read the image).
