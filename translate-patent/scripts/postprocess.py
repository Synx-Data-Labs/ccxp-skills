#!/usr/bin/env python3
"""Deterministic post-processor for translate-patent's CN/EN markdown output.

Folds back the 11 patent-specific rendering fixes -- originally hand-applied
to a real patent's translated output -- into an automatic pass:

  - filing-part heading INSERTION at structural boundaries (item 5, part 1)
  - in-spec section heading promotion (item 5, part 2)
  - global figure renumbering, descending replace order (item 15)
  - figure pagination-split at single-box top borders (item 11)
  - Word PUA-bullet stripping (item 13)
  - claim-number escaping, "N." -> "N\\." (item 6)
  - claim-continuation dedent (item 7)

The four filing-part headings (说明书摘要/摘要附图/权利要求书/说明书, plus 附图 for
the appendix) never exist as literal text anywhere in a raw CN patent
extraction -- unlike the five in-spec section titles, which are always
literal text promote_headings() can find and promote. insert_filing_part_
headings() manufactures them from document STRUCTURE (figure-group and
section-title anchors) instead, and runs before promote_headings() so the
'摘要附图'/'权利要求书' anchors that renumber_figures()/escape_claim_numbers()/
dedent_claim_continuations() depend on (via _find_h1_span()) actually exist.

CSS-only fixes (items 8, 10, 12, 14) live in translate-patent/patent-pdf-extra.css
instead — nothing to do with text transforms, out of scope for this script.

Idempotency: every transform is designed so a second run on already-processed
text is a no-op (see per-function comments). This matters because
translate-patent/SKILL.md's step 8 may be re-run against a doc that was
already post-processed (e.g. a partial re-run after --no-pdf).

CLI:
    postprocess.py <file.md> [--lang en|zh] [--in-place | -o <output>]

If neither --in-place nor -o is given, the result is written to stdout.
--lang is auto-detected from CJK-vs-Latin character-class majority when
omitted (the recommended default).
"""
import argparse
import re
import sys
from pathlib import Path

# --- vocabulary ---------------------------------------------------------

# Four part-level "# " headings per language (item 5).
PART_HEADINGS = {
    "zh": ["说明书摘要", "摘要附图", "权利要求书", "说明书"],
    "en": ["Abstract", "Abstract Drawing", "Claims", "Specification"],
}

# Five in-spec section titles promoted to "## " headings (item 5).
SECTION_HEADINGS = {
    "zh": ["技术领域", "背景技术", "发明内容", "附图说明", "具体实施方式"],
    "en": [
        "Technical Field",
        "Background Art",
        "Summary of the Invention",
        "Description of Drawings",
        "Detailed Description of Embodiments",
    ],
}

CLAIMS_HEADING = {"zh": "权利要求书", "en": "Claims"}
ABSTRACT_DRAWING_HEADING = {"zh": "摘要附图", "en": "Abstract Drawing"}
ABSTRACT_HEADING = {"zh": "说明书摘要", "en": "Abstract"}
SPECIFICATION_HEADING = {"zh": "说明书", "en": "Specification"}
APPENDIX_HEADING = {"zh": "附图", "en": "Drawings"}

# Figure-reference patterns: capture (marker, whitespace, number) so the
# original spacing style ("图 N" vs "图N") is preserved on substitution.
FIGURE_PATTERNS = {
    "zh": re.compile(r"(图)(\s*)(\d+)"),
    "en": re.compile(r"(Figure)(\s+)(\d+)"),
}

# Bare word used by a figure CAPTION (not the same as the FIGURE_PATTERNS
# marker text, though it happens to coincide -- kept separate since a
# caption match additionally requires the whole line to be a heading/bold
# paragraph, immediately followed by a number + colon).
CAPTION_WORD = {"zh": "图", "en": "Figure"}

FENCE_RE = re.compile(r"^\s*```")
TOP_BORDER_RE = re.compile(r"^\s*┌─+┐\s*$")
PUA_RE = re.compile(r"[-]")
BULLET_LINE_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<bullet>[-])(?P<sep>[ \t]+)(?P<rest>.*)$"
)
LABEL_SEP_RE = re.compile(r"^(?P<label>.{1,24}?)[：:](?P<rest>.*)$")
CLAIM_NUM_RE = re.compile(r"^(\d+)\.(\s)")


# --- language detection ---------------------------------------------------

def detect_lang(text):
    """Auto-detect 'zh' or 'en' from CJK-vs-Latin character-class majority."""
    cjk = sum(1 for c in text if "一" <= c <= "鿿")
    latin = sum(1 for c in text if c.isalpha() and c.isascii())
    return "zh" if cjk > latin else "en"


# --- item 5, part 1: filing-part heading INSERTION at structural anchors --

def _vocab_text(line):
    """Punctuation-trimmed heading-candidate text for a line, whether it is
    still a bare paragraph or has already been promoted to a '#' heading.
    Shared by the anchor/idempotency helpers below."""
    s = line.strip()
    if s.startswith("#"):
        s = s.lstrip("#").strip()
    return s.rstrip("：:。.")


def _find_filing_part_heading(lines, heading):
    """Locate an existing occurrence of <heading> -- either a real '# '
    heading (a prior run of this script, or a hand-edited input) or a bare
    paragraph exactly matching the closed-vocabulary text that
    promote_headings() would turn into that same heading on its own.

    This is the idempotency guard for insert_filing_part_headings(): either
    form means "this heading already exists somewhere", so no insertion
    happens (no --lang-scoped anchor lookup is even needed).
    """
    esc = re.escape(heading)
    fence = False
    for i, line in enumerate(lines):
        if FENCE_RE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        if re.match(rf"^#\s*{esc}\s*$", line.strip()):
            return i
        if _vocab_text(line) == heading:
            return i
    return None


def _find_first_section_heading(lines, lang):
    """Locate the first occurrence of the first in-spec section title
    (Technical Field / 技术领域) -- anchor B for filing-part heading
    insertion (see insert_filing_part_headings()). Recognizes the title
    whether it is still bare text or already promoted, reusing
    promote_headings()'s own closed-vocabulary match rather than
    re-deriving a separate detection rule."""
    target = SECTION_HEADINGS[lang][0]
    fence = False
    for i, line in enumerate(lines):
        if FENCE_RE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        if _vocab_text(line) == target:
            return i
    return None


def _figure_caption_body(line, lang):
    """Return the inner text of a figure-caption line ('#### 图 N：...' or
    '**Figure N: ...**' -- either format, since this may run on older
    already-partially-processed content too), or None if the line is not a
    whole-line caption."""
    s = line.strip()
    if s.startswith("#"):
        body = s.lstrip("#").strip()
    elif s.startswith("**") and s.endswith("**") and len(s) > 4:
        body = s[2:-2].strip()
    else:
        return None
    word = re.escape(CAPTION_WORD[lang])
    if re.match(rf"^{word}\s*\d+\s*[:：]", body):
        return body
    return None


def _consume_one_figure(lines, i):
    """Consume a single caption + its one-or-more fenced blocks starting at
    line i (already confirmed to be a caption). Returns the index right
    after the last consumed closing fence, or None if no fence follows
    (not a valid figure -- e.g. a caption-shaped line with no diagram)."""
    n = len(lines)
    j = i + 1
    while j < n and lines[j].strip() == "":
        j += 1
    found_fence = False
    while j < n and FENCE_RE.match(lines[j]):
        found_fence = True
        j += 1
        while j < n and not FENCE_RE.match(lines[j]):
            j += 1
        if j < n:
            j += 1  # consume the closing fence line
        k = j
        while k < n and lines[k].strip() == "":
            k += 1
        if k < n and FENCE_RE.match(lines[k]):
            j = k  # another fenced chunk follows -> same figure (item 11 split)
        else:
            break
    return j if found_fence else None


def _find_figure_groups(lines, lang):
    """Return every "figure group" in document order: a maximal run of one
    or more (caption + one-or-more fenced blocks) figures with NO prose
    between them -- only blank lines. This matters because the drawings
    appendix always dumps every remaining figure back-to-back with no
    intervening prose (e.g. when two appendix figures are adjacent, the
    '# 附图' heading must land before the FIRST of the two, not before
    each individually) -- so the whole adjacent run counts as one group,
    and only ITS start/end matter as an anchor. A lone figure (no adjacent
    caption before/after it) is simply a group of one.

    Each group is (caption_index, end_index): caption_index is the first
    figure's caption line in the run; end_index is the line right after
    the run's last closing fence (exclusive)."""
    n = len(lines)
    groups = []
    i = 0
    while i < n:
        if _figure_caption_body(lines[i], lang) is not None:
            group_start = i
            j = i
            while _figure_caption_body(lines[j], lang) is not None:
                fence_end = _consume_one_figure(lines, j)
                if fence_end is None:
                    break
                j = fence_end
                k = j
                while k < n and lines[k].strip() == "":
                    k += 1
                if k < n and _figure_caption_body(lines[k], lang) is not None:
                    j = k  # next content is another caption -> same group
                    continue
                break
            if j > group_start:
                groups.append((group_start, j))
                i = j
                continue
        i += 1
    return groups


def _step_back_over_title_repeat(lines, lang, b_idx):
    """If the non-blank line immediately preceding anchor B (the first
    section title) looks like a bare repeated invention-title -- short,
    not already a heading, not itself a closed-vocabulary title -- return
    its index instead, so '# Specification'/'# 说明书' lands before the
    title repeat rather than between it and 'Technical Field'/'技术领域'.

    Deliberately simple: if this can't confidently detect a title-repeat
    line, it returns b_idx unchanged, which is still correct (just a
    cosmetic difference, not a functional one)."""
    k = b_idx - 1
    while k >= 0 and lines[k].strip() == "":
        k -= 1
    if k < 0:
        return b_idx
    candidate = lines[k].strip()
    if not candidate or candidate.startswith("#") or len(candidate) > 60:
        return b_idx
    body = candidate.rstrip("：:。.")
    if body in SECTION_HEADINGS[lang] or body in PART_HEADINGS[lang]:
        return b_idx
    return k


def insert_filing_part_headings(text, lang):
    """Insert the filing-part '# ' headings (说明书摘要/摘要附图/权利要求书/说明书,
    plus 附图 for the appendix) at structurally-recognized boundaries.

    Unlike the five in-spec section titles, these never exist as literal
    text anywhere in a raw CN patent extraction, so promote_headings()
    (which can only promote text that already exists) can never create
    them on its own -- leaving escape_claim_numbers()/renumber_figures()/
    dedent_claim_continuations() unable to find the '# 权利要求书'/
    '# 摘要附图' anchors they depend on (_find_h1_span()). This function
    creates those anchors from document STRUCTURE instead, using only two
    kinds of anchor:

      A = the first figure group (see _find_figure_groups())
      B = the first occurrence of the first in-spec section title
          (Technical Field / 技术领域, see _find_first_section_heading())
      C = the last figure group, distinct from A only if there are
          >= 2 figure groups total

    Insertions, in document order:
      - Abstract heading: the very first line of the document.
      - Abstract Drawing heading: immediately before anchor A's caption.
      - Claims heading: immediately after anchor A's figure group ends.
      - Specification heading: immediately before anchor B (optionally
        stepping back over one bare title-repeat line -- see
        _step_back_over_title_repeat()).
      - Drawings (appendix) heading: immediately before anchor C's
        caption, only when anchor C is distinct from anchor A (i.e. there
        are genuinely >= 2 figure groups; a document with only one figure
        has no separate appendix content to label, so nothing is inserted
        for it).

    Idempotency: each heading is skipped if it already exists anywhere in
    the document, as either a real '# ' heading or a bare paragraph
    promote_headings() would turn into one on its own (see
    _find_filing_part_heading()) -- this covers both a second run of this
    script and a hand-edited / partially-processed input.
    """
    abstract_h = ABSTRACT_HEADING[lang]
    drawing_h = ABSTRACT_DRAWING_HEADING[lang]
    claims_h = CLAIMS_HEADING[lang]
    spec_h = SPECIFICATION_HEADING[lang]
    appendix_h = APPENDIX_HEADING[lang]

    lines = text.split("\n")
    n = len(lines)

    groups = _find_figure_groups(lines, lang)
    anchor_a = groups[0] if groups else None
    anchor_c = groups[-1] if len(groups) >= 2 else None

    # Gather (position, doc_order_rank, [lines to insert]) against the
    # ORIGINAL (pre-edit) line indices, then apply in descending order --
    # by position first, and by doc_order_rank as a tie-break for two
    # insertions that land on the very same line (e.g. a document whose
    # very first line is already a figure caption, with no abstract prose
    # ahead of it: the Abstract and Abstract Drawing headings would both
    # target position 0). Processing descending means the position/rank
    # that belongs LATER in the final document is spliced in first, so a
    # still-pending earlier insertion at the same spot is guaranteed to
    # land in front of it, not behind.
    insertions = []
    RANK_ABSTRACT, RANK_DRAWING, RANK_CLAIMS, RANK_SPEC, RANK_APPENDIX = range(5)

    if _find_filing_part_heading(lines, abstract_h) is None:
        insertions.append((0, RANK_ABSTRACT, [f"# {abstract_h}", ""]))

    if anchor_a is not None and _find_filing_part_heading(lines, drawing_h) is None:
        cap_idx, _ = anchor_a
        insertions.append((cap_idx, RANK_DRAWING, [f"# {drawing_h}", ""]))

    if anchor_a is not None and _find_filing_part_heading(lines, claims_h) is None:
        _, group_end = anchor_a
        pos = group_end
        while pos < n and lines[pos].strip() == "":
            pos += 1
        insertions.append((pos, RANK_CLAIMS, [f"# {claims_h}", ""]))

    if _find_filing_part_heading(lines, spec_h) is None:
        b_idx = _find_first_section_heading(lines, lang)
        if b_idx is not None:
            pos = _step_back_over_title_repeat(lines, lang, b_idx)
            insertions.append((pos, RANK_SPEC, [f"# {spec_h}", ""]))

    if anchor_c is not None and _find_filing_part_heading(lines, appendix_h) is None:
        cap_idx, _ = anchor_c
        insertions.append((cap_idx, RANK_APPENDIX, [f"# {appendix_h}", ""]))

    if not insertions:
        return text

    insertions.sort(key=lambda t: (t[0], t[1]), reverse=True)
    for pos, _rank, new_lines in insertions:
        lines[pos:pos] = new_lines

    return "\n".join(lines)


# --- item 5, part 2: in-spec section heading promotion ---------------------

def promote_headings(text, lang):
    """Promote literal filing-part / section-title lines to real headings.

    A line is promoted only if its whole (punctuation-trimmed) content
    exactly matches one of the closed vocabularies, and it is not already a
    heading — so re-running on an already-promoted doc ("# Claims") is a
    no-op: the line already starts with '#' and is left untouched.
    """
    parts = PART_HEADINGS[lang]
    sections = SECTION_HEADINGS[lang]
    lines = text.split("\n")
    out = []
    fence = False
    for line in lines:
        if FENCE_RE.match(line):
            fence = not fence
            out.append(line)
            continue
        if fence:
            out.append(line)
            continue
        stripped = line.strip()
        test = stripped.rstrip("：:。.")
        if stripped.startswith("#"):
            out.append(line)
        elif test in parts:
            out.append(f"# {test}")
        elif test in sections:
            out.append(f"## {test}")
        else:
            out.append(line)
    return "\n".join(out)


# --- shared: locate a "# <heading>" ... next "# " span --------------------

def _find_h1_span(lines, heading):
    """Return (content_start, content_end) for the body under a "# <heading>"
    h1 (exclusive of the heading line itself), ending at the next true h1 or
    EOF. Returns None if the heading is not present."""
    start = None
    esc = re.escape(heading)
    for i, line in enumerate(lines):
        if re.match(rf"^#\s*{esc}\s*$", line.strip()):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^#\s+\S", lines[j]):
            end = j
            break
    return start + 1, end


# --- item 15: global figure renumbering ------------------------------------

def renumber_figures(text, lang):
    """Shift all figure numbers OUTSIDE the abstract-drawing part by +1, so
    the abstract drawing keeps 图1/Figure 1 and the appendix figures that
    originally collided by restarting at 1 continue 图2, 图3, ... instead.

    Descending replace order (highest original number first) avoids a figure
    already shifted to N+1 being re-matched by a later N -> N+1 pass.

    Idempotency: only fires when the lowest figure number found outside the
    abstract-drawing span is exactly 1 (the collision this fixes). After one
    run that minimum becomes 2, so a second run is a no-op — no marker
    bookkeeping needed.
    """
    lines = text.split("\n")
    span = _find_h1_span(lines, ABSTRACT_DRAWING_HEADING[lang])
    if span is None:
        return text  # no abstract-drawing part -> nothing to reconcile
    start, end = span
    protected = set(range(start, end))
    pattern = FIGURE_PATTERNS[lang]

    candidates = set()
    for i, line in enumerate(lines):
        if i in protected:
            continue
        for m in pattern.finditer(line):
            candidates.add(int(m.group(3)))

    if not candidates or min(candidates) != 1:
        return text  # already renumbered, or no figures to reconcile

    offset = 1
    for n in sorted(candidates, reverse=True):
        target = n + offset

        def repl(m, n=n, target=target):
            if int(m.group(3)) == n:
                return f"{m.group(1)}{m.group(2)}{target}"
            return m.group(0)

        for i in range(len(lines)):
            if i in protected:
                continue
            lines[i] = pattern.sub(repl, lines[i])

    return "\n".join(lines)


# --- item 11: figure pagination-split --------------------------------------

def split_figure_pagination(text):
    """Split a fenced ASCII-figure code block into per-box chunks, breaking
    immediately BEFORE a line that is a single-box top border
    (^\\s*┌─+┐\\s*$). A side-by-side two-box line (trailing content after
    the first closing corner) never matches, so it is never split.

    Idempotency: a split point is only recognized when the top-border line
    is NOT the first content line of its (sub-)block. After a split, every
    resulting block's first content line IS a top border, so re-scanning
    never re-splits it.
    """
    lines = text.split("\n")
    out = []
    i = 0
    n = len(lines)
    while i < n:
        m = re.match(r"^(\s*)(```+)(.*)$", lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        indent, ticks, info = m.groups()
        block = [lines[i]]
        i += 1
        closed = False
        while i < n:
            block.append(lines[i])
            if re.match(rf"^\s*{re.escape(ticks)}\s*$", lines[i]):
                closed = True
                i += 1
                break
            i += 1

        if not closed or len(block) < 2:
            out.extend(block)
            continue

        content = block[1:-1]
        split_at = [
            idx for idx, l in enumerate(content) if idx > 0 and TOP_BORDER_RE.match(l)
        ]
        if not split_at:
            out.extend(block)
            continue

        chunks = []
        start = 0
        for idx in split_at:
            chunks.append(content[start:idx])
            start = idx
        chunks.append(content[start:])

        for ci, chunk in enumerate(chunks):
            out.append(f"{indent}{ticks}{info}")
            out.extend(chunk)
            out.append(f"{indent}{ticks}")
            if ci != len(chunks) - 1:
                out.append("")

    return "\n".join(out)


# --- item 13: Word PUA-bullet stripping -------------------------------------

def _is_cjk(s):
    return any("一" <= c <= "鿿" for c in s)


def strip_pua_bullets(text):
    """Strip Word PUA bullet glyphs (U+E000-U+F8FF, e.g. U+F0B7 Wingdings).

    A labeled bullet ("<PUA> Label: text") becomes a bold lead-in
    ("**Label:** text"), mirroring the existing EN style. A bare bullet
    ("<PUA> text") becomes a plain paragraph (bullet dropped). Any stray PUA
    char elsewhere on a line is simply removed.

    Idempotency: the output never contains a PUA char, so re-running finds
    nothing left to strip.
    """
    lines = text.split("\n")
    out = []
    fence = False
    for line in lines:
        if FENCE_RE.match(line):
            fence = not fence
            out.append(line)
            continue
        if fence:
            out.append(line)
            continue
        m = BULLET_LINE_RE.match(line)
        if m:
            rest = m.group("rest").strip()
            lm = LABEL_SEP_RE.match(rest)
            if lm:
                label = lm.group("label").strip()
                body = lm.group("rest").strip()
                colon = "：" if _is_cjk(label) else ":"
                out.append(f"**{label}{colon}** {body}")
            else:
                out.append(rest)
        else:
            out.append(PUA_RE.sub("", line))
    return "\n".join(out)


# --- items 6-7: claim-number escaping + continuation dedent -----------------

def escape_claim_numbers(text, lang):
    """Escape claim-number markers ("1." -> "1\\.") inside the Claims part so
    markdown does not parse/renumber them as an ordered list.

    Idempotency: the regex requires the digit run to be immediately followed
    by a literal '.'; once escaped the next char is '\\' instead, so the
    pattern no longer matches on a second run.
    """
    lines = text.split("\n")
    span = _find_h1_span(lines, CLAIMS_HEADING[lang])
    if span is None:
        return text
    start, end = span
    for i in range(start, end):
        if CLAIM_NUM_RE.match(lines[i]):
            lines[i] = CLAIM_NUM_RE.sub(lambda m: f"{m.group(1)}\\.{m.group(2)}", lines[i], count=1)
    return "\n".join(lines)


def dedent_claim_continuations(text, lang):
    """Reflow any >=4-space-indented continuation line inside the Claims
    part flush-left, so it does not get parsed as a fenced-off code block.

    Idempotency: dedented lines end up with 0 leading whitespace (< 4), so a
    second run finds nothing left to dedent.
    """
    lines = text.split("\n")
    span = _find_h1_span(lines, CLAIMS_HEADING[lang])
    if span is None:
        return text
    start, end = span
    fence = False
    for i in range(start, end):
        line = lines[i]
        if FENCE_RE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        stripped = line.lstrip(" \t")
        if not stripped:
            continue
        leading = line[: len(line) - len(stripped)]
        width = leading.replace("\t", "    ")
        if len(width) >= 4:
            lines[i] = stripped
    return "\n".join(lines)


# --- orchestrator -----------------------------------------------------------

def postprocess_text(text, lang):
    """Run every transform in the fixed order the design requires:
    filing-part heading INSERTION first (manufactures the '# 摘要附图' /
    '# 权利要求书' anchors that do not otherwise exist in raw input), then
    in-spec section heading promotion, then figure renumbering,
    pagination-split, PUA-bullet stripping, then claim escaping and
    continuation dedent (renumbering/claim-escaping/dedent locate their
    spans off the headings the first two steps produce)."""
    text = insert_filing_part_headings(text, lang)
    text = promote_headings(text, lang)
    text = renumber_figures(text, lang)
    text = split_figure_pagination(text)
    text = strip_pua_bullets(text)
    text = escape_claim_numbers(text, lang)
    text = dedent_claim_continuations(text, lang)
    return text


# --- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        description="Post-process a translate-patent CN/EN markdown file "
        "(heading promotion, figure renumbering + pagination, PUA-bullet "
        "stripping, claim escaping + dedent)."
    )
    p.add_argument("file", help="path to the markdown file to post-process")
    p.add_argument(
        "--lang",
        choices=["en", "zh"],
        default=None,
        help="document language; auto-detected from CJK-vs-Latin majority if omitted",
    )
    g = p.add_mutually_exclusive_group()
    g.add_argument("--in-place", action="store_true", help="write the result back to <file>")
    g.add_argument("-o", "--output", metavar="PATH", help="write the result to PATH instead of stdout")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    path = Path(args.file)
    if not path.is_file():
        print(f"Error: file not found: {path}", file=sys.stderr)
        return 1

    text = path.read_text(encoding="utf-8")
    lang = args.lang or detect_lang(text)
    result = postprocess_text(text, lang)

    if args.in_place:
        path.write_text(result, encoding="utf-8")
    elif args.output:
        Path(args.output).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
