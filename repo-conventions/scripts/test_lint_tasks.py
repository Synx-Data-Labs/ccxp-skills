#!/usr/bin/env python3
import os
import unittest
import tempfile
from pathlib import Path

import lint_tasks


def write_task(root, name="T20260611-000001-demo.md",
               frontmatter="status: Open\nestimation: 2",
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
        f = write_task(self.root, frontmatter="estimation: 2")
        self.assertIn("missing required field 'status'", lint_tasks.lint_file(f))

    def test_missing_estimation_fails(self):
        f = write_task(self.root, frontmatter="status: Open")
        self.assertIn("missing required field 'estimation'", lint_tasks.lint_file(f))

    def test_prose_suffixed_status_passes(self):
        f = write_task(self.root, frontmatter=(
            "status: In Progress — UNBLOCKED 2026-06-06: maintainer picked B\n"
            "estimation: 2\n"
            "scheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_unknown_status_fails(self):
        f = write_task(self.root, frontmatter="status: Inprogress\nestimation: 2")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("not a known status" in m for m in out), out)

    def test_in_progress_status_passes(self):
        # T20260809-355059: "In Progress" is the one two-word status name —
        # task_claim.sh acquire writes it, so lint must accept it (a
        # one-word lookalike typo like "Inprogress" above must still fail).
        f = write_task(self.root, frontmatter=(
            "status: In Progress\nestimation: 2\nscheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_prose_suffixed_in_progress_status_passes(self):
        f = write_task(self.root, frontmatter=(
            "status: In Progress — SUPERVISED (needs a human)\n"
            "estimation: 2\n"
            "scheduled: 2026-06-09"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_tier_1_to_4_passes(self):
        for t in ("1", "2", "3", "4"):
            f = write_task(self.root, frontmatter=f"status: Open\nestimation: 2\ntier: {t}")
            self.assertEqual(lint_tasks.lint_file(f), [], t)

    def test_tier_out_of_range_fails(self):
        for t in ("0", "5", "high", "2.5", ""):
            f = write_task(self.root, frontmatter=f"status: Open\nestimation: 2\ntier: {t}")
            out = lint_tasks.lint_file(f)
            self.assertTrue(any("tier" in m and "1..4" in m for m in out), (t, out))

    def test_bad_estimation_fails(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: soon")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must be one of" in m for m in out), out)

    def test_legacy_duration_estimation_fails(self):
        # No compatibility window (T20260924-232855 Migration §4) — a
        # leftover duration-bucket value fails lint immediately once this
        # repo has migrated, same as any other invalid value.
        f = write_task(self.root, frontmatter="status: Open\nestimation: 2h")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must be one of" in m for m in out), out)

    def test_estimation_with_prose_suffix_passes(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: 2 (S)")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_estimation_rejects_non_fibonacci_integer(self):
        # 4 and 6 are not in the {1,2,3,5,8} Fibonacci-style enum.
        f = write_task(self.root, frontmatter="status: Open\nestimation: 4")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must be one of" in m for m in out), out)

    def test_estimation_accepts_each_fibonacci_value(self):
        for v in (1, 2, 3, 5, 8):
            f = write_task(self.root, name=f"T20260611-00000{v}-demo.md",
                            frontmatter=f"status: Open\nestimation: {v}")
            self.assertEqual(lint_tasks.lint_file(f), [], v)

    def test_estimation_rejects_a_digit_followed_by_non_whitespace(self):
        # A naive `^(1|2|3|5|8)\b` regex would wrongly accept "1-2h" — \b
        # matches the word/non-word transition right after the leading "1",
        # regardless of what garbage follows. Require whitespace or
        # end-of-string after the point value instead.
        f = write_task(self.root, frontmatter="status: Open\nestimation: 1-2h")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must be one of" in m for m in out), out)

    def test_estimation_rejects_multi_digit_number(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: 28")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("must be one of" in m for m in out), out)

    def test_unknown_field_fails(self):
        f = write_task(self.root,
            frontmatter="status: Open\nestimation: 2\nname: Foo")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("unknown field 'name'" in m for m in out), out)

    def test_support_keys_pass(self):
        f = write_task(self.root, frontmatter=(
            "status: Open\nestimation: 1\n"
            "support-issue: https://example.com/acme/repo/issues/7\n"
            "support-report: off"))
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_support_lookalike_key_still_fails(self):
        f = write_task(self.root,
            frontmatter="status: Open\nestimation: 1\nsupport-ticket: 7")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("unknown field 'support-ticket'" in m for m in out), out)

    def test_allowed_extra_fields_pass(self):
        f = write_task(self.root, frontmatter=(
            "status: Open\nestimation: 2\n"
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

    def test_done_status_in_todo_fails(self):
        f = write_task(self.root, frontmatter=(
            "status: Done\nestimation: 2\nscheduled: 2026-06-09"), sub="TODO")
        out = lint_tasks.lint_file(f)
        self.assertTrue(
            any("still in dev/TODO" in m and "T20260914-422854" in m
                for m in out), out)

    def test_done_status_in_parking_passes(self):
        f = write_task(self.root, frontmatter=(
            "status: Done\nestimation: 2\nscheduled: 2026-06-09"), sub="PARKING")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_closed_status_in_todo_fails(self):
        # sync.py's status_to_option_id treats "closed"-leading status as
        # Done-equivalent for the board sync — the guard must too, or a
        # Closed-but-stranded-in-TODO file is exactly the symptom this check
        # exists for, just via the other spelling.
        f = write_task(self.root, frontmatter=(
            "status: Closed\nestimation: 2\nscheduled: 2026-06-09"), sub="TODO")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("still in dev/TODO" in m for m in out), out)

    def test_narrated_done_status_in_todo_fails(self):
        f = write_task(self.root, frontmatter=(
            "status: Done — superseded by T20260914-422854\n"
            "estimation: 2\nscheduled: 2026-06-09"), sub="TODO")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("still in dev/TODO" in m for m in out), out)

    def test_non_done_status_in_todo_passes_the_new_check(self):
        f = write_task(self.root, sub="TODO")  # default status: Open
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_all_lints_todo_and_parking_skips_journal(self):
        write_task(self.root, name="T20260611-000001-good.md", sub="TODO")
        write_task(self.root, name="T20260611-000002-park.md",
                   frontmatter="status: Parked\nestimation: 2", sub="PARKING")
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
            "status: Blocked by T20260611-000010\nestimation: 2"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_done_blocker_fails(self):
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertIn(dep, out)
        self.assertTrue(any("already Done" in m for m in out[dep]), out)

    def test_blocked_by_live_wins_over_stale_journal_entry(self):
        # A re-opened blocker: live file in TODO + a lingering old JOURNAL entry
        # with the same id. Live must win — no false "already Done".
        write_journal(self.root, "2026-01-01-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000010-blocker.md")  # re-opened, live
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_multiple_blockers_flags_only_done_one(self):
        write_task(self.root, name="T20260611-000010-live.md")  # live
        write_journal(self.root, "2026-06-17-T20260611-000020-done.md")  # done
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010 and T20260611-000020\n"
            "estimation: 2"))
        out = lint_tasks.lint_blocked_by(self.root)
        msgs = out.get(dep, [])
        self.assertEqual(len(msgs), 1, msgs)  # only the Done blocker flagged
        self.assertIn("T20260611-000020", msgs[0])

    def test_bare_blocked_status_without_id_passes(self):
        # `status: Blocked` with no T-id names nothing to resolve — not flagged.
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked — external vendor\nestimation: 2"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_non_blocked_status_mentioning_id_is_ignored(self):
        # A Done blocker id mentioned in a NON-blocked status must NOT be flagged
        # (only `status: Blocked by …` triggers the cross-reference).
        write_journal(self.root, "2026-06-17-T20260611-000010-done.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: In Progress — superseded T20260611-000010\nestimation: 2"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_blocked_by_missing_blocker_fails(self):
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-999999\nestimation: 2"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertTrue(any("not found" in m for m in out.get(dep, [])), out)

    def test_blocked_by_prose_suffixed_status_resolves_id(self):
        # 'Blocked by T<id> — <prose>' must still resolve the named blocker.
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        dep = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010 — waiting on review\n"
            "estimation: 2"))
        out = lint_tasks.lint_blocked_by(self.root)
        self.assertTrue(any("already Done" in m for m in out.get(dep, [])), out)

    def test_blocked_by_ignores_prose_blocked_by_field(self):
        # status is NOT Blocked; the free-text blocked-by field names a Done id
        # in strikethrough (a historical note) — must NOT be flagged.
        write_journal(self.root, "2026-06-17-T20260611-000010-old.md")
        f = write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Open\nestimation: 2\n"
            "blocked-by: '~~T20260611-000010~~ closed 2026-06-17'"))
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})
        self.assertEqual(lint_tasks.lint_file(f), [])  # schema still clean

    def test_all_mode_fails_on_stale_blocker(self):
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2"))
        self.assertEqual(lint_tasks.main(["--all", self.root]), 1)

    def test_changed_mode_catches_stale_blocker_on_unchanged_file(self):
        # The close-the-blocker PR touches only the blocker (now in JOURNAL);
        # the board-wide pass must still flag the *unchanged* dependent even
        # when --changed names an unrelated, schema-clean file.
        write_journal(self.root, "2026-06-17-T20260611-000010-blocker.md")
        write_task(self.root, name="T20260611-000011-dep.md", frontmatter=(
            "status: Blocked by T20260611-000010\nestimation: 2"))
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
            "status: Blocked by T20260611-000010\nestimation: 2"))
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

    def test_in_progress_without_scheduled_fails(self):
        f = write_task(self.root,
                       frontmatter="status: In Progress\nestimation: 3")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m and "missing" in m for m in out), out)

    def test_open_without_scheduled_passes(self):
        # Open tasks are not required to carry scheduled:.
        f = write_task(self.root,
                       frontmatter="status: Open\nestimation: 3")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_parked_without_scheduled_passes(self):
        # Parked tasks are not required to carry scheduled:.
        f = write_task(self.root,
                       frontmatter="status: Parked\nestimation: 3", sub="PARKING")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_design_without_scheduled_fails(self):
        f = write_task(self.root,
                       frontmatter="status: Design\nestimation: 2")
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m for m in out), out)

    def test_prose_suffixed_in_progress_without_scheduled_fails(self):
        # 'In Progress — UNBLOCKED …' has leading token 'In Progress' → still
        # must carry scheduled: (sync-agreement guard: this status syncs as
        # In Progress).
        f = write_task(self.root,
                       frontmatter=(
                           "status: In Progress — UNBLOCKED 2026-06-06: pick B\n"
                           "estimation: 2"))
        out = lint_tasks.lint_file(f)
        self.assertTrue(any("scheduled:" in m for m in out), out)

    def test_in_progress_with_valid_scheduled_passes(self):
        f = write_task(self.root,
                       frontmatter="status: In Progress\nestimation: 3\nscheduled: 2026-06-09")
        self.assertEqual(lint_tasks.lint_file(f), [])

    def test_in_progress_with_invalid_scheduled_fails(self):
        # scheduled: present but not YYYY-MM-DD → still a violation.
        f = write_task(self.root,
                       frontmatter="status: In Progress\nestimation: 3\nscheduled: next-monday")
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


class DimensionsTest(unittest.TestCase):
    """T20261114-352324: when / when-end / place / person / type, typed blockers."""
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def lint(self, extra, status="Open"):
        f = write_task(self.root, frontmatter=f"status: {status}\nestimation: 2\nscheduled: 2026-11-16\n{extra}")
        return lint_tasks.lint_file(f)

    def test_old_task_without_keys_passes(self):
        self.assertEqual(self.lint(""), [])

    def test_accepted_forms(self):
        fm = ("when: 2026-11-14\nwhen-end: 2026-11-15T10:00:00Z\n"
              "place: [office, vpn]\nperson: person-a\ntype: feature")
        self.assertEqual(self.lint(fm), [])

    def test_datetime_with_offset_and_yaml_datetime(self):
        self.assertEqual(self.lint("when: 2026-11-14T14:00+08:00"), [])
        self.assertEqual(self.lint("when: 2026-11-14T14:00"), [])

    def test_bad_when_format(self):
        self.assertTrue(any("when" in m for m in self.lint("when: tomorrow")))
        self.assertTrue(any("when" in m for m in self.lint("when: 2026-11-14 14:00")))

    def test_when_end_before_when(self):
        errs = self.lint("when: 2026-11-14\nwhen-end: 2026-11-13")
        self.assertTrue(any("before" in m for m in errs))

    def test_when_end_date_same_day_as_datetime_when_ok(self):
        self.assertEqual(self.lint("when: 2026-11-14T10:00\nwhen-end: 2026-11-14"), [])

    def test_event_with_null_when_fails(self):
        self.assertTrue(any("requires 'when'" in m for m in self.lint("type: event\nwhen:")))

    def test_email_in_person_or_place(self):
        self.assertTrue(any("email" in m for m in self.lint("person: a@b.com")))
        self.assertTrue(any("email" in m for m in self.lint("place: [x@y.org]")))

    def test_whitespace_in_slug(self):
        self.assertTrue(self.lint("place: needs VPN"))
        self.assertTrue(self.lint("person: [person a]"))

    def test_non_list_value(self):
        self.assertTrue(any("slug" in m for m in self.lint("place: {a: b}")))

    def test_type_enum_and_event_guard(self):
        self.assertTrue(any("type" in m for m in self.lint("type: gadget")))
        self.assertEqual(self.lint("type: bug"), [])
        self.assertTrue(any("requires 'when'" in m for m in self.lint("type: event")))
        self.assertEqual(self.lint("type: event\nwhen: 2026-12-01"), [])

    def test_fallback_parser_prose_value(self):
        # unquoted ': ' breaks yaml -> line-based parser; raw strings are checked
        fm = "source: Owner request: call\nplace: [office, vpn]\nwhen: 2026-11-14"
        self.assertEqual(self.lint(fm), [])
        self.assertTrue(self.lint("source: Owner request: call\nperson: a@b.com"))

    def test_typed_blockers(self):
        self.assertEqual(self.lint("", "Blocked by person:person-a"), [])
        self.assertEqual(self.lint("", "Blocked by ext:vendor reply"), [])
        self.assertTrue(any("email" in m for m in self.lint("", "Blocked by person:a@b.com")))
        errs = self.lint("", "Blocked by ext:waiting on T20260101-000001")
        self.assertTrue(any("T<id>" in m for m in errs))

    def test_typed_blocker_passes_board_pass(self):
        write_task(self.root, frontmatter="status: Blocked by person:person-a\nestimation: 1\nscheduled: 2026-11-16")
        self.assertEqual(lint_tasks.lint_blocked_by(self.root), {})

    def test_task_id_blocker_still_checked(self):
        write_task(self.root, frontmatter="status: Blocked by T20260101-000009\nestimation: 1\nscheduled: 2026-11-16")
        self.assertEqual(len(lint_tasks.lint_blocked_by(self.root)), 1)

    def test_warning_past_when_exit_zero(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: 1\nwhen: 2020-01-01")
        self.assertEqual(lint_tasks.lint_file(f), [])
        w = lint_tasks.warnings_for(f, today="2026-11-16")
        self.assertEqual(len(w), 1)
        self.assertEqual(lint_tasks.main(["--all", self.root]), 0)

    def test_warning_event_passed_and_none_for_done_or_future(self):
        f = write_task(self.root, frontmatter="status: Open\nestimation: 1\ntype: event\nwhen: 2020-01-01")
        self.assertIn("close it", lint_tasks.warnings_for(f, today="2026-11-16")[0])
        g = write_task(self.root, name="T20260611-000002-x.md", frontmatter="status: Open\nestimation: 1\nwhen: 2030-01-01")
        self.assertEqual(lint_tasks.warnings_for(g, today="2026-11-16"), [])
        h = write_task(self.root, name="T20260611-000003-x.md", frontmatter="status: Parked\nestimation: 1\nwhen: 2020-01-01")
        self.assertEqual(lint_tasks.warnings_for(h, today="2026-11-16"), [])


if __name__ == "__main__":
    unittest.main()
