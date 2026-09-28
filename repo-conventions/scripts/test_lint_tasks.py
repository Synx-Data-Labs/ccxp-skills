#!/usr/bin/env python3
import os
import unittest
import tempfile
from pathlib import Path

import lint_tasks


def write_task(root, name="T20260611-000001-demo.md",
               frontmatter="status: Open\nestimation: 2h",
               body=None, sub="TODO"):
    """Write a task file under <root>/dev/<sub>/ and return its Path."""
    tid = "-".join(name.split("-")[:2])
    if body is None:
        body = f"# {tid}: Demo task\n\n## Problem\n\nStuff.\n"
    f = Path(root) / "dev" / sub / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(f"---\n{frontmatter}\n---\n\n{body}", encoding="utf-8")
    return f


def write_journal(root, name):
    """Write a Done task into <root>/dev/JOURNAL/ (yyyy-mm-dd-T<id>-slug.md)."""
    f = Path(root) / "dev" / "JOURNAL" / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("# done\n", encoding="utf-8")
    return f


class LintTasksTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_clean_file_passes(self):
        f = write_task(self.root)
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_missing_status_fails(self):
        f = write_task(self.root, frontmatter="estimation: 2h")
        self.assertIn("missing required field 'status'", lint_tasks.lint_file(f))

    def test_missing_estimation_fails(self):
        f = write_task(self.root, frontmatter="status: Open")
        self.assertIn("missing required field 'estimation'", lint_tasks.lint_file(f))

    def test_prose_suffixed_status_passes(self):
        f = write_task(self.root, frontmatter=(
            "status: Coding — UNBLOCKED 2026-06-06: maintainer picked B\n"
            "estimation: 2h\n"
            "scheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_unknown_status_fails(self):
        f = write_task(self.root, frontmatter="status: Inprogress\nestimation: 2h")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("not a known status" in m for m in out), out)

    def test_in_progress_status_passes(self):
        # T20260809-355059: "In Progress" is the one two-word status name —
        # task_claim.sh acquire writes it, so lint must accept it (a
        # one-word lookalike typo like "Inprogress" above must still fail).
        f = write_task(self.root, frontmatter=(
            "status: In Progress\nestimation: 2h\nscheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_prose_suffixed_in_progress_status_passes(self):
        f = write_task(self.root, frontmatter=(
            "status: In Progress — SUPERVISED (needs a human)\n"
            "estimation: 2h\n"
            "scheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_bad_estimation_fails(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: soon")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must start with a duration" in m for m in out), out)

    def test_estimation_with_prose_suffix_passes(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: 2h (S)")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_unknown_field_fails(self):
        f = write_task(self.root,
            frontmatter="status: Open\nestimation: 2h\nname: Foo")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("unknown field 'name'" in m for m in out), out)

    def test_allowed_extra_fields_pass(self):
        f = write_task(self.root, frontmatter=(
            "status: Open\nestimation: 2h\n"
            "related: T20260101-000001\nowner: Alex\ndescription: x"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_bad_filename_fails(self):
        f = write_task(self.root, name="not-a-task.md")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("filename must match" in m for m in out), out)

    def test_missing_frontmatter_fails(self):
        f = Path(self.root) / "dev" / "TODO" / "T20260611-000001-demo.md"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("# T20260611-000001: Demo\n\nno frontmatter\n", encoding="utf-8")
        self.assertIn("missing YAML frontmatter (--- block)", lint_tasks.lint_file(f))

    def test_h1_id_mismatch_fails(self):
        f = write_task(self.root, name="T20260611-000001-demo.md",
            body="# T20260611-999999: Wrong id\n\n## Problem\n\nx\n")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("does not match filename id" in m for m in out), out)

    def test_missing_h1_fails(self):
        f = write_task(self.root, body="## Problem\n\nno h1\n")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("missing H1" in m for m in out), out)

    def test_all_lints_todo_and_parking_skips_journal(self):
        write_task(self.root, name="T20260611-000001-good.md", sub="TODO")
        write_task(self.root, name="T20260611-000002-park.md",
                   frontmatter="status: Parked\nestimation: 2h", sub="PARKING")
        j = Path(self.root) / "dev" / "JOURNAL" / "2025-01-01-legacy.md"
        j.parent.mkdir(parents=True, exist_ok=True)
        j.write_text("# 2025-01-01: legacy entry\n", encoding="utf-8")  # no frontmatter
        self.assertEqual(lint_tasks.main(["--all", self.root]), 0)

    def test_changed_filters_non_task_files(self):
        good = write_task(self.root, name="T20260611-000001-good.md")
        readme = Path(self.root) / "README.md"
        readme.write_text("hi\n", encoding="utf-8")
        self.assertEqual(lint_tasks.main(["--changed", str(good), str(readme)]), 0)

    def test_changed_reports_violation(self):
        bad = write_task(self.root, name="T20260611-000001-bad.md",
                         frontmatter="status: Open")  # missing estimation
        self.assertEqual(lint_tasks.main(["--changed", str(bad)]), 1)

    # --- blocked-by cross-reference (stale-blocker / cascade-unblock gate) ----

    def test_blocked_by_live_blocker_passes(self):
        write_task(self.root, name="T20260611-000010-blocker.md")  # live in TODO
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_done_blocker_fails(self):
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertIn(dep, out)
        self.assertTrue(any("already Done" in m for m in out[dep]), out)

    def test_blocked_by_live_wins_over_stale_journal_entry(self):
        # A re-opened blocker: live file in TODO + a lingering old JOURNAL entry
        # with the same id. Live must win — no false "already Done".
        write_journal(self.root, "2026-01-01-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000010-blocker.md")  # re-opened, live
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_multiple_blockers_flags_only_done_one(self):
        write_task(self.root, name="T20260611-000010-live.md")  # live
        write_journal(self.root, "2026-06-17-T20260611-000020-done.md")  # done
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010 and T20260611-000020\n"
            "estimation: 2h"))
        out = lint_tasks.lint_blocked_by(self.root)
        msgs = out.get(dep, [])
        self.assertEqual(len(msgs), 1, msgs)  # only the Done blocker flagged
        self.assertIn("T20260611-000020", msgs[0])

    def test_bare_blocked_status_without_id_passes(self):
        # `status: Blocked` with no T-id names nothing to resolve — not flagged.
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked — external vendor\nestimation: 2h"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_non_blocked_status_mentioning_id_is_ignored(self):
        # A Done blocker id mentioned in a NON-blocked status must NOT be flagged
        # (only `status: Blocked by …` triggers the cross-reference).
        write_journal(self.root, "2026-06-17-T20260611-000010-done.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Coding — superseded T20260611-000010\nestimation: 2h"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_missing_blocker_fails(self):
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-999999\nestimation: 2h"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertTrue(any("not found" in m for m in out.get(dep, [])), out)

    def test_blocked_by_prose_suffixed_status_resolves_id(self):
        # 'Blocked by T<id> — <prose>' must still resolve the named blocker.
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010 — waiting on review\n"
            "estimation: 2h"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertTrue(any("already Done" in m for m in out.get(dep, [])), out)

    def test_blocked_by_ignores_prose_blocked_by_field(self):
        # status is NOT Blocked; the free-text blocked-by field names a Done id
        # in strikethrough (a historical note) — must NOT be flagged.
        write_journal(self.root, "2026-06-17-T20260611-000010-old.md")
        f = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Open\nestimation: 2h\n"
            "blocked-by: '~~T20260611-000010~~ closed 2026-06-17'"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})
        self.assertEqual(lint_tasks.lint_file(f), [])  # schema still clean

    def test_all_mode_fails_on_stale_blocker(self):
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        self.assertEqual(lint_tasks.main(["--all", self.root]), 1)

    def test_changed_mode_catches_stale_blocker_on_unchanged_file(self):
        # The close-the-blocker PR touches only the blocker (now in JOURNAL);
        # the board-wide pass must still flag the *unchanged* dependent even
        # when --changed names an unrelated, schema-clean file.
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        write_task(self.root, name="T20260611-000012-other.md")  # clean, changed
        cwd = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, cwd)
        self.assertEqual(lint_tasks.main(
            ["--changed", "dev/TODO/T20260611-000012-other.md"]), 1)

    def test_changed_empty_set_still_runs_board_pass(self):
        # The close-PR (TODO→JOURNAL) changes no TODO/PARKING file, so the action
        # invokes `--changed` with zero files — the board-wide pass must still
        # run and catch the now-stale dependent.
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2h"))
        cwd = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, cwd)
        self.assertEqual(lint_tasks.main(["--changed"]), 1)

    def test_changed_empty_set_clean_board_passes(self):
        # Empty changed set on a board with no stale blockers → exit 0.
        write_task(self.root, name="T20260611-000011-dep.md")
        cwd = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, cwd)
        self.assertEqual(lint_tasks.main(["--changed"]), 0)

    # --- scheduled: when-advanced rule ----------------------------------------

    def test_coding_without_scheduled_fails(self):
        f = write_task(self.root,
                       frontmatter="status: Coding\nestimation: 1d")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m and "missing" in m for m in out), out)

    def test_open_without_scheduled_passes(self):
        # Open tasks are not required to carry scheduled:.
        f = write_task(self.root,
                       frontmatter="status: Open\nestimation: 1d")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_parked_without_scheduled_passes(self):
        # Parked tasks are not required to carry scheduled:.
        f = write_task(self.root,
                       frontmatter="status: Parked\nestimation: 1d", sub="PARKING")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_design_without_scheduled_fails(self):
        f = write_task(self.root,
                       frontmatter="status: Design\nestimation: 2h")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m for m in out), out)

    def test_prose_suffixed_coding_without_scheduled_fails(self):
        # 'Coding — UNBLOCKED …' has leading token 'Coding' → still must carry
        # scheduled: (sync-agreement guard: this status syncs as Coding).
        f = write_task(self.root,
                       frontmatter=(
                           "status: Coding — UNBLOCKED 2026-06-06: pick B\n"
                           "estimation: 2h"))
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m for m in out), out)

    def test_coding_with_valid_scheduled_passes(self):
        f = write_task(self.root,
                       frontmatter="status: Coding\nestimation: 1d\nscheduled: 2026-06-09")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_coding_with_invalid_scheduled_fails(self):
        # scheduled: present but not YYYY-MM-DD → still a violation.
        f = write_task(self.root,
                       frontmatter="status: Coding\nestimation: 1d\nscheduled: next-monday")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m and "not a valid" in m for m in out), out)

    def test_queue_md_is_not_a_task_file(self):
        # dev/TODO/queue.md is the /todo priority-queue index (T20260702-947261
        # follow-up), not a task file — it has no frontmatter and won't match
        # the T<id>-<slug>.md filename pattern by design.
        f = Path(self.root) / "dev" / "TODO" / "queue.md"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("# TODO Queue\n\n- T20260611-000001: Demo\n", encoding="utf-8")
        self.assertFalse(lint_tasks.is_task_file(f))

    def test_iter_task_files_skips_queue_md(self):
        write_task(self.root)
        queue = Path(self.root) / "dev" / "TODO" / "queue.md"
        queue.write_text("# TODO Queue\n", encoding="utf-8")
        found = list(lint_tasks.iter_task_files(self.root))
        self.assertNotIn(queue, found)
        self.assertEqual(len(found), 1)

    def test_changed_mode_ignores_queue_md(self):
        # main()'s --changed path filters through is_task_file too — a PR that
        # only touches queue.md (e.g. /stage, /top) must not fail schema lint.
        queue = Path(self.root) / "dev" / "TODO" / "queue.md"
        queue.parent.mkdir(parents=True, exist_ok=True)
        queue.write_text("# TODO Queue\n", encoding="utf-8")
        rc = lint_tasks.main(["--changed", str(queue), self.root])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
