#!/usr/bin/env python3
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import lint_links

TID = "T20260611-000001"


def mk(root, rel, body=""):
    f = Path(root) / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(body, encoding="utf-8")
    return f


def run(root, *args):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = lint_links.main([str(root), *args])
    return rc, buf.getvalue()


class LintLinksTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.root = Path(self._td.name).resolve()
        self.addCleanup(self._td.cleanup)

    def test_ok_link_exits_zero(self):
        mk(self.root, "dev/TODO/b.md")
        mk(self.root, "dev/TODO/a.md", "[b](b.md)\n")
        self.assertEqual(run(self.root)[0], 0)

    def test_broken_link_exits_one_and_is_read_only(self):
        f = mk(self.root, "dev/TODO/a.md", "[x](nope.md)\n")
        rc, out = run(self.root)
        self.assertEqual(rc, 1)
        self.assertIn("nope.md", out)
        self.assertEqual(f.read_text(), "[x](nope.md)\n")

    def test_skips_external_anchor_mailto(self):
        mk(self.root, "dev/a.md", "[a](https://x.io/y) [b](#top) [c](mailto:a@b.c)\n")
        self.assertEqual(run(self.root)[0], 0)

    def test_fragment_stripped(self):
        mk(self.root, "dev/b.md")
        mk(self.root, "dev/a.md", "[b](b.md#sec)\n")
        self.assertEqual(run(self.root)[0], 0)

    def test_code_ignored(self):
        mk(self.root, "dev/a.md", "`[x](no.md)`\n```\n[y](no2.md)\n```\n")
        self.assertEqual(run(self.root)[0], 0)

    def test_cross_repo_outside_root_skipped(self):
        mk(self.root, "dev/a.md", "[x](../../other-repo/README.md)\n")
        self.assertEqual(run(self.root)[0], 0)

    def test_allowlist_file_and_flag(self):
        mk(self.root, "dev/a.md", "[x](gone.md) [y](old/z.md)\n")
        self.assertEqual(run(self.root)[0], 1)
        mk(self.root, "dev/.link-allowlist", "# baseline\ngone.md\n")
        self.assertEqual(run(self.root)[0], 1)
        self.assertEqual(run(self.root, "--allow", "old/*")[0], 0)

    def test_print_allowlist(self):
        mk(self.root, "dev/a.md", "[x](gone.md)\n")
        rc, out = run(self.root, "--print-allowlist")
        self.assertEqual((rc, out.strip()), (0, "gone.md"))

    def test_taskid_suggestion_and_fix_idempotent(self):
        mk(self.root, f"dev/JOURNAL/2026-10-01-{TID}-demo.md")
        f = mk(self.root, "dev/TODO/a.md", f"[d]({TID}-demo.md#s)\n")
        rc, out = run(self.root)
        self.assertEqual(rc, 1)
        self.assertIn(f"../JOURNAL/2026-10-01-{TID}-demo.md#s", out)
        self.assertEqual(f.read_text(), f"[d]({TID}-demo.md#s)\n")
        self.assertEqual(run(self.root, "--fix")[0], 0)
        fixed = f.read_text()
        self.assertEqual(fixed, f"[d](../JOURNAL/2026-10-01-{TID}-demo.md#s)\n")
        self.assertEqual(run(self.root, "--fix")[0], 0)
        self.assertEqual(f.read_text(), fixed)

    def test_fix_leaves_unresolvable_broken(self):
        mk(self.root, "dev/a.md", f"[d]({TID}-zzz.md) [e](nope.md)\n")
        self.assertEqual(run(self.root, "--fix")[0], 1)

    def test_no_dev_dir_ok(self):
        self.assertEqual(run(self.root)[0], 0)


if __name__ == "__main__":
    unittest.main()
