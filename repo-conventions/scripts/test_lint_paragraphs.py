#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

import lint_paragraphs


def write_task(root, name="T20260611-000001-demo.md", body="", sub="TODO"):
    f = Path(root) / "dev" / sub / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(f"---\nstatus: Open\nestimation: 2h\n---\n\n{body}",
                 encoding="utf-8")
    return f


LONG_SENTENCE = "word " * 70  # 70 words, over the 60-word default threshold
SHORT_SENTENCE = "word " * 10  # under threshold


class LintParagraphsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_short_paragraph_not_flagged(self):
        body = f"## Problem\n\n{SHORT_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_long_paragraph_flagged(self):
        body = f"## Problem\n\n{LONG_SENTENCE}\n"
        f = write_task(self.root, body=body)
        hits = lint_paragraphs.lint_file(f)
        self.assertEqual(len(hits), 1)
        start_line, word_count, preview = hits[0]
        self.assertEqual(word_count, 70)
        self.assertGreater(start_line, 0)

    def test_bulleted_content_not_flagged_even_if_long_overall(self):
        lines = "\n".join(f"- {SHORT_SENTENCE}" for _ in range(10))
        body = f"## Problem\n\n{lines}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_root_cause_section_exempt(self):
        body = f"## Root cause\n\n{LONG_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_closed_section_exempt(self):
        body = f"## Closed (2026-07-20)\n\n{LONG_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_plan_section_not_exempt(self):
        body = f"## Plan\n\n{LONG_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(len(lint_paragraphs.lint_file(f)), 1)

    def test_fenced_code_block_ignored(self):
        body = f"## Problem\n\n```\n{LONG_SENTENCE}\n```\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_table_rows_ignored(self):
        rows = "\n".join(f"| {SHORT_SENTENCE} | x |" for _ in range(10))
        body = f"## Problem\n\n| a | b |\n|---|---|\n{rows}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_blockquote_ignored(self):
        body = f"## Problem\n\n> {LONG_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])

    def test_custom_threshold(self):
        body = f"## Problem\n\n{SHORT_SENTENCE}\n"
        f = write_task(self.root, body=body)
        self.assertEqual(lint_paragraphs.lint_file(f), [])  # default: not flagged
        hits = lint_paragraphs.lint_file(f, threshold=5)  # lower bar: now flagged
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0][1], 10)

    def test_main_never_fails(self):
        body = f"## Problem\n\n{LONG_SENTENCE}\n"
        write_task(self.root, body=body)
        rc = lint_paragraphs.main(["--all", self.root])
        self.assertEqual(rc, 0)

    def test_is_task_file_excludes_queue_md(self):
        self.assertFalse(lint_paragraphs.is_task_file("dev/TODO/queue.md"))

    def test_is_task_file_excludes_journal(self):
        self.assertFalse(
            lint_paragraphs.is_task_file("dev/JOURNAL/2026-07-20-x.md"))


if __name__ == "__main__":
    unittest.main()
