#!/usr/bin/env python3
"""Unit tests for the canonical sync-tasks action script."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).resolve().parent / "sync.py"


def _load():
    os.environ.setdefault("GH_REPO", "your-org/ccxp-skills")
    os.environ.setdefault("GH_TOKEN", "dummy")
    spec = importlib.util.spec_from_file_location("sync_mod", SCRIPT_PATH)
    m = importlib.util.module_from_spec(spec)
    sys.modules["sync_mod"] = m
    spec.loader.exec_module(m)
    return m


sync = _load()


class ExtractBlockersTests(unittest.TestCase):
    def test_blocked_by_markdown_link(self):
        self.assertEqual(
            sync.extract_blockers({"status": "Blocked",
                                   "blocked-by": "[T20260418-124634](T20260418-124634-drata.md)"}),
            "T20260418-124634")

    def test_status_blocked_by_id(self):
        self.assertEqual(
            sync.extract_blockers({"status": "Blocked by T20260101-000001"}),
            "T20260101-000001")

    def test_both_sources_deduped_ordered(self):
        self.assertEqual(
            sync.extract_blockers({"status": "Blocked by T20260101-000001",
                                   "blocked_by": "T20260202-000002, T20260101-000001"}),
            "T20260202-000002, T20260101-000001")

    def test_not_blocked_empty(self):
        self.assertEqual(sync.extract_blockers({"status": "Design"}), "")


class ModeSyncRenameTests(unittest.TestCase):
    def test_rename_to_parking_creates_and_closes_issue(self):
        diff_output = (
            "R100\tdev/TODO/T20260514-123456-example.md\t"
            "dev/PARKING/T20260514-123456-example.md\n"
        )
        issue_map = {}
        completed = subprocess.CompletedProcess(
            args=["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
            returncode=0,
            stdout=diff_output,
            stderr="",
        )

        with patch.dict(os.environ, {"GITHUB_SHA": "abcdef12"}, clear=False), \
             patch.object(sync.subprocess, "run", return_value=completed), \
             patch.object(sync, "create_issue", return_value=(42, None)) as create_issue, \
             patch.object(sync, "add_label") as add_label, \
             patch.object(sync, "close_issue") as close_issue:
            sync.mode_sync(issue_map)

        self.assertEqual(
            issue_map,
            {
                "T20260514-123456": {
                    "issue": 42,
                    "path": "dev/PARKING/T20260514-123456-example.md",
                }
            },
        )
        create_issue.assert_called_once_with(
            "T20260514-123456",
            "dev/PARKING/T20260514-123456-example.md",
            "PARKING",
        )
        add_label.assert_called_once_with(42, sync.PARKED_LABEL)
        close_issue.assert_called_once_with(
            42,
            reason="not_planned",
            comment="Task moved to PARKING (dev/PARKING/T20260514-123456-example.md) in abcdef12.",
        )

    def test_rename_to_parking_uses_unknown_when_sha_missing(self):
        diff_output = (
            "R100\tdev/TODO/T20260514-123456-example.md\t"
            "dev/PARKING/T20260514-123456-example.md\n"
        )
        issue_map = {}
        completed = subprocess.CompletedProcess(
            args=["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
            returncode=0,
            stdout=diff_output,
            stderr="",
        )

        with patch.dict(os.environ, {"GITHUB_SHA": ""}, clear=False), \
             patch.object(sync.subprocess, "run", return_value=completed), \
             patch.object(sync, "create_issue", return_value=(42, None)), \
             patch.object(sync, "add_label"), \
             patch.object(sync, "close_issue") as close_issue:
            sync.mode_sync(issue_map)

        close_issue.assert_called_once_with(
            42,
            reason="not_planned",
            comment="Task moved to PARKING (dev/PARKING/T20260514-123456-example.md) in unknown.",
        )


class CloseIssueReasonTests(unittest.TestCase):
    """close_issue maps internal reason tokens to the values `gh issue close
    --reason` accepts ({completed | not planned | duplicate}), surfaces a failed
    close instead of swallowing it, and refuses unknown reasons."""

    @staticmethod
    def _ok(args=None):
        return subprocess.CompletedProcess(args=args or [], returncode=0, stdout="", stderr="")

    def test_not_planned_mapped_to_gh_token(self):
        calls = []

        def fake_gh(args, check=True):
            calls.append(args)
            return self._ok(args)

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=fake_gh):
            sync.close_issue(7, reason="not_planned")

        close_call = next(a for a in calls if a[:2] == ["issue", "close"])
        self.assertIn("not planned", close_call)
        self.assertNotIn("not_planned", close_call)

    def test_completed_passes_through(self):
        calls = []
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=lambda args, check=True: calls.append(args) or self._ok(args)):
            sync.close_issue(7, reason="completed")
        close_call = next(a for a in calls if a[:2] == ["issue", "close"])
        self.assertIn("completed", close_call)

    def test_successful_close_returns_true(self):
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=lambda args, check=True: self._ok(args)):
            self.assertIs(sync.close_issue(7, reason="completed"), True)

    def test_failed_close_returns_false_not_swallowed(self):
        def fake_gh(args, check=True):
            if args[:2] == ["issue", "close"]:
                return subprocess.CompletedProcess(args=args, returncode=1, stdout="", stderr="boom")
            return self._ok(args)

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=fake_gh):
            self.assertIs(sync.close_issue(7, reason="completed"), False)

    def test_unknown_reason_skips_close(self):
        calls = []
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=lambda args, check=True: calls.append(args) or self._ok(args)):
            result = sync.close_issue(7, reason="bogus")
        self.assertIs(result, False)
        self.assertEqual([a for a in calls if a[:2] == ["issue", "close"]], [])


class ModeSyncSplitMoveTests(unittest.TestCase):
    """A TODO→JOURNAL completion whose commit also rewrites the file body drops
    below git's -M rename threshold, so the diff is a separate D (old path) + A
    (new path) sharing one task-id. mode_sync must recognize the pair and apply
    the real transition (close `completed`), not a bare not_planned delete."""

    @staticmethod
    def _diff(stdout):
        return subprocess.CompletedProcess(
            args=["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
            returncode=0, stdout=stdout, stderr="")

    def test_split_delete_add_todo_to_journal_closes_completed(self):
        diff = (
            "A\tdev/JOURNAL/2026-06-12-T20260514-123456-example.md\n"
            "D\tdev/TODO/T20260514-123456-example.md\n"
        )
        issue_map = {"T20260514-123456": {"issue": 42,
                                          "path": "dev/TODO/T20260514-123456-example.md"}}
        journal = "dev/JOURNAL/2026-06-12-T20260514-123456-example.md"
        with patch.dict(os.environ, {"GITHUB_SHA": "abcdef12"}, clear=False), \
             patch.object(sync.subprocess, "run", return_value=self._diff(diff)), \
             patch.object(sync, "_resync_fields_for", return_value=0), \
             patch.object(sync, "update_issue_body") as update_body, \
             patch.object(sync, "close_issue") as close_issue:
            sync.mode_sync(issue_map)

        close_issue.assert_called_once_with(
            42, reason="completed",
            comment=f"Task moved to JOURNAL ({journal}) in abcdef12.")
        update_body.assert_called_once_with(42, journal, "JOURNAL")
        self.assertEqual(issue_map["T20260514-123456"]["path"], journal)

    def test_pure_delete_without_add_stays_not_planned(self):
        diff = "D\tdev/TODO/T20260514-123456-example.md\n"
        issue_map = {"T20260514-123456": {"issue": 42,
                                          "path": "dev/TODO/T20260514-123456-example.md"}}
        with patch.dict(os.environ, {"GITHUB_SHA": "abcdef12"}, clear=False), \
             patch.object(sync.subprocess, "run", return_value=self._diff(diff)), \
             patch.object(sync, "close_issue") as close_issue:
            sync.mode_sync(issue_map)

        self.assertEqual(close_issue.call_count, 1)
        self.assertEqual(close_issue.call_args.kwargs.get("reason"), "not_planned")


class ModeSyncModifyTests(unittest.TestCase):
    """In-place frontmatter edits (git status M) must resync Project fields
    (Status/Iteration/dates) — the IPM carries a task forward by rewriting
    `scheduled:` in a file that stays in dev/TODO, which git reports as M."""

    @staticmethod
    def _diff(stdout):
        return subprocess.CompletedProcess(
            args=["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
            returncode=0,
            stdout=stdout,
            stderr="",
        )

    def test_modify_in_place_resyncs_fields_for_mapped_file(self):
        path = "dev/TODO/T20260514-123456-example.md"
        entry = {"issue": 42, "path": path, "project_item_id": "PVTI_x"}
        issue_map = {"T20260514-123456": entry}

        with patch.object(sync.subprocess, "run", return_value=self._diff(f"M\t{path}\n")), \
             patch.object(sync, "_resync_fields_for", return_value=1) as resync, \
             patch.object(sync, "create_issue") as create_issue:
            sync.mode_sync(issue_map)

        resync.assert_called_once_with(entry, path, {})
        create_issue.assert_not_called()

    def test_modify_in_place_unmapped_is_noop(self):
        # An unmapped M is a plain no-op: build_index() already discovered
        # every existing issue at run start (replacing the old per-task
        # find_issue_by_task_id self-heal), so absence from the index means
        # the issue genuinely doesn't exist. M never creates issues (only A/R
        # do).
        path = "dev/TODO/T20260514-999999-orphan.md"
        issue_map = {}

        with patch.object(sync.subprocess, "run", return_value=self._diff(f"M\t{path}\n")), \
             patch.object(sync, "_resync_fields_for", return_value=0) as resync, \
             patch.object(sync, "create_issue") as create_issue:
            sync.mode_sync(issue_map)

        resync.assert_not_called()
        create_issue.assert_not_called()
        self.assertEqual(issue_map, {})

    def test_modify_in_place_indexed_entry_resyncs(self):
        # The orphaned-map-PR failure mode (T20260608-125662) is now covered
        # structurally: an issue that would have "fallen out of the map" is
        # rediscovered by build_index() at run start, so the M edit finds it
        # in the index and resyncs its fields.
        path = "dev/TODO/T20260514-888888-rediscovered.md"
        entry = {"issue": 404, "node_id": "I_node404", "path": path}
        issue_map = {"T20260514-888888": entry}

        with patch.object(sync.subprocess, "run", return_value=self._diff(f"M\t{path}\n")), \
             patch.object(sync, "_resync_fields_for", return_value=1) as resync, \
             patch.object(sync, "create_issue") as create_issue:
            sync.mode_sync(issue_map)

        create_issue.assert_not_called()  # index hit means never duplicate
        resync.assert_called_once_with(entry, path, {})


class ReconcileModeTests(unittest.TestCase):
    """`MODE=reconcile` resyncs Project fields for every mapped item without
    creating issues — the one-time backfill and a future cron heartbeat."""

    def test_reconcile_mode_calls_ensure_on_project(self):
        issue_map = {"T20260514-123456": {"issue": 42, "path": "dev/TODO/x.md"}}
        ipm_map = {"2026-06-29": {"issue": 99}}
        original_mode = sync.MODE
        try:
            sync.MODE = "reconcile"
            with patch.object(sync, "build_index", return_value=issue_map), \
                 patch.object(sync, "build_ipm_index", return_value=ipm_map), \
                 patch.object(sync, "ensure_on_project") as eop, \
                 patch.object(sync, "ensure_ipm_on_project") as eiop, \
                 patch.object(sync, "mode_backfill") as backfill, \
                 patch.object(sync, "mode_sync") as mode_sync:
                sync.main()
            eop.assert_called_once_with(issue_map)
            eiop.assert_called_once_with(ipm_map)
            backfill.assert_not_called()
            mode_sync.assert_not_called()
        finally:
            sync.MODE = original_mode


class FindIterationIdTests(unittest.TestCase):
    def test_finds_containing_iteration(self):
        iterations = [
            {"id": "it_1", "startDate": "2026-05-01", "duration": 14},
            {"id": "it_2", "startDate": "2026-05-15", "duration": 14},
        ]
        self.assertEqual(sync.find_iteration_id("2026-05-03", iterations), "it_1")
        self.assertEqual(sync.find_iteration_id("2026-05-17", iterations), "it_2")

    def test_exact_start_date_matches(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01", "duration": 7}]
        self.assertEqual(sync.find_iteration_id("2026-05-01", iterations), "it_1")

    def test_last_day_exclusive(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01", "duration": 7}]
        self.assertIsNone(sync.find_iteration_id("2026-05-08", iterations))

    def test_no_match_returns_none(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01", "duration": 7}]
        self.assertIsNone(sync.find_iteration_id("2026-05-15", iterations))

    def test_empty_iterations(self):
        self.assertIsNone(sync.find_iteration_id("2026-05-01", []))

    def test_none_iterations(self):
        self.assertIsNone(sync.find_iteration_id("2026-05-01", None))

    def test_invalid_scheduled_returns_none(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01", "duration": 7}]
        self.assertIsNone(sync.find_iteration_id("not-a-date", iterations))

    def test_none_scheduled_returns_none(self):
        self.assertIsNone(sync.find_iteration_id(None, []))

    def test_missing_duration_defaults_to_7(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01"}]
        self.assertEqual(sync.find_iteration_id("2026-05-05", iterations), "it_1")
        self.assertIsNone(sync.find_iteration_id("2026-05-08", iterations))

    def test_invalid_duration_defaults_to_7(self):
        iterations = [{"id": "it_1", "startDate": "2026-05-01", "duration": "bad"}]
        self.assertEqual(sync.find_iteration_id("2026-05-05", iterations), "it_1")


class JournalCloseDateTests(unittest.TestCase):
    def test_parses_date_prefix(self):
        self.assertEqual(
            sync.journal_close_date("dev/JOURNAL/2026-06-10-T20260601-704122-x.md"),
            "2026-06-10")

    def test_bare_filename(self):
        self.assertEqual(
            sync.journal_close_date("2026-01-02-T20260101-000001-y.md"), "2026-01-02")

    def test_no_date_prefix_returns_none(self):
        # Legacy JOURNAL files without the YYYY-MM-DD- prefix → no inferred date.
        self.assertIsNone(sync.journal_close_date("dev/JOURNAL/T20260101-000001-z.md"))


class JournalIterationFallbackTests(unittest.TestCase):
    """A CLOSED (JOURNAL) task with no `scheduled` falls back to its close-date
    (filename prefix) for the Iteration; a LIVE (TODO) task with no `scheduled`
    keeps the backlog invariant (iteration CLEARED)."""

    ITERS = {"id": "FIELD_IT", "iterations": [
        {"id": "it_jun8", "startDate": "2026-06-08", "duration": 7},  # contains 2026-06-10
    ]}

    def test_closed_task_without_scheduled_uses_close_date(self):
        path = "dev/JOURNAL/2026-06-10-T20260601-704122-example.md"
        with patch.object(sync, "get_frontmatter", return_value={}), \
             patch.object(sync, "update_iteration", return_value=True) as upd, \
             patch.object(sync, "clear_field", return_value=False) as clr:
            sync.sync_fields("PVTI_x", path, {"Iteration": dict(self.ITERS)})
        upd.assert_called_once_with("PVTI_x", "FIELD_IT", "it_jun8")
        clr.assert_not_called()

    def test_closed_scheduled_still_wins_over_close_date(self):
        path = "dev/JOURNAL/2026-06-10-T20260601-704122-example.md"
        iters = {"id": "FIELD_IT", "iterations": [
            {"id": "it_jun8", "startDate": "2026-06-08", "duration": 7},
            {"id": "it_jun1", "startDate": "2026-06-01", "duration": 7},
        ]}
        with patch.object(sync, "get_frontmatter", return_value={"scheduled": "2026-06-02"}), \
             patch.object(sync, "update_iteration", return_value=True) as upd, \
             patch.object(sync, "clear_field", return_value=False) as clr:
            sync.sync_fields("PVTI_x", path, {"Iteration": iters})
        upd.assert_called_once_with("PVTI_x", "FIELD_IT", "it_jun1")
        clr.assert_not_called()

    def test_live_task_without_scheduled_clears_iteration(self):
        path = "dev/TODO/T20260601-704122-example.md"
        with patch.object(sync, "get_frontmatter", return_value={}), \
             patch.object(sync, "update_iteration", return_value=True) as upd, \
             patch.object(sync, "clear_field", return_value=True) as clr:
            sync.sync_fields("PVTI_x", path, {"Iteration": dict(self.ITERS)})
        upd.assert_not_called()
        clr.assert_called_once_with("PVTI_x", "FIELD_IT")

    def test_closed_task_unmapped_close_date_clears(self):
        # close-date outside every defined iteration window → still cleared.
        path = "dev/JOURNAL/2025-01-01-T20250101-000001-old.md"
        with patch.object(sync, "get_frontmatter", return_value={}), \
             patch.object(sync, "update_iteration", return_value=True) as upd, \
             patch.object(sync, "clear_field", return_value=True) as clr:
            sync.sync_fields("PVTI_x", path, {"Iteration": dict(self.ITERS)})
        upd.assert_not_called()
        clr.assert_called_once_with("PVTI_x", "FIELD_IT")


class StatusToOptionIdTests(unittest.TestCase):
    def test_direct_match_exact_case(self):
        options = {"Open": "opt_open", "Done": "opt_done"}
        self.assertEqual(sync.status_to_option_id("Open", options), "opt_open")

    def test_direct_match_case_insensitive(self):
        options = {"Open": "opt_open"}
        self.assertEqual(sync.status_to_option_id("open", options), "opt_open")

    def test_blocked_prefix(self):
        options = {"Blocked": "opt_blocked"}
        self.assertEqual(
            sync.status_to_option_id("Blocked by T20260101", options), "opt_blocked"
        )

    def test_blocked_prefix_case_insensitive_option(self):
        options = {"blocked": "opt_blocked"}
        self.assertEqual(
            sync.status_to_option_id("Blocked by someone", options), "opt_blocked"
        )

    def test_closed_prefix_maps_to_done(self):
        options = {"Done": "opt_done"}
        self.assertEqual(sync.status_to_option_id("Closed - finished", options), "opt_done")

    def test_done_prefix_maps_to_done(self):
        options = {"Done": "opt_done"}
        self.assertEqual(sync.status_to_option_id("Done already", options), "opt_done")

    def test_done_prefix_case_insensitive_option(self):
        options = {"done": "opt_done"}
        self.assertEqual(sync.status_to_option_id("Done already", options), "opt_done")

    def test_prose_suffixed_status_matches_leading_option(self):
        # Real-world: T20260320-000029 carries "Coding — UNBLOCKED 2026-06-06:
        # maintainer picked Option B". The leading known option ("Coding") must
        # map even with a free-text suffix, the same way "Blocked by ..." does.
        options = {"Coding": "opt_coding", "Design": "opt_design"}
        self.assertEqual(
            sync.status_to_option_id("Coding — UNBLOCKED 2026-06-06: picked B", options),
            "opt_coding",
        )

    def test_prose_suffixed_status_with_colon(self):
        options = {"Design": "opt_design"}
        self.assertEqual(
            sync.status_to_option_id("Design: re-scoped after review", options),
            "opt_design",
        )

    def test_in_progress_two_word_status_matches(self):
        # T20260809-355059: "In Progress" is the one two-word status name —
        # the leading-token split must treat it as a single unit ("in
        # progress"), not split on its own internal space and try to match
        # the bare word "in" (which the fix below prevents).
        options = {"In Progress": "opt_in_progress"}
        self.assertEqual(
            sync.status_to_option_id("In Progress", options), "opt_in_progress"
        )

    def test_prose_suffixed_in_progress_status_matches_leading_option(self):
        options = {"In Progress": "opt_in_progress"}
        self.assertEqual(
            sync.status_to_option_id(
                "In Progress — SUPERVISED (needs a human)", options
            ),
            "opt_in_progress",
        )

    def test_in_progress_lookalike_typo_does_not_match(self):
        # "Inprogress" (one word) must NOT be treated as the two-word phrase.
        options = {"In Progress": "opt_in_progress"}
        self.assertIsNone(sync.status_to_option_id("Inprogress", options))

    def test_no_match_returns_none(self):
        options = {"Open": "opt_open"}
        self.assertIsNone(sync.status_to_option_id("Unknown", options))

    def test_empty_status_returns_none(self):
        self.assertIsNone(sync.status_to_option_id("", {"Open": "opt_open"}))

    def test_none_status_returns_none(self):
        self.assertIsNone(sync.status_to_option_id(None, {"Open": "opt_open"}))

    def test_none_options_returns_none(self):
        self.assertIsNone(sync.status_to_option_id("Open", None))

    def test_empty_options_returns_none(self):
        self.assertIsNone(sync.status_to_option_id("Open", {}))


class StatusForLocationTests(unittest.TestCase):
    def test_parking_returns_parked(self):
        self.assertEqual(sync.status_for_location("dev/PARKING/T123.md", "Open"), "Parked")

    def test_journal_returns_done(self):
        self.assertEqual(sync.status_for_location("dev/JOURNAL/T123.md", "Open"), "Done")

    def test_todo_returns_frontmatter_status(self):
        self.assertEqual(sync.status_for_location("dev/TODO/T123.md", "Coding"), "Coding")

    def test_todo_returns_none_when_no_frontmatter_status(self):
        self.assertIsNone(sync.status_for_location("dev/TODO/T123.md", None))

    def test_parking_ignores_frontmatter_status(self):
        self.assertEqual(sync.status_for_location("dev/PARKING/T123.md", "Coding"), "Parked")


class GetFrontmatterTests(unittest.TestCase):
    def _write_tmp(self, content):
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False)
        f.write(content)
        f.flush()
        f.close()
        return f.name

    def test_valid_frontmatter(self):
        path = self._write_tmp("---\nstatus: Open\nestimation: S\n---\n# Task\n")
        try:
            meta = sync.get_frontmatter(path)
            self.assertEqual(meta["status"], "Open")
            self.assertEqual(meta["estimation"], "S")
        finally:
            os.unlink(path)

    def test_no_frontmatter_returns_empty(self):
        path = self._write_tmp("# Task\n\nSome body.\n")
        try:
            self.assertEqual(sync.get_frontmatter(path), {})
        finally:
            os.unlink(path)

    def test_missing_file_returns_empty(self):
        self.assertEqual(sync.get_frontmatter("/tmp/nonexistent-xyz-abc.md"), {})

    def test_invalid_yaml_returns_empty(self):
        path = self._write_tmp("---\n: bad: yaml: here\n---\n# Task\n")
        try:
            result = sync.get_frontmatter(path)
            self.assertIsInstance(result, dict)
        finally:
            os.unlink(path)

    def test_prose_colon_in_estimation_recovers_scalars(self):
        # Real-world shape (T20260320-000029): an unquoted ": " inside a prose
        # `estimation:` / `status:` value makes PyYAML raise (it reads the
        # colon-space as a nested mapping). The lenient fallback must still
        # recover the known scalar fields instead of dropping all of them —
        # otherwise the board silently loses Status + Iteration for the task.
        content = (
            "---\n"
            "estimation: 3d (plumbing) — revised up: blast radius now spans more\n"
            "status: Coding — UNBLOCKED 2026-06-06: maintainer picked Option B\n"
            "scheduled: 2026-06-01\n"
            "deadline: 2026-05-08 (set by maintainer)\n"
            "priority: High — latent release-blocker: next eviction breaks it\n"
            "---\n# Task\n"
        )
        path = self._write_tmp(content)
        try:
            meta = sync.get_frontmatter(path)
            self.assertEqual(meta.get("scheduled"), "2026-06-01")
            self.assertTrue(meta.get("status", "").startswith("Coding"))
            self.assertTrue(meta.get("estimation", "").startswith("3d"))
            self.assertTrue(meta.get("deadline", "").startswith("2026-05-08"))
            self.assertTrue(meta.get("priority", "").startswith("High"))
        finally:
            os.unlink(path)

    def test_prose_colon_recovery_includes_claim_fields(self):
        # claimed_by is a consumed scalar (the on-main lock). When a prose-colon
        # elsewhere in the block makes PyYAML raise, the lenient fallback must
        # still recover the claim field — otherwise a malformed sibling line
        # silently drops the claim from the board.
        content = (
            "---\n"
            "status: Coding — UNBLOCKED 2026-06-06: maintainer picked Option B\n"
            "claimed_by: cdw:/home/ci/focus/some-repo\n"
            "---\n# Task\n"
        )
        path = self._write_tmp(content)
        try:
            meta = sync.get_frontmatter(path)
            self.assertEqual(meta.get("claimed_by"),
                             "cdw:/home/ci/focus/some-repo")
        finally:
            os.unlink(path)

    def test_unparseable_frontmatter_logs_warning(self):
        # A YAML parse failure must no longer be swallowed silently — log a
        # warning so future drift is visible in the workflow run.
        path = self._write_tmp("---\nestimation: a: b: c\nstatus: Open\n---\n# Task\n")
        try:
            with patch.object(sync, "log") as mock_log:
                sync.get_frontmatter(path)
            self.assertTrue(
                any("unparseable" in str(c.args[0]).lower()
                    for c in mock_log.call_args_list),
                "expected a warning log on YAML parse failure",
            )
        finally:
            os.unlink(path)

    def test_quoted_prose_colon_parses_strictly(self):
        # Option A (quoting) stays valid and must parse via real YAML — i.e.
        # the fallback only kicks in on an actual error, so structured fields
        # (lists, nested maps) are preserved for well-formed files.
        path = self._write_tmp(
            '---\nstatus: "Coding: in progress"\nscheduled: 2026-06-01\n'
            "blocks: [T20260101-000001, T20260101-000002]\n---\n# Task\n"
        )
        try:
            meta = sync.get_frontmatter(path)
            self.assertEqual(meta["status"], "Coding: in progress")
            # PyYAML auto-types an unquoted ISO date to datetime.date; both that
            # and the lenient string form feed _parse_date the same way.
            self.assertEqual(str(meta["scheduled"]), "2026-06-01")
            self.assertEqual(meta["blocks"], ["T20260101-000001", "T20260101-000002"])
        finally:
            os.unlink(path)


class StatusFromTextTests(unittest.TestCase):
    def test_frontmatter_status(self):
        text = "---\nstatus: Design\n---\n# Task\n"
        self.assertEqual(sync._status_from_text(text), "Design")

    def test_legacy_bullet_status(self):
        text = "# Task\n\n- **Status**: Coding\n"
        self.assertEqual(sync._status_from_text(text), "Coding")

    def test_no_status_returns_none(self):
        text = "# Task\n\nSome content.\n"
        self.assertIsNone(sync._status_from_text(text))

    def test_frontmatter_takes_priority_over_bullet(self):
        text = "---\nstatus: Review\n---\n# Task\n\n- **Status**: Open\n"
        self.assertEqual(sync._status_from_text(text), "Review")

    def test_empty_string_returns_none(self):
        self.assertIsNone(sync._status_from_text(""))

    def test_prose_colon_frontmatter_recovers_status(self):
        # git-history walk (get_start_date) reads via _status_from_text; it
        # must tolerate the same prose-colon shape so the Start-date derivation
        # doesn't blank out on the very commits that introduced the prose value.
        text = (
            "---\n"
            "estimation: 3d — revised up: bigger now\n"
            "status: Coding — UNBLOCKED 2026-06-06: picked Option B\n"
            "---\n# Task\n"
        )
        self.assertTrue(sync._status_from_text(text).startswith("Coding"))


class GetStartDateTests(unittest.TestCase):
    def _completed(self, args, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(args, returncode, stdout=stdout, stderr=stderr)

    def test_returns_date_when_status_changes_from_open(self):
        log_output = "abc123 2026-05-10T10:00:00+00:00\ndef456 2026-05-12T10:00:00+00:00\n"
        file_open = "---\nstatus: Open\n---\n# Task\n"
        file_design = "---\nstatus: Design\n---\n# Task\n"

        calls = iter([
            self._completed(["git", "log"], stdout=log_output),
            self._completed(["git", "show"], stdout=file_open),
            self._completed(["git", "show"], stdout=file_design),
        ])

        with patch.object(sync.subprocess, "run", side_effect=lambda *a, **k: next(calls)):
            result = sync.get_start_date("dev/TODO/T123.md")
        self.assertEqual(result, "2026-05-12")

    def test_returns_none_when_always_open(self):
        log_output = "abc123 2026-05-10T10:00:00+00:00\n"
        file_open = "---\nstatus: Open\n---\n# Task\n"

        calls = iter([
            self._completed(["git", "log"], stdout=log_output),
            self._completed(["git", "show"], stdout=file_open),
        ])

        with patch.object(sync.subprocess, "run", side_effect=lambda *a, **k: next(calls)):
            result = sync.get_start_date("dev/TODO/T123.md")
        self.assertIsNone(result)

    def test_returns_none_when_no_git_history(self):
        with patch.object(
            sync.subprocess, "run",
            return_value=self._completed(["git", "log"], stdout=""),
        ):
            result = sync.get_start_date("dev/TODO/T123.md")
        self.assertIsNone(result)

    def test_returns_none_on_git_failure(self):
        with patch.object(
            sync.subprocess, "run",
            return_value=self._completed(["git", "log"], returncode=1, stderr="fatal"),
        ):
            result = sync.get_start_date("dev/TODO/T123.md")
        self.assertIsNone(result)


class SyncFieldsTests(unittest.TestCase):
    """Tests for sync_fields — verifies field dispatch and update counting."""

    _FIELDS = {
        "Status": {"id": "fld_status", "options": {"Open": "opt_open", "Done": "opt_done"}},
        "Blocked by": {"id": "fld_blocked"},
        "Iteration": {"id": "fld_iter", "iterations": [
            {"id": "it_1", "startDate": "2026-05-01", "duration": 14},
        ]},
        "Estimate": {"id": "fld_est"},
        "End date": {"id": "fld_end"},
        "Start date": {"id": "fld_start"},
    }

    def test_all_fields_updated_when_metadata_present(self):
        meta = {
            "status": "Open",
            "scheduled": "2026-05-05",
            "estimation": "M",
            "deadline": "2026-06-01",
        }
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True) as mock_ss, \
             patch.object(sync, "update_iteration", return_value=True) as mock_iter, \
             patch.object(sync, "clear_field", return_value=True) as mock_clear, \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True) as mock_date, \
             patch.object(sync, "get_start_date", return_value="2026-05-03"):
            count = sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)

        # Status + Blocked-by (cleared "") + Iteration + Estimate + 2 dates
        self.assertEqual(count, 6)
        mock_ss.assert_called_once_with("item_1", "fld_status", "opt_open")
        mock_iter.assert_called_once_with("item_1", "fld_iter", "it_1")
        mock_clear.assert_not_called()  # scheduled maps → set, never clear
        # update_text serves both Estimate and Blocked-by; no blocker here, so
        # the Blocked-by field is written empty (intentional clear-to-empty).
        mock_text.assert_any_call("item_1", "fld_est", "M")
        mock_text.assert_any_call("item_1", "fld_blocked", "")
        self.assertEqual(mock_date.call_count, 2)

    def test_iteration_cleared_when_no_scheduled(self):
        # No `scheduled` → Iteration must be CLEARED (not left stale), since the
        # board iteration strictly mirrors the file's scheduled date.
        meta = {"status": "Open"}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "update_iteration", return_value=True) as mock_iter, \
             patch.object(sync, "clear_field", return_value=True) as mock_clear, \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True), \
             patch.object(sync, "get_start_date", return_value=None):
            count = sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)

        # Status updated + Blocked-by cleared "" + iteration cleared;
        # estimate/end-date/start-date skipped (no estimation/deadline/start).
        self.assertEqual(count, 3)
        mock_iter.assert_not_called()
        mock_clear.assert_called_once_with("item_1", "fld_iter")
        # No estimation → no Estimate write; the only update_text call is the
        # Blocked-by clear-to-empty (no blocker present).
        mock_text.assert_called_once_with("item_1", "fld_blocked", "")

    def test_returns_zero_on_dry_run(self):
        original = sync.DRY_RUN
        try:
            sync.DRY_RUN = True
            count = sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)
        finally:
            sync.DRY_RUN = original
        self.assertEqual(count, 0)

    def test_returns_zero_when_no_item_id(self):
        count = sync.sync_fields(None, "dev/TODO/T123.md", self._FIELDS)
        self.assertEqual(count, 0)

    def test_invalid_deadline_skips_end_date(self):
        meta = {"deadline": "not-a-date"}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True), \
             patch.object(sync, "update_date", return_value=True) as mock_date, \
             patch.object(sync, "get_start_date", return_value=None):
            count = sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)
        mock_date.assert_not_called()  # unparseable deadline → no End date write
        # No status, no scheduled (→ iteration cleared = 1), Blocked-by cleared
        # "" (= 1), no estimate/dates.
        self.assertEqual(count, 2)

    def test_parking_location_maps_status_to_parked(self):
        parking_fields = {
            "Status": {"id": "fld_status", "options": {"Parked": "opt_parked"}},
        }
        meta = {}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True) as mock_ss, \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/PARKING/T123.md", parking_fields)
        mock_ss.assert_called_once_with("item_1", "fld_status", "opt_parked")

    def test_blocked_by_field_written_with_extracted_blocker_id(self):
        # A task whose frontmatter carries a `blocked-by` markdown link must
        # write the extracted blocker id to the Blocked-by TEXT field.
        meta = {
            "status": "Blocked",
            "blocked-by": "[T20260418-124634](T20260418-124634-drata.md)",
        }
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "update_iteration", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True), \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)
        # No estimation in meta, so the only update_text call is Blocked-by.
        mock_text.assert_called_once_with("item_1", "fld_blocked", "T20260418-124634")

    def test_blocked_by_field_cleared_to_empty_when_no_blocker(self):
        # Intentional design: an unblocked task still writes the Blocked-by
        # field as "" — for a TEXT field, writing "" IS the clear, so a stale
        # blocker never lingers on the board. Lock that behavior in.
        meta = {"status": "Open"}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)
        mock_text.assert_called_once_with("item_1", "fld_blocked", "")

    def test_claim_fields_projected_when_present(self):
        # claimed_by is the on-main session lock (_session/task_claim.sh). A
        # LEGACY "<host>:<path>" value still projects verbatim — pre-migration
        # rows on the board must not change shape underneath anyone.
        fields = {
            **self._FIELDS,
            "claimed_by": {"id": "fld_claimed"},
        }
        meta = {
            "status": "Coding",
            "claimed_by": "cdw:/home/ci/focus/some-repo",
        }
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "update_iteration", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True), \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", fields)
        mock_text.assert_any_call("item_1", "fld_claimed", "cdw:/home/ci/focus/some-repo")

    def test_claim_fields_projected_short_with_role_for_cc1(self):
        # A current claimant id is opaque (T20260911-698434), so the board
        # shows a short prefix plus the role — the part a human scanning the
        # board actually wants — instead of 26 characters of hash.
        fields = {
            **self._FIELDS,
            "claimed_by": {"id": "fld_claimed"},
        }
        meta = {
            "status": "Coding",
            "claimed_by": "cc1-a1b2c3d4:9f8e7d6c5b4a3210",
            "claimed_role": "ccxp",
        }
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "update_iteration", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True), \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", fields)
        mock_text.assert_any_call("item_1", "fld_claimed", "cc1-a1b2c3 (ccxp)")

    def test_claim_display_shapes(self):
        d = sync.claim_display
        self.assertEqual(d("cc1-a1b2c3d4:9f8e7d6c5b4a3210", "ccxp"), "cc1-a1b2c3 (ccxp)")
        self.assertEqual(d("cc1-a1b2c3d4:9f8e7d6c5b4a3210", None), "cc1-a1b2c3")
        # Legacy and human-assigned values pass through untouched.
        self.assertEqual(d("cdw:/home/ci/repo", None), "cdw:/home/ci/repo")
        self.assertEqual(d("Alex", None), "Alex")
        # Near-miss shapes are NOT shortened — only the exact format is known.
        self.assertEqual(d("cc1-a1b2c3d4", None), "cc1-a1b2c3d4")
        self.assertEqual(d("cc1-A1B2C3D4:9f8e7d6c5b4a3210", None),
                         "cc1-A1B2C3D4:9f8e7d6c5b4a3210")
        # Clear-to-empty contract.
        self.assertEqual(d("", None), "")
        self.assertEqual(d(None, None), "")

    def test_claim_fields_cleared_to_empty_when_unclaimed(self):
        # A released/unclaimed task carries empty claim frontmatter. Mirror the
        # Blocked-by clear-to-empty contract: always write the claim fields so a
        # stale owner never lingers on the board after release. (Writing "" IS
        # the clear for a TEXT field.)
        fields = {
            **self._FIELDS,
            "claimed_by": {"id": "fld_claimed"},
        }
        meta = {"status": "Open", "claimed_by": ""}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", fields)
        mock_text.assert_any_call("item_1", "fld_claimed", "")

    def test_claim_fields_absent_key_clears_board(self):
        # A task file with no claim lines at all (e.g. an unseeded/legacy file)
        # must still clear the board columns rather than leave a stale value —
        # meta.get returns None, which projects as "".
        fields = {
            **self._FIELDS,
            "claimed_by": {"id": "fld_claimed"},
        }
        meta = {"status": "Open"}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", fields)
        mock_text.assert_any_call("item_1", "fld_claimed", "")

    def test_claim_fields_skipped_when_board_lacks_columns(self):
        # If the Project has no claimed_by column, projection is a no-op (same
        # tolerance as every other optional field), never an error.
        # self._FIELDS has no claim column, so no claim writes happen.
        meta = {"status": "Coding",
                "claimed_by": "cdw:/home/ci/x"}
        with patch.object(sync, "get_frontmatter", return_value=meta), \
             patch.object(sync, "update_single_select", return_value=True), \
             patch.object(sync, "update_iteration", return_value=True), \
             patch.object(sync, "clear_field", return_value=True), \
             patch.object(sync, "update_text", return_value=True) as mock_text, \
             patch.object(sync, "update_date", return_value=True), \
             patch.object(sync, "get_start_date", return_value=None):
            sync.sync_fields("item_1", "dev/TODO/T123.md", self._FIELDS)
        for call in mock_text.call_args_list:
            self.assertNotIn("fld_claimed", call.args)


class FindTaskFileTests(unittest.TestCase):
    """find_task_file re-discovers a task's real location across dev/{TODO,
    PARKING,JOURNAL} by id — the basis for self-healing a stale sidecar path."""

    def _in_tmp_repo(self):
        tmp = tempfile.mkdtemp()
        for d in ("dev/TODO", "dev/PARKING", "dev/JOURNAL"):
            os.makedirs(os.path.join(tmp, d), exist_ok=True)
        return tmp

    def _run_in(self, tmp, fn):
        prev = os.getcwd()
        try:
            os.chdir(tmp)
            return fn()
        finally:
            os.chdir(prev)

    def test_finds_in_todo(self):
        tmp = self._in_tmp_repo()
        open(os.path.join(tmp, "dev/TODO/T20260101-000001-slug.md"), "w").close()
        self.assertEqual(
            self._run_in(tmp, lambda: sync.find_task_file("T20260101-000001")),
            "dev/TODO/T20260101-000001-slug.md",
        )

    def test_finds_in_journal_with_date_prefix(self):
        tmp = self._in_tmp_repo()
        open(os.path.join(tmp, "dev/JOURNAL/2026-05-26-T20260101-000002-slug.md"), "w").close()
        self.assertEqual(
            self._run_in(tmp, lambda: sync.find_task_file("T20260101-000002")),
            "dev/JOURNAL/2026-05-26-T20260101-000002-slug.md",
        )

    def test_prefers_todo_over_journal(self):
        tmp = self._in_tmp_repo()
        open(os.path.join(tmp, "dev/TODO/T20260101-000003-slug.md"), "w").close()
        open(os.path.join(tmp, "dev/JOURNAL/2026-05-26-T20260101-000003-slug.md"), "w").close()
        self.assertEqual(
            self._run_in(tmp, lambda: sync.find_task_file("T20260101-000003")),
            "dev/TODO/T20260101-000003-slug.md",
        )

    def test_returns_none_when_absent(self):
        tmp = self._in_tmp_repo()
        self.assertIsNone(self._run_in(tmp, lambda: sync.find_task_file("T20260101-999999")))

    def test_returns_none_for_empty_id(self):
        self.assertIsNone(sync.find_task_file(""))


class ReconcileIssueStateTests(unittest.TestCase):
    """reconcile_issue_state enforces GitHub issue open/closed from the file's
    folder — closes orphaned issues left by a failed move-sync."""

    def test_journal_open_issue_is_closed_completed(self):
        with patch.object(sync, "issue_is_open", return_value=True), \
             patch.object(sync, "close_issue") as close, \
             patch.object(sync, "reopen_issue") as reopen:
            act = sync.reconcile_issue_state({"issue": 42}, "JOURNAL")
        self.assertEqual(act, "closed-completed")
        close.assert_called_once()
        self.assertEqual(close.call_args.kwargs.get("reason"), "completed")
        reopen.assert_not_called()

    def test_parking_open_issue_is_parked_and_closed(self):
        with patch.object(sync, "issue_is_open", return_value=True), \
             patch.object(sync, "add_label") as add_label, \
             patch.object(sync, "close_issue") as close:
            act = sync.reconcile_issue_state({"issue": 42}, "PARKING")
        self.assertEqual(act, "closed-parked")
        add_label.assert_called_once_with(42, sync.PARKED_LABEL)
        self.assertEqual(close.call_args.kwargs.get("reason"), "not_planned")

    def test_todo_closed_issue_is_reopened(self):
        with patch.object(sync, "issue_is_open", return_value=False), \
             patch.object(sync, "remove_label") as remove_label, \
             patch.object(sync, "reopen_issue") as reopen, \
             patch.object(sync, "close_issue") as close:
            act = sync.reconcile_issue_state({"issue": 42}, "TODO")
        self.assertEqual(act, "reopened")
        remove_label.assert_called_once_with(42, sync.PARKED_LABEL)
        reopen.assert_called_once()
        close.assert_not_called()

    def test_journal_already_closed_is_noop(self):
        with patch.object(sync, "issue_is_open", return_value=False), \
             patch.object(sync, "close_issue") as close, \
             patch.object(sync, "reopen_issue") as reopen:
            act = sync.reconcile_issue_state({"issue": 42}, "JOURNAL")
        self.assertIsNone(act)
        close.assert_not_called()
        reopen.assert_not_called()

    def test_todo_open_issue_is_noop(self):
        with patch.object(sync, "issue_is_open", return_value=True), \
             patch.object(sync, "reopen_issue") as reopen, \
             patch.object(sync, "close_issue") as close:
            act = sync.reconcile_issue_state({"issue": 42}, "TODO")
        self.assertIsNone(act)
        reopen.assert_not_called()
        close.assert_not_called()

    def test_no_issue_number_is_noop(self):
        with patch.object(sync, "issue_is_open") as is_open:
            self.assertIsNone(sync.reconcile_issue_state({}, "JOURNAL"))
        is_open.assert_not_called()


class EnsureOnProjectTests(unittest.TestCase):
    def test_missing_task_file_skips_reconcile_and_sync(self):
        issue_map = {
            "T20260514-123456": {
                "issue": 42,
                "path": "dev/TODO/T20260514-123456-example.md",
                "node_id": "NODE_1",
            }
        }
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "HAS_PAT", True), \
             patch.object(sync, "get_project_id", return_value="PID"), \
             patch.object(sync, "get_project_fields", return_value={"Status": {"id": "fld_status", "options": {}}}), \
             patch.object(sync, "find_task_file", return_value=None), \
             patch.object(sync, "reconcile_issue_state") as reconcile_issue_state, \
             patch.object(sync, "add_to_project", return_value="ITEM_1"), \
             patch.object(sync, "sync_fields") as sync_fields:
            sync.ensure_on_project(issue_map)

        reconcile_issue_state.assert_not_called()
        sync_fields.assert_not_called()


class ClearFieldTests(unittest.TestCase):
    """clear_field issues the clearProjectV2ItemFieldValue mutation."""

    def test_clear_field_issues_clear_mutation(self):
        ok = subprocess.CompletedProcess(args=["gh"], returncode=0, stdout="", stderr="")
        with patch.object(sync, "get_project_id", return_value="PID"), \
             patch.object(sync, "gh", return_value=ok) as mock_gh, \
             patch.object(sync, "DRY_RUN", False):
            result = sync.clear_field("item_1", "fld_iter")
        self.assertTrue(result)
        sent = mock_gh.call_args.args[0]
        query = " ".join(sent)
        self.assertIn("clearProjectV2ItemFieldValue", query)
        self.assertIn("fld_iter", query)

    def test_clear_field_noop_on_dry_run(self):
        with patch.object(sync, "DRY_RUN", True), \
             patch.object(sync, "gh") as mock_gh:
            self.assertFalse(sync.clear_field("item_1", "fld_iter"))
        mock_gh.assert_not_called()


class ParseIssueRefTests(unittest.TestCase):
    """_parse_issue_ref recovers (task_id, path) from an Issue's body permalink,
    falling back to the title — the join key build_index() derives the runtime
    mapping from (T20260610-023106 retired the committed sidecar map)."""

    def test_body_permalink_yields_id_and_path(self):
        body = ("**Task file**: [dev/TODO/T20260604-230790-x.md]"
                "(https://github.com/o/r/blob/main/dev/TODO/T20260604-230790-x.md)\n")
        self.assertEqual(
            sync._parse_issue_ref(body, "unrelated title"),
            ("T20260604-230790", "dev/TODO/T20260604-230790-x.md"),
        )

    def test_journal_permalink_with_date_prefix(self):
        body = ("**Task file**: [x](https://github.com/o/r/blob/main/"
                "dev/JOURNAL/2026-06-03-T20260602-261980-libicu.md)\n")
        tid, path = sync._parse_issue_ref(body, "")
        self.assertEqual(tid, "T20260602-261980")
        self.assertEqual(path, "dev/JOURNAL/2026-06-03-T20260602-261980-libicu.md")

    def test_title_fallback_when_body_has_no_id(self):
        # e.g. a manually-filed issue: no permalink, id only in the title
        self.assertEqual(
            sync._parse_issue_ref("free-form body", "T20260604-230790 — a title"),
            ("T20260604-230790", None),
        )

    def test_no_id_anywhere_returns_none_pair(self):
        self.assertEqual(sync._parse_issue_ref("plain body", "plain title"),
                         (None, None))

    def test_none_inputs(self):
        self.assertEqual(sync._parse_issue_ref(None, None), (None, None))


class BuildIndexTests(unittest.TestCase):
    """build_index derives the task→issue mapping from a single REST issue
    list — the map-free replacement for the committed sidecar."""

    @staticmethod
    def _gh_result(stdout, returncode=0):
        return subprocess.CompletedProcess(
            args=["gh"], returncode=returncode, stdout=stdout, stderr=""
        )

    @staticmethod
    def _issue(num, tid, path=None, title_only=False):
        body = "" if title_only else (
            f"**Task file**: [x](https://github.com/o/r/blob/main/{path})\n")
        title = f"{tid} — slug" if title_only else "title"
        return {"number": num, "id": f"I_n{num}", "title": title, "body": body}

    def test_indexes_issues_by_body_permalink(self):
        payload = json.dumps([
            self._issue(935, "T20260604-230790", "dev/TODO/T20260604-230790-x.md"),
            self._issue(910, "T20260602-261980",
                        "dev/JOURNAL/2026-06-03-T20260602-261980-y.md"),
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)), \
             patch.object(sync, "_attach_project_items"):
            index = sync.build_index()
        self.assertEqual(index["T20260604-230790"],
                         {"issue": 935, "node_id": "I_n935",
                          "path": "dev/TODO/T20260604-230790-x.md"})
        self.assertEqual(index["T20260602-261980"]["issue"], 910)

    def test_title_only_issue_indexed_without_path(self):
        payload = json.dumps([self._issue(7, "T20260101-000001", title_only=True)])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)), \
             patch.object(sync, "_attach_project_items"):
            index = sync.build_index()
        self.assertEqual(index["T20260101-000001"]["issue"], 7)
        self.assertNotIn("path", index["T20260101-000001"])

    def test_first_issue_per_task_wins_on_duplicates(self):
        payload = json.dumps([
            self._issue(100, "T20260101-000001", "dev/TODO/T20260101-000001-a.md"),
            self._issue(99, "T20260101-000001", "dev/TODO/T20260101-000001-a.md"),
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)), \
             patch.object(sync, "_attach_project_items"):
            index = sync.build_index()
        self.assertEqual(index["T20260101-000001"]["issue"], 100)

    def test_non_task_issues_skipped(self):
        payload = json.dumps([
            {"number": 5, "id": "I_n5", "title": "CI is flaky", "body": "no id here"},
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)), \
             patch.object(sync, "_attach_project_items"):
            self.assertEqual(sync.build_index(), {})

    def test_gh_failure_returns_empty_index(self):
        with patch.object(sync, "gh", return_value=self._gh_result("", returncode=1)), \
             patch.object(sync, "_attach_project_items") as attach:
            self.assertEqual(sync.build_index(), {})
        attach.assert_not_called()

    def test_malformed_json_returns_empty_index(self):
        with patch.object(sync, "gh", return_value=self._gh_result("not json")):
            self.assertEqual(sync.build_index(), {})

    def test_list_cap_logs_warning(self):
        payload = json.dumps([
            self._issue(i, f"T20260101-{i:06d}", f"dev/TODO/T20260101-{i:06d}-x.md")
            for i in range(1000)
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)), \
             patch.object(sync, "_attach_project_items"), \
             patch.object(sync, "log") as mock_log:
            sync.build_index()
        self.assertTrue(any("1000-issue list cap" in str(c.args[0])
                            for c in mock_log.call_args_list))


class BackfillIndexTests(unittest.TestCase):
    """backfill must skip any task already present in the derived index (never
    duplicate) and create issues only for genuinely unindexed files."""

    def _run_backfill_in_tmp(self, filename, issue_map):
        tmp = tempfile.mkdtemp()
        todo = Path(tmp) / "dev" / "TODO"
        todo.mkdir(parents=True)
        (todo / filename).write_text("---\nstatus: Open\n---\n\n# heading\n")
        prev = os.getcwd()
        try:
            os.chdir(tmp)
            with patch.object(sync, "create_issue", return_value=(777, "I_777")) as create_issue, \
                 patch.object(sync, "ensure_on_project") as ensure:
                sync.mode_backfill(issue_map)
        finally:
            os.chdir(prev)
        return issue_map, create_issue, ensure

    def test_backfill_skips_indexed_task(self):
        # The issue exists on GitHub: build_index() already put it in the map,
        # so backfill must not create a duplicate.
        pre = {"T20260604-230790": {"issue": 935, "node_id": "I_n935",
                                    "path": "dev/TODO/T20260604-230790-x.md"}}
        issue_map, create_issue, ensure = self._run_backfill_in_tmp(
            "T20260604-230790-x.md", pre)
        create_issue.assert_not_called()
        self.assertEqual(issue_map["T20260604-230790"]["issue"], 935)
        ensure.assert_called_once()

    def test_backfill_creates_when_not_indexed(self):
        issue_map, create_issue, ensure = self._run_backfill_in_tmp(
            "T20260604-230790-x.md", {})
        create_issue.assert_called_once()
        self.assertEqual(issue_map["T20260604-230790"]["issue"], 777)


class UpdateIssueBodyTests(unittest.TestCase):
    """T20260610-627431: the Issue body's 'Task file' link must track the file's
    current location. Without this a TODO→JOURNAL move leaves the body linking to
    the dead dev/TODO/ path (issue #937)."""

    def setUp(self):
        self.path = "dev/JOURNAL/2026-06-09-T20260604-803312-e2e-verify.md"
        self.expected = sync.issue_body(self.path, "JOURNAL")

    def _gh(self, args, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(args, returncode, stdout=stdout, stderr=stderr)

    def test_skips_edit_when_body_already_current(self):
        calls = []

        def fake_gh(args, check=True):
            calls.append(args)
            return self._gh(args, stdout=self.expected)

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=fake_gh):
            result = sync.update_issue_body(937, self.path, "JOURNAL")

        self.assertFalse(result)
        self.assertTrue(any(a[:2] == ["issue", "view"] for a in calls))
        self.assertFalse(any(a[:2] == ["issue", "edit"] for a in calls))

    def test_skips_edit_when_body_differs_only_by_trailing_newline(self):
        # GitHub may store the body with a trailing newline / CRLF; that must not
        # count as a difference and trigger a churn edit.
        def fake_gh(args, check=True):
            return self._gh(args, stdout="\r\n" + self.expected + "\n")

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=fake_gh):
            result = sync.update_issue_body(937, self.path, "JOURNAL")
        self.assertFalse(result)

    def test_edits_when_body_is_stale(self):
        calls = []

        def fake_gh(args, check=True):
            calls.append(args)
            if args[:2] == ["issue", "view"]:
                # stale: still links to the old dev/TODO/ path
                return self._gh(args, stdout="**Task file**: old dev/TODO/ link")
            return self._gh(args)

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", side_effect=fake_gh):
            result = sync.update_issue_body(937, self.path, "JOURNAL")

        self.assertTrue(result)
        edit_calls = [a for a in calls if a[:2] == ["issue", "edit"]]
        self.assertEqual(len(edit_calls), 1)
        # the rendered current-path body is passed to --body
        self.assertIn(self.expected, edit_calls[0])
        # and that body points at the JOURNAL path, not the old TODO path
        self.assertIn(self.path, self.expected)
        self.assertIn("Closed task", self.expected)

    def test_dry_run_is_noop(self):
        with patch.object(sync, "DRY_RUN", True), \
             patch.object(sync, "gh") as g:
            self.assertFalse(sync.update_issue_body(937, self.path, "JOURNAL"))
            g.assert_not_called()

    def test_invalid_issue_number_is_noop(self):
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh") as g:
            self.assertFalse(sync.update_issue_body(-1, self.path, "JOURNAL"))
            self.assertFalse(sync.update_issue_body(None, self.path, "JOURNAL"))
            self.assertFalse(sync.update_issue_body(937, "", "JOURNAL"))
            g.assert_not_called()


class ModeSyncBodyOnMoveTests(unittest.TestCase):
    """A rename must re-point the Issue body at the new path (issue #937)."""

    @staticmethod
    def _diff(stdout):
        return subprocess.CompletedProcess(
            args=["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
            returncode=0, stdout=stdout, stderr="",
        )

    def test_rename_todo_to_journal_updates_body_and_closes_completed(self):
        old = "dev/TODO/T20260604-803312-e2e-verify.md"
        new = "dev/JOURNAL/2026-06-09-T20260604-803312-e2e-verify.md"
        entry = {"issue": 937, "path": old}
        issue_map = {"T20260604-803312": entry}

        with patch.dict(os.environ, {"GITHUB_SHA": "abcdef12"}, clear=False), \
             patch.object(sync.subprocess, "run", return_value=self._diff(f"R100\t{old}\t{new}\n")), \
             patch.object(sync, "update_issue_body") as upd, \
             patch.object(sync, "_resync_fields_for", return_value=0), \
             patch.object(sync, "close_issue") as close:
            sync.mode_sync(issue_map)

        upd.assert_called_once_with(937, new, "JOURNAL")
        close.assert_called_once()
        self.assertEqual(close.call_args.kwargs.get("reason"), "completed")
        self.assertEqual(issue_map["T20260604-803312"]["path"], new)

    def test_same_dir_slug_rename_updates_body(self):
        old = "dev/TODO/T20260604-803312-old-slug.md"
        new = "dev/TODO/T20260604-803312-new-slug.md"
        entry = {"issue": 937, "path": old}
        issue_map = {"T20260604-803312": entry}

        with patch.object(sync.subprocess, "run", return_value=self._diff(f"R100\t{old}\t{new}\n")), \
             patch.object(sync, "update_issue_body") as upd, \
             patch.object(sync, "_resync_fields_for", return_value=0):
            sync.mode_sync(issue_map)

        upd.assert_called_once_with(937, new, "TODO")


class StaleLinkRepairTests(unittest.TestCase):
    """The #124/#937 bug class: a task file moved TODO→JOURNAL leaves the Issue
    body's permalink pointing at the dead dev/TODO/ path. The reconcile /
    ensure_on_project self-heal must repoint it from the file's CURRENT
    location. This exercises that repair path end-to-end (mocked gh/fs)."""

    def test_reconcile_repairs_moved_file_body(self):
        # Index entry's stored path is STALE (file has moved to dev/JOURNAL/);
        # the live file is discovered by find_task_file at the JOURNAL location.
        stale = "dev/TODO/T20260514-123456-example.md"
        moved = "dev/JOURNAL/2026-06-09-T20260514-123456-example.md"
        entry = {"issue": 42, "path": stale, "node_id": "NODE_1"}
        issue_map = {"T20260514-123456": entry}

        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "HAS_PAT", True), \
             patch.object(sync, "get_project_id", return_value="PID"), \
             patch.object(sync, "get_project_fields",
                          return_value={"Status": {"id": "fld_status", "options": {}}}), \
             patch.object(sync, "find_task_file", return_value=moved), \
             patch.object(sync, "reconcile_issue_state", return_value="closed-completed") as reconcile, \
             patch.object(sync, "update_issue_body", return_value=True) as upd_body, \
             patch.object(sync, "add_to_project", return_value="ITEM_1"), \
             patch.object(sync, "sync_fields", return_value=0):
            sync.ensure_on_project(issue_map)

        # The stale TODO path is self-healed to the discovered JOURNAL path.
        self.assertEqual(entry["path"], moved)
        # The body permalink is repointed at the CURRENT (JOURNAL) location —
        # this is the actual stale-link repair, and it would fail if the
        # update_issue_body wiring in ensure_on_project were removed.
        upd_body.assert_called_once_with(42, moved, "JOURNAL")
        # A JOURNAL-but-(still-)open issue is reconciled (closed) as well.
        reconcile.assert_called_once_with(entry, "JOURNAL")


class ExtractIpmDateTests(unittest.TestCase):
    """T20260608-264027: IPM_FILE_RE must match a real ipm-weekly.md and must
    NOT match a task journal whose slug happens to end the same way (the
    glob collision _ipm/current.sh already guards against)."""

    def test_matches_real_ipm_file(self):
        self.assertEqual(
            sync.extract_ipm_date("dev/JOURNAL/2026-06-29-ipm-weekly.md"),
            "2026-06-29")

    def test_does_not_match_task_journal_with_similar_slug(self):
        # T20260513-359694's actual filename: a task about renaming
        # "weekly-focus" to "ipm-weekly", not an IPM file itself.
        self.assertIsNone(sync.extract_ipm_date(
            "dev/JOURNAL/2026-06-27-T20260513-359694-rename-legacy-weekly-focus-to-ipm-weekly.md"))

    def test_no_match_returns_none(self):
        self.assertIsNone(sync.extract_ipm_date("dev/TODO/T20260101-000001-x.md"))


class IsIpmStagingStubTests(unittest.TestCase):
    def test_staging_stub_detected(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write("# Weekly Focus: 2026-07-06\n\n**Status**: Pre-IPM staging\n\n## Candidates\n")
            path = f.name
        try:
            self.assertTrue(sync.is_ipm_staging_stub(path))
        finally:
            os.unlink(path)

    def test_committed_ipm_is_not_a_stub(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write("# Weekly Focus: 2026-06-29\n\n**Scheduled**: 2026-06-29\n\n## Carry-over\n")
            path = f.name
        try:
            self.assertFalse(sync.is_ipm_staging_stub(path))
        finally:
            os.unlink(path)

    def test_missing_file_returns_false(self):
        self.assertFalse(sync.is_ipm_staging_stub("/no/such/file.md"))


class IpmIssueBodyTests(unittest.TestCase):
    def test_renders_permalink_and_marker(self):
        body = sync.ipm_issue_body("dev/JOURNAL/2026-06-29-ipm-weekly.md", "2026-06-29")
        self.assertIn(
            "https://github.com/your-org/ccxp-skills/blob/main/"
            "dev/JOURNAL/2026-06-29-ipm-weekly.md", body)
        self.assertIn("<!-- ipm:2026-06-29 -->", body)


class BuildIpmIndexTests(unittest.TestCase):
    @staticmethod
    def _gh_result(stdout, returncode=0):
        return subprocess.CompletedProcess(
            args=["gh"], returncode=returncode, stdout=stdout, stderr="")

    def test_indexes_issues_by_marker(self):
        payload = json.dumps([
            {"number": 55, "id": "I_n55", "title": "Weekly Focus: 2026-06-29",
             "body": sync.ipm_issue_body("dev/JOURNAL/2026-06-29-ipm-weekly.md", "2026-06-29")},
            {"number": 5, "id": "I_n5", "title": "CI is flaky", "body": "no marker here"},
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)):
            index = sync.build_ipm_index()
        self.assertEqual(index, {"2026-06-29": {"issue": 55, "node_id": "I_n55"}})

    def test_first_issue_per_date_wins_on_duplicates(self):
        payload = json.dumps([
            {"number": 100, "id": "I_100", "title": "x",
             "body": "<!-- ipm:2026-06-29 -->"},
            {"number": 101, "id": "I_101", "title": "y",
             "body": "<!-- ipm:2026-06-29 -->"},
        ])
        with patch.object(sync, "gh", return_value=self._gh_result(payload)):
            index = sync.build_ipm_index()
        self.assertEqual(index["2026-06-29"]["issue"], 100)

    def test_gh_failure_returns_empty_index(self):
        with patch.object(sync, "gh", return_value=self._gh_result("", returncode=1)):
            self.assertEqual(sync.build_ipm_index(), {})

    def test_malformed_json_returns_empty_index(self):
        with patch.object(sync, "gh", return_value=self._gh_result("not json")):
            self.assertEqual(sync.build_ipm_index(), {})


class CreateIpmIssueTests(unittest.TestCase):
    def test_dry_run_returns_placeholder(self):
        tmp = tempfile.mkdtemp()
        path = Path(tmp) / "2026-06-29-ipm-weekly.md"
        path.write_text("# Weekly Focus: 2026-06-29\n")
        with patch.object(sync, "DRY_RUN", True):
            num, node_id = sync.create_ipm_issue("2026-06-29", str(path))
        self.assertEqual((num, node_id), (-1, None))

    def test_success_parses_number_and_node_id(self):
        tmp = tempfile.mkdtemp()
        path = Path(tmp) / "2026-06-29-ipm-weekly.md"
        path.write_text("# Weekly Focus: 2026-06-29\n")
        completed = subprocess.CompletedProcess(
            args=["gh"], returncode=0,
            stdout=json.dumps({"number": 200, "node_id": "I_200"}), stderr="")
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "gh", return_value=completed) as gh_mock:
            num, node_id = sync.create_ipm_issue("2026-06-29", str(path))
        self.assertEqual((num, node_id), (200, "I_200"))
        body_arg = next(a for a in gh_mock.call_args[0][0] if a.startswith("body="))
        self.assertIn("<!-- ipm:2026-06-29 -->", body_arg)


class ModeBackfillIpmTests(unittest.TestCase):
    """mode_backfill's IPM scan: backfill committed JOURNAL ipm-weekly.md
    files not yet in ipm_map; skip staging stubs and already-indexed dates."""

    def _run_in_tmp(self, files, ipm_map):
        tmp = tempfile.mkdtemp()
        journal = Path(tmp) / "dev" / "JOURNAL"
        journal.mkdir(parents=True)
        for name, content in files.items():
            (journal / name).write_text(content)
        prev = os.getcwd()
        try:
            os.chdir(tmp)
            with patch.object(sync, "create_issue") as create_issue, \
                 patch.object(sync, "ensure_on_project"), \
                 patch.object(sync, "create_ipm_issue", return_value=(321, "I_321")) as create_ipm, \
                 patch.object(sync, "ensure_ipm_on_project") as ensure_ipm:
                sync.mode_backfill({}, ipm_map)
        finally:
            os.chdir(prev)
        return ipm_map, create_issue, create_ipm, ensure_ipm

    def test_backfills_committed_ipm_not_indexed(self):
        ipm_map, _, create_ipm, ensure_ipm = self._run_in_tmp(
            {"2026-06-29-ipm-weekly.md": "# Weekly Focus: 2026-06-29\n\n**Scheduled**: 2026-06-29\n"},
            {})
        create_ipm.assert_called_once_with("2026-06-29", "dev/JOURNAL/2026-06-29-ipm-weekly.md")
        self.assertEqual(ipm_map["2026-06-29"]["issue"], 321)
        ensure_ipm.assert_called_once_with(ipm_map)

    def test_skips_staging_stub(self):
        ipm_map, _, create_ipm, _ = self._run_in_tmp(
            {"2026-07-06-ipm-weekly.md": "# Weekly Focus: 2026-07-06\n\n**Status**: Pre-IPM staging\n"},
            {})
        create_ipm.assert_not_called()
        self.assertEqual(ipm_map, {})

    def test_skips_already_indexed_date(self):
        pre = {"2026-06-29": {"issue": 55, "node_id": "I_55"}}
        ipm_map, _, create_ipm, _ = self._run_in_tmp(
            {"2026-06-29-ipm-weekly.md": "# Weekly Focus: 2026-06-29\n"}, pre)
        create_ipm.assert_not_called()
        self.assertEqual(ipm_map["2026-06-29"]["issue"], 55)

    def test_ipm_map_defaults_to_empty_when_omitted(self):
        # mode_backfill(issue_map) with no ipm_map arg must not raise.
        tmp = tempfile.mkdtemp()
        prev = os.getcwd()
        try:
            os.chdir(tmp)
            with patch.object(sync, "ensure_on_project"), \
                 patch.object(sync, "ensure_ipm_on_project") as ensure_ipm:
                sync.mode_backfill({})
            ensure_ipm.assert_called_once_with({})
        finally:
            os.chdir(prev)


class SyncIpmLineTests(unittest.TestCase):
    """_sync_ipm_line — the per-diff-line IPM handler mode_sync() dispatches
    to before its task-id logic, so an A/M on an ipm-weekly.md never falls
    into the task path (which would silently no-op on a None tid)."""

    def test_staging_stub_add_is_noop(self):
        tmp = tempfile.mkdtemp()
        path = Path(tmp) / "2026-07-06-ipm-weekly.md"
        path.write_text("**Status**: Pre-IPM staging\n")
        ipm_map = {}
        with patch.object(sync, "create_ipm_issue") as create_ipm:
            actions, updates = sync._sync_ipm_line(
                "A", str(path), str(path), "2026-07-06", ipm_map, {})
        create_ipm.assert_not_called()
        self.assertEqual((actions, updates), (0, 0))
        self.assertEqual(ipm_map, {})

    def test_delete_is_noop(self):
        ipm_map = {"2026-06-29": {"issue": 55}}
        with patch.object(sync, "create_ipm_issue") as create_ipm:
            actions, updates = sync._sync_ipm_line(
                "D", "dev/JOURNAL/2026-06-29-ipm-weekly.md", None, "2026-06-29", ipm_map, {})
        create_ipm.assert_not_called()
        self.assertEqual((actions, updates), (0, 0))

    def test_new_committed_ipm_creates_issue_and_syncs_iteration(self):
        tmp = tempfile.mkdtemp()
        path = Path(tmp) / "2026-06-29-ipm-weekly.md"
        path.write_text("# Weekly Focus: 2026-06-29\n\n**Scheduled**: 2026-06-29\n")
        ipm_map = {}
        fields = {"Iteration": {"id": "fld_it",
                                 "iterations": [{"id": "it_13", "startDate": "2026-06-29", "duration": 7}]}}
        with patch.object(sync, "create_ipm_issue", return_value=(60, "I_60")) as create_ipm, \
             patch.object(sync, "add_to_project", return_value="ITEM_60"), \
             patch.object(sync, "update_iteration", return_value=True) as upd_it:
            actions, updates = sync._sync_ipm_line(
                "M", str(path), str(path), "2026-06-29", ipm_map, fields)
        create_ipm.assert_called_once_with("2026-06-29", str(path))
        self.assertEqual(ipm_map["2026-06-29"]["issue"], 60)
        self.assertEqual((actions, updates), (1, 1))
        upd_it.assert_called_once_with("ITEM_60", "fld_it", "it_13")

    def test_existing_ipm_resyncs_without_recreating(self):
        ipm_map = {"2026-06-29": {"issue": 55, "node_id": "I_55", "project_item_id": "ITEM_55"}}
        fields = {"Iteration": {"id": "fld_it",
                                 "iterations": [{"id": "it_13", "startDate": "2026-06-29", "duration": 7}]}}
        with patch.object(sync, "create_ipm_issue") as create_ipm, \
             patch.object(sync, "is_ipm_staging_stub", return_value=False), \
             patch.object(sync, "update_iteration", return_value=True) as upd_it:
            actions, updates = sync._sync_ipm_line(
                "M", "dev/JOURNAL/2026-06-29-ipm-weekly.md",
                "dev/JOURNAL/2026-06-29-ipm-weekly.md", "2026-06-29", ipm_map, fields)
        create_ipm.assert_not_called()
        self.assertEqual((actions, updates), (0, 1))
        upd_it.assert_called_once_with("ITEM_55", "fld_it", "it_13")


class SyncIpmFieldsTests(unittest.TestCase):
    def test_sets_iteration_when_matched(self):
        fields = {"Iteration": {"id": "fld_it",
                                 "iterations": [{"id": "it_13", "startDate": "2026-06-29", "duration": 7}]}}
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "update_iteration", return_value=True) as upd_it:
            self.assertEqual(sync.sync_ipm_fields("ITEM_1", "2026-06-29", fields), 1)
        upd_it.assert_called_once_with("ITEM_1", "fld_it", "it_13")

    def test_no_iteration_field_is_noop(self):
        with patch.object(sync, "DRY_RUN", False):
            self.assertEqual(sync.sync_ipm_fields("ITEM_1", "2026-06-29", {}), 0)

    def test_dry_run_is_noop(self):
        with patch.object(sync, "DRY_RUN", True):
            self.assertEqual(sync.sync_ipm_fields("ITEM_1", "2026-06-29", {"Iteration": {}}), 0)

    def test_no_item_id_is_noop(self):
        with patch.object(sync, "DRY_RUN", False):
            self.assertEqual(sync.sync_ipm_fields(None, "2026-06-29", {"Iteration": {}}), 0)

    def test_unmatched_date_is_noop(self):
        fields = {"Iteration": {"id": "fld_it",
                                 "iterations": [{"id": "it_13", "startDate": "2026-06-29", "duration": 7}]}}
        with patch.object(sync, "DRY_RUN", False):
            self.assertEqual(sync.sync_ipm_fields("ITEM_1", "2099-01-01", fields), 0)


class EnsureIpmOnProjectTests(unittest.TestCase):
    def test_dry_run_skips(self):
        with patch.object(sync, "DRY_RUN", True), \
             patch.object(sync, "get_project_id") as gpid:
            sync.ensure_ipm_on_project({"2026-06-29": {"issue": 55}})
        gpid.assert_not_called()

    def test_no_pat_skips(self):
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "HAS_PAT", False), \
             patch.object(sync, "get_project_id") as gpid:
            sync.ensure_ipm_on_project({"2026-06-29": {"issue": 55}})
        gpid.assert_not_called()

    def test_adds_to_project_and_syncs_iteration(self):
        ipm_map = {"2026-06-29": {"issue": 55, "node_id": "I_55"}}
        fields = {"Iteration": {"id": "fld_it",
                                 "iterations": [{"id": "it_13", "startDate": "2026-06-29", "duration": 7}]}}
        with patch.object(sync, "DRY_RUN", False), \
             patch.object(sync, "HAS_PAT", True), \
             patch.object(sync, "get_project_id", return_value="PID"), \
             patch.object(sync, "get_project_fields", return_value=fields), \
             patch.object(sync, "add_to_project", return_value="ITEM_55") as add_proj, \
             patch.object(sync, "update_iteration", return_value=True) as upd_it:
            sync.ensure_ipm_on_project(ipm_map)
        add_proj.assert_called_once_with("I_55")
        self.assertEqual(ipm_map["2026-06-29"]["project_item_id"], "ITEM_55")
        upd_it.assert_called_once_with("ITEM_55", "fld_it", "it_13")


class GetProjectIdTests(unittest.TestCase):
    """PROJECT_OWNER/PROJECT_NUMBER carry no baked-in your-org/1 default
    (T20260827-280088). They're read once at module-import time, so each case
    reloads the module fresh via _load() after setting/clearing env vars —
    the module-level `sync` instance imported at file load keeps the old
    values and is left untouched for every other test class in this file."""

    def test_no_pat_returns_none_regardless_of_owner_number(self):
        # Existing HAS_PAT gate — should already pass, confirms no regression.
        with patch.dict(os.environ,
                         {"PROJECT_OWNER": "", "PROJECT_NUMBER": "", "PROJECT_PAT": ""},
                         clear=False):
            mod = _load()
            self.assertFalse(mod.HAS_PAT)
            self.assertIsNone(mod.get_project_id())

    def test_pat_set_but_owner_number_unset_returns_none_without_default(self):
        # Regression test for the bug: PROJECT_OWNER/PROJECT_NUMBER must NOT
        # fall back to "your-org"/1 — and no GraphQL call is made when
        # they're unconfigured.
        with patch.dict(os.environ,
                         {"PROJECT_OWNER": "", "PROJECT_NUMBER": "", "PROJECT_PAT": "dummy-pat"},
                         clear=False):
            mod = _load()
            self.assertTrue(mod.HAS_PAT)
            self.assertEqual(mod.PROJECT_OWNER, "")
            self.assertEqual(mod.PROJECT_NUMBER, 0)
            with patch.object(mod, "gh") as mock_gh:
                result = mod.get_project_id()
            self.assertIsNone(result)
            mock_gh.assert_not_called()

    def test_configured_owner_number_are_used_verbatim(self):
        # With explicit config, the module must use those exact values — not
        # the old hardcoded your-org/1 defaults.
        with patch.dict(os.environ,
                         {"PROJECT_OWNER": "test-org", "PROJECT_NUMBER": "7",
                          "PROJECT_PAT": "dummy-pat"},
                         clear=False):
            mod = _load()
            self.assertEqual(mod.PROJECT_OWNER, "test-org")
            self.assertEqual(mod.PROJECT_NUMBER, 7)
            ok = subprocess.CompletedProcess(
                args=["gh"], returncode=0,
                stdout=json.dumps(
                    {"data": {"organization": {"projectV2": {"id": "PVT_test"}}}}),
                stderr="",
            )
            with patch.object(mod, "gh", return_value=ok) as mock_gh:
                result = mod.get_project_id()
            self.assertEqual(result, "PVT_test")
            sent_args = mock_gh.call_args.args[0]
            self.assertIn("login=test-org", sent_args)
            self.assertIn("number=7", sent_args)
            self.assertNotIn("login=your-org", sent_args)
            self.assertNotIn("number=1", sent_args)


if __name__ == "__main__":
    unittest.main(verbosity=2)
