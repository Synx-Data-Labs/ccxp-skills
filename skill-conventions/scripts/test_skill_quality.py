#!/usr/bin/env python3
"""Unit tests for skill_score.py, skill_eval.py (grader only) and
skill_feedback.py. Run: python3 skill-conventions/scripts/test_skill_quality.py
"""
import json
import os
import tempfile
import unittest
from pathlib import Path

import skill_eval
import skill_feedback
import skill_score

GOOD = """---
name: demo
description: Use when the user explicitly asks to demo the scorer on a fixture
disable-model-invocation: false
argument-hint: "[x]"
---

# Demo

## Argument

`x` — optional.

## Workflow

1. Run `scripts/run.sh`.
"""


def make_repo(root, skill_md=GOOD, name="demo", scripts=(), tests=()):
    root = Path(root)
    d = root / name
    (d / "scripts").mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(skill_md, encoding="utf-8")
    for s in scripts:
        (d / "scripts" / s).write_text("#!/bin/sh\n")
    (root / "tests").mkdir(exist_ok=True)
    for t, body in tests:
        (root / "tests" / t).write_text(body)
    return d


class ScoreTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def score(self, **kw):
        d = make_repo(self.root, **kw)
        return skill_score.score_skill(d, self.root)

    def test_good_skill_is_deterministic_and_high(self):
        make_repo(self.root, scripts=["run.sh"],
                  tests=[("demo.bats", "run bash demo/scripts/run.sh")])
        a = skill_score.score_skill(self.root / "demo", self.root)
        b = skill_score.score_skill(self.root / "demo", self.root)
        self.assertEqual(a, b)
        self.assertEqual(a["score"], 100)

    def test_invalid_yaml_frontmatter_zeroes_metadata(self):
        bad = GOOD.replace("on a fixture", "on a key: value fixture")
        r = self.score(skill_md=bad)
        self.assertEqual(r["checks"]["frontmatter"]["points"], 0)
        self.assertEqual(r["checks"]["trigger"]["points"], 0)

    def test_what_description_loses_trigger_points(self):
        r = self.score(skill_md=GOOD.replace(
            "Use when the user explicitly asks to demo", "Demonstrates the static"))
        self.assertEqual(r["checks"]["trigger"]["points"], 5)

    def test_size_scales_to_zero(self):
        big = GOOD + ("- filler line of words\n" * 2000)
        r = self.score(skill_md=big)
        self.assertEqual(r["checks"]["size"]["points"], 0)

    def test_broken_in_repo_ref_but_consumer_paths_ignored(self):
        md = GOOD + "\nSee `scripts/missing.sh`, `dev/ROADMAP.md`, " \
                    "`.claude/state/x.json`, [x](../nope/SKILL.md).\n"
        r = self.score(skill_md=md, scripts=["run.sh"])
        self.assertIn("scripts/missing.sh", r["checks"]["refs"]["detail"])
        self.assertIn("../nope/SKILL.md", r["checks"]["refs"]["detail"])
        self.assertNotIn("ROADMAP", r["checks"]["refs"]["detail"])
        self.assertEqual(r["checks"]["refs"]["points"], 5)

    def test_task_id_noise_penalized_past_two(self):
        md = GOOD + "\n" + " ".join(f"T20260101-00000{i}" for i in range(6))
        r = self.score(skill_md=md)
        self.assertEqual(r["checks"]["changelog_noise"]["points"], 6)

    def test_untested_script_detected(self):
        r = self.score(scripts=["run.sh", "other.sh"],
                       tests=[("demo.bats", "run.sh")])
        self.assertIn("other.sh", r["checks"]["script_tests"]["detail"])

    def test_baseline_ratchet(self):
        results = [{"skill": "a", "score": 80, "checks": {}},
                   {"skill": "b", "score": 65, "checks": {}}]
        self.assertEqual(
            skill_score.check_baseline(results, {"a": 80, "b": 60}), [])
        self.assertEqual(len(skill_score.check_baseline(results, {"a": 81})),
                         2)  # a regressed; b is new and under the floor

    def test_maturity_ladder(self):
        d = make_repo(self.root)
        self.assertEqual(skill_score.maturity(d, self.root, 50), "L0 Draft")
        self.assertEqual(skill_score.maturity(d, self.root, 90), "L1 Novice")
        (d / "evals").mkdir()
        (d / "evals" / "evals.json").write_text(json.dumps({"evals": [
            {"id": i, "assertions": [{"type": "x"}]} for i in "abc"]}))
        self.assertEqual(skill_score.maturity(d, self.root, 90),
                         "L2 Apprentice")
        q = self.root / "dev" / "quality"
        q.mkdir(parents=True)
        runs = "".join(json.dumps({"skill": "demo", "pass_rate": 1.0}) + "\n"
                       for _ in range(3))
        (q / "skill-evals.jsonl").write_text(runs)
        self.assertEqual(skill_score.maturity(d, self.root, 90), "L4 Master")
        (q / "skill-feedback.jsonl").write_text(json.dumps(
            {"skill": "demo", "status": "open"}) + "\n")
        self.assertEqual(skill_score.maturity(d, self.root, 90),
                         "L3 Practitioner")


class RepoFrontmatterTest(unittest.TestCase):
    """Regression coverage for the 2026-09-28 skill-review finding: an
    unquoted ': ' inside a plain-scalar `description:` value is invalid
    YAML (it reads as a nested mapping key), so `yaml.safe_load` raises and
    skill_score.split_frontmatter() silently returns fm=None — the skill's
    trigger may then never load. This walks every real SKILL.md in the repo
    (not a synthetic fixture) so a future skill with the same mistake fails
    here before it ships. Failed on migrate-task/SKILL.md and
    statusline-setup/SKILL.md prior to T20260928-101526's frontmatter fix.
    """

    def test_every_skill_frontmatter_is_valid_yaml(self):
        repo = Path(__file__).resolve().parents[2]
        bad = []
        for skill_dir in skill_score.iter_skills(repo):
            text = (skill_dir / "SKILL.md").read_text(encoding="utf-8")
            fm, _ = skill_score.split_frontmatter(text)
            if fm is None:
                bad.append(skill_dir.name)
        self.assertEqual(bad, [], f"invalid/missing YAML frontmatter in: {bad}")


TRANSCRIPT = [
    json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Skill",
         "input": {"skill": "ccxp-skills:todo"}}]}}),
    json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Bash",
         "input": {"command": "bash todo/scripts/todo-next.sh"}}]}}),
    json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t9", "name": "Bash",
         "input": {"command": "bash eta/scripts/eta.sh"}}]}}),
    json.dumps({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t9", "is_error": True,
         "content": "No such file or directory"}]}}),
    "not json",
    json.dumps({"type": "result", "result": "Next: T20260101-000001"}),
]


class GraderTest(unittest.TestCase):
    def setUp(self):
        self.run = skill_eval.parse_transcript(TRANSCRIPT)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.wd = Path(self._tmp.name)
        (self.wd / "q.md").write_text("1. T20260101-000001\n")

    def ok(self, a):
        return skill_eval.check(a, self.run, self.wd)[0]

    def test_skill_assertions_handle_plugin_namespace(self):
        self.assertTrue(self.ok({"type": "skill_invoked", "skill": "todo"}))
        self.assertFalse(self.ok({"type": "skill_invoked", "skill": "do"}))
        self.assertTrue(self.ok({"type": "skill_not_invoked",
                                 "skill": "drive"}))

    def test_slash_prompt_counts_as_invocation(self):
        empty = skill_eval.parse_transcript([])
        a = {"type": "skill_invoked", "skill": "eta"}
        self.assertTrue(skill_eval.check(a, empty, self.wd, "/eta T1")[0])
        self.assertFalse(skill_eval.check(a, empty, self.wd, "eta please")[0])

    def test_command_and_tool_assertions(self):
        self.assertTrue(self.ok({"type": "command_ran",
                                 "pattern": r"todo-next\.sh"}))
        self.assertTrue(self.ok({"type": "command_not_ran",
                                 "pattern": "gh pr merge"}))
        self.assertTrue(self.ok({"type": "tool_not_called", "tool": "Edit"}))

    def test_command_succeeded_catches_errored_calls(self):
        self.assertTrue(self.ok({"type": "command_succeeded",
                                 "pattern": r"todo-next\.sh"}))
        self.assertFalse(self.ok({"type": "command_succeeded",
                                  "pattern": r"eta\.sh"}))
        self.assertFalse(self.ok({"type": "command_succeeded",
                                  "pattern": "never-ran"}))

    def test_output_and_file_assertions(self):
        self.assertTrue(self.ok({"type": "output_matches",
                                 "pattern": r"T\d{8}-\d{6}"}))
        self.assertTrue(self.ok({"type": "file_matches", "path": "q.md",
                                 "pattern": "^1\\. T2026"}))
        self.assertTrue(self.ok({"type": "file_absent", "path": "nope"}))

    def test_grade_uses_viewer_field_names(self):
        case = {"assertions": [{"type": "file_exists", "path": "q.md"}]}
        [r] = skill_eval.grade(case, self.run, self.wd)
        self.assertEqual(set(r), {"text", "passed", "evidence"})

    def test_unknown_assertion_raises(self):
        with self.assertRaises(ValueError):
            self.ok({"type": "vibes"})


class FeedbackTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        os.environ["SKILL_FEEDBACK_LOG"] = str(Path(self._tmp.name) / "f.jsonl")
        self.addCleanup(os.environ.pop, "SKILL_FEEDBACK_LOG")

    def test_add_then_codify(self):
        skill_feedback.add("todo", "correction", "picked a blocked task")
        [item] = skill_feedback.load()
        self.assertEqual((item["id"], item["status"]), ("F0001", "open"))
        skill_feedback.close("F0001", "codified", eval_id="skips-blocked")
        [item] = skill_feedback.load()
        self.assertEqual(item["status"], "codified")
        self.assertEqual(item["eval_id"], "skips-blocked")

    def test_rejects_unknown_kind(self):
        with self.assertRaises(SystemExit):
            skill_feedback.add("todo", "meh", "x")


if __name__ == "__main__":
    unittest.main()
