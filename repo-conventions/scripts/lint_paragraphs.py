#!/usr/bin/env python3
"""Warn (never fail) on long prose paragraphs in dev/TODO + dev/PARKING task
files — the "bullets, not paragraphs" house style (repo-conventions/templates/
guidelines.md's Documentation section, design-doc.md's Format discipline).

This is a nudge for the AGENT writing/revising a task doc, not a CI gate: a
purely syntactic scan can't tell a lazy wall-of-prose from a root-cause story
that genuinely doesn't decompose (guidelines.md's own carve-out), so it never
blocks — it prints file:line + a preview so the reader (human or agent) can
judge and revise. Always exits 0.

Scope mirrors lint_tasks.py's iter_task_files: dev/TODO + dev/PARKING only.
dev/JOURNAL is archival and exempt (same reasoning as the frontmatter linter).
"""
import argparse
import re
import sys
from pathlib import Path

DEFAULT_WORD_THRESHOLD = 60  # ~3-4 sentences of normal-density prose
NON_TASK_FILES = {"queue.md"}
LIST_RE = re.compile(r"^\s*([-*+]|\d+[.)])\s+")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
# Sections where a full paragraph is the documented, legitimate choice
# (guidelines.md: "reserve prose for narrative that genuinely doesn't
# decompose — a root-cause story, a rationale").
EXEMPT_HEADINGS = {"root cause", "closed"}


def is_task_file(path):
    p = Path(path)
    if p.name in NON_TASK_FILES:
        return False
    parts = p.parts
    return "dev" in parts and any(s in parts for s in ("TODO", "PARKING"))


def iter_task_files(repo_path):
    root = Path(repo_path)
    for sub in ("TODO", "PARKING"):
        d = root / "dev" / sub
        if d.is_dir():
            yield from (f for f in sorted(d.glob("*.md"))
                        if f.name not in NON_TASK_FILES)


def strip_frontmatter(text):
    """Return body text with a leading '---'...'---' YAML block removed."""
    if not text.startswith("---\n"):
        return text
    parts = text.split("---", 2)
    return parts[2] if len(parts) >= 3 else text


def find_long_paragraphs(text, threshold=DEFAULT_WORD_THRESHOLD):
    """Yield (start_line, word_count, preview) for each flush-left prose
    paragraph over `threshold` words, outside code fences / exempt headings.

    A "paragraph line" is non-blank, unindented, and not a list item,
    heading, blockquote, or table row — i.e. bare prose directly under a
    section heading. Indented lines are treated as list continuations/nested
    content and skipped, matching lint-docs.sh's MD032 continuation rule.
    """
    lines = text.splitlines()
    in_fence = False
    current_heading = ""
    block = []
    block_start = None

    def flush():
        if not block:
            return None
        joined = " ".join(block)
        words = joined.split()
        is_exempt = any(current_heading.startswith(h) for h in EXEMPT_HEADINGS)
        if len(words) <= threshold or is_exempt:
            return None
        preview = joined[:100] + ("…" if len(joined) > 100 else "")
        return (block_start, len(words), preview)

    for i, line in enumerate(lines, start=1):
        if FENCE_RE.match(line):
            result = flush()
            if result:
                yield result
            block, block_start = [], None
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        heading_match = HEADING_RE.match(line)
        if heading_match:
            result = flush()
            if result:
                yield result
            block, block_start = [], None
            current_heading = heading_match.group(2).strip().lower()
            continue

        stripped = line.strip()
        is_blank = stripped == ""
        is_structured = (
            LIST_RE.match(line) or stripped.startswith(">")
            or stripped.startswith("|") or line.startswith(" ")
            or line.startswith("\t")
        )

        if is_blank or is_structured:
            result = flush()
            if result:
                yield result
            block, block_start = [], None
            continue

        if block_start is None:
            block_start = i
        block.append(stripped)

    result = flush()
    if result:
        yield result


def lint_file(path, threshold=DEFAULT_WORD_THRESHOLD):
    text = Path(path).read_text(encoding="utf-8")
    body = strip_frontmatter(text)
    return list(find_long_paragraphs(body, threshold))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Warn on long prose paragraphs in dev/TODO + dev/PARKING "
                    "task files. Never fails — always exits 0.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true",
                   help="scan every dev/TODO + dev/PARKING file under repo_path")
    g.add_argument("--changed", nargs="*", metavar="FILE",
                   help="scan only these files (non-task files ignored)")
    ap.add_argument("--threshold", type=int, default=DEFAULT_WORD_THRESHOLD,
                     help=f"word count above which a paragraph is flagged "
                          f"(default: {DEFAULT_WORD_THRESHOLD})")
    ap.add_argument("repo_path", nargs="?", default=".")
    args = ap.parse_args(argv)

    if args.changed is not None:
        files = [Path(f) for f in args.changed if is_task_file(f)]
    else:
        files = list(iter_task_files(args.repo_path))

    total_warnings = 0
    for f in files:
        for start_line, word_count, preview in lint_file(f, args.threshold):
            total_warnings += 1
            print(f"⚠️  {f}:{start_line} — {word_count}-word paragraph, "
                  f"consider bullets: \"{preview}\"")

    if total_warnings:
        print(f"\n⚠️  {total_warnings} long paragraph(s) found — bullets, not "
              f"paragraphs (repo-conventions/templates/guidelines.md). "
              f"Non-blocking; revise where the content actually decomposes.")
    else:
        print("✅ no long paragraphs found")
    return 0  # always — this is a nudge, never a gate


if __name__ == "__main__":
    sys.exit(main())
