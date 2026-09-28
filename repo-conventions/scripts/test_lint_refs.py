#!/usr/bin/env python3
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import lint_refs


def write_task(root, name="T20260611-000001-demo.md", body="", sub="TODO"):
    f = Path(root) / "dev" / sub / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(body, encoding="utf-8")
    return f


def fake_taskid_resolver(links):
    """links: {tid: markdown_link_or_None}"""
    def _resolve(tid):
        return links.get(tid)
    return _resolve


def fake_typed_resolver(results):
    """results: {number: (label, url)_or_None}"""
    def _resolve(number):
        return results.get(number)
    return _resolve


class ProcessTextTest(unittest.TestCase):
    def test_taskid_resolves_via_injected_resolver(self):
        text = "See T20260611-000001 for details.\n"
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)",
        })
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 1)
        self.assertEqual(bare, 0)
        self.assertIn("[T20260611-000001](https://github.com/o/r/issues/5)", new_text)

    def test_taskid_left_bare_when_unresolvable(self):
        text = "See T20260611-000001 for details.\n"
        resolve_taskid = fake_taskid_resolver({"T20260611-000001": None})
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 0)
        self.assertEqual(bare, 1)
        self.assertEqual(new_text, text)

    def test_typed_ref_pr_linkified(self):
        text = "Fixed in PR #250.\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 1)
        self.assertIn("[PR #250](https://github.com/o/r/pull/250)", new_text)

    def test_typed_ref_issue_linkified(self):
        text = "See issue #99 for context.\n"
        resolve_typed = fake_typed_resolver({"99": ("issue", "https://github.com/o/r/issues/99")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 1)
        self.assertIn("[issue #99](https://github.com/o/r/issues/99)", new_text)

    def test_typed_ref_type_is_corrected(self):
        # author mistyped "issue #250" but the GitHub API says it's a PR
        text = "See issue #250 for context.\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertIn("[PR #250](https://github.com/o/r/pull/250)", new_text)
        self.assertNotIn("issue #250", new_text)

    def test_pull_request_phrase_matches_and_normalizes_to_pr(self):
        text = "See pull request #12 for context.\n"
        resolve_typed = fake_typed_resolver({"12": ("PR", "https://github.com/o/r/pull/12")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 1)
        self.assertIn("[PR #12](https://github.com/o/r/pull/12)", new_text)

    def test_wiki_style_double_bracket_ref_is_not_corrupted(self):
        # this corpus also uses a [[T-id]] wiki-style cross-ref convention;
        # linkifying only the inner bare id produces malformed [[[id](url)]]
        text = "See [[T20260611-000001]] for background.\n"
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)",
        })
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_taskid_embedded_in_a_bare_filename_is_not_spliced(self):
        # a T-id that's a substring of a longer, unbacktick'd .md filename
        # must not get a markdown link spliced into the middle of the path
        text = "Merged into dev/JOURNAL/2026-06-09-T20260611-000001-some-slug.md already.\n"
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)",
        })
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    @patch.dict(os.environ, {"KNOWN_SIBLING_REPOS": "example-website.com"})
    def test_typed_ref_qualified_with_a_different_repo_is_left_bare(self):
        # "example-website.com PR #39" is a DIFFERENT repo's PR #39 — resolving it
        # against the current repo would link to the wrong PR entirely.
        # (example-website.com must be a configured KNOWN_SIBLING_REPOS entry for
        # this heuristic to fire at all — see KnownSiblingReposTest for that
        # config-driven contract on its own.)
        text = "Shipped as example-website.com PR #39 last week.\n"
        resolve_typed = fake_typed_resolver({"39": ("PR", "https://github.com/your-org/hub-repo/pull/39")})
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_typed_ref_qualified_with_current_repo_name_still_resolves(self):
        # mentioning the CURRENT repo's own name is not a foreign qualifier
        text = "Shipped as hub-repo PR #39 last week.\n"
        resolve_typed = fake_typed_resolver({"39": ("PR", "https://github.com/your-org/hub-repo/pull/39")})
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 1)
        self.assertIn("[PR #39](https://github.com/your-org/hub-repo/pull/39)", new_text)

    @patch.dict(os.environ, {"KNOWN_SIBLING_REPOS": "hub"})
    def test_typed_ref_qualified_with_overlapping_but_distinct_repo_name_is_left_bare(self):
        # "hub" is a substring of "hub-repo" (current) — the self-check must
        # not let that overlap mask a genuinely different repo mention.
        # ("hub" must itself be a configured KNOWN_SIBLING_REPOS entry for
        # the heuristic to fire — see KnownSiblingReposTest.)
        text = "See hub PR #82 for the underlying fix.\n"
        resolve_typed = fake_typed_resolver({"82": ("PR", "https://github.com/your-org/hub-repo/pull/82")})
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_typed_ref_with_no_repo_qualifier_unaffected_by_new_param(self):
        text = "Fixed by PR #250.\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 1)
        self.assertIn("[PR #250](https://github.com/o/r/pull/250)", new_text)

    def test_overlength_taskid_is_not_partially_matched(self):
        # a typo'd 7-digit suffix must not be corrupted by a 6-digit partial match
        text = "See T20260611-1234567 for the typo.\n"
        resolve_taskid = fake_taskid_resolver({"T20260611-123456": "[SHOULD-NOT-MATCH](x)"})
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_bare_hash_number_without_keyword_is_not_matched(self):
        # street address / ordinal false positives from the task's own Context section
        text = "Ste G2 #26880, and POC plan for #1 feature.\n"
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), fake_typed_resolver({"26880": ("issue", "x"), "1": ("issue", "x")}))
        self.assertEqual(fixed, 0)
        self.assertEqual(bare, 0)
        self.assertEqual(new_text, text)

    def test_ref_inside_inline_code_span_is_skipped(self):
        text = "Run `grep PR #250` in a shell.\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_ref_inside_fenced_code_block_is_skipped(self):
        text = "```\nPR #250 in a fence\n```\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_already_linked_taskid_is_skipped(self):
        text = "See [T20260611-000001](https://github.com/o/r/issues/5) for details.\n"
        resolve_taskid = fake_taskid_resolver({"T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)"})
        new_text, fixed, bare = lint_refs.process_text(text, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_already_linked_typed_ref_is_skipped(self):
        text = "See [PR #250](https://github.com/o/r/pull/250) for details.\n"
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        new_text, fixed, bare = lint_refs.process_text(text, fake_taskid_resolver({}), resolve_typed)
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)

    def test_idempotent_second_run_produces_no_further_changes(self):
        text = "Fixed in PR #250, tracked as T20260611-000001.\n"
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)",
        })
        resolve_typed = fake_typed_resolver({"250": ("PR", "https://github.com/o/r/pull/250")})
        first_text, first_fixed, _ = lint_refs.process_text(text, resolve_taskid, resolve_typed)
        self.assertEqual(first_fixed, 2)
        second_text, second_fixed, _ = lint_refs.process_text(first_text, resolve_taskid, resolve_typed)
        self.assertEqual(second_fixed, 0)
        self.assertEqual(second_text, first_text)


class LintFileTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_frontmatter_refs_are_not_linkified(self):
        body = (
            "---\n"
            "status: Open\n"
            "estimation: 1h\n"
            "related: T20260611-000001\n"
            "---\n\n"
            "# T20260611-000002: Demo\n\nSee T20260611-000001 too.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000001": "[T20260611-000001](https://github.com/o/r/issues/5)",
        })
        new_text, fixed, bare = lint_refs.lint_file(f, resolve_taskid, fake_typed_resolver({}))
        self.assertEqual(fixed, 1)
        self.assertIn("related: T20260611-000001\n", new_text)
        self.assertIn("[T20260611-000001](https://github.com/o/r/issues/5) too.", new_text)

    def test_typed_ref_left_bare_when_yaml_frontmatter_declares_other_target_repo(self):
        # target-repo: <other> means EVERY typed ref in this file belongs to
        # that repo, even with no textual qualifier on the ref's own line —
        # the same-line heuristic alone can't catch this (T20260616-130977
        # backfill review, round 2).
        body = (
            "---\n"
            "status: Done\n"
            "estimation: 2h\n"
            "target-repo: 'your-org/ccxp-skills'\n"
            "---\n\n"
            "# T20260611-000002: Demo\n\nToday PR #134 landed the fix.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_typed = fake_typed_resolver({"134": ("PR", "https://github.com/your-org/hub-repo/pull/134")})
        new_text, fixed, bare = lint_refs.lint_file(
            f, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 0)
        self.assertIn("Today PR #134 landed the fix.\n", new_text)

    def test_typed_ref_left_bare_when_legacy_body_target_repo_bullet_declares_other_repo(self):
        # older (pre-YAML-frontmatter) task files declare the target repo as
        # a body bullet instead of a frontmatter key.
        body = (
            "# T20260611-000002: Demo\n\n"
            "- **Target repo**: your-org/omnistrate-cli-tools\n\n"
            "## Closed\n\n"
            "PR #1 shipped it.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_typed = fake_typed_resolver({"1": ("PR", "https://github.com/your-org/hub-repo/pull/1")})
        new_text, fixed, bare = lint_refs.lint_file(
            f, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 0)

    def test_legacy_body_target_repo_bullet_strips_backtick_quoting(self):
        # several real legacy bullets wrap the value in backticks:
        # "- **Target repo**: `your-org/ccxp-skills` (primary...)"
        body = (
            "# T20260611-000002: Demo\n\n"
            "- **Target repo**: `your-org/ccxp-skills` (primary code change)\n\n"
            "## Closed\n\n"
            "PR #1 shipped it.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_typed = fake_typed_resolver({"1": ("PR", "https://github.com/your-org/hub-repo/pull/1")})
        new_text, fixed, bare = lint_refs.lint_file(
            f, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 0)

    def test_typed_ref_still_resolves_when_declared_target_repo_matches_current(self):
        body = (
            "---\n"
            "status: Done\n"
            "estimation: 2h\n"
            "target-repo: 'your-org/hub-repo'\n"
            "---\n\n"
            "# T20260611-000002: Demo\n\nToday PR #134 landed the fix.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_typed = fake_typed_resolver({"134": ("PR", "https://github.com/your-org/hub-repo/pull/134")})
        new_text, fixed, bare = lint_refs.lint_file(
            f, fake_taskid_resolver({}), resolve_typed, current_repo_name="hub-repo")
        self.assertEqual(fixed, 1)
        self.assertIn("[PR #134](https://github.com/your-org/hub-repo/pull/134)", new_text)

    def test_h1_self_reference_stays_bare_even_when_resolvable(self):
        # lint_tasks.py's H1_RE requires the H1 to start with a BARE T-id
        # matching the filename ('# T<id>: <title>') — linkifying it breaks
        # that structural check, so the file's own H1 self-reference must
        # never be linkified, regardless of whether it *could* resolve.
        body = (
            "---\n"
            "status: Open\n"
            "estimation: 1h\n"
            "---\n\n"
            "# T20260611-000002: Demo\n\nSee T20260611-000002 again in prose.\n"
        )
        f = write_task(self.root, name="T20260611-000002-demo.md", body=body)
        resolve_taskid = fake_taskid_resolver({
            "T20260611-000002": "[T20260611-000002](https://github.com/o/r/issues/9)",
        })
        new_text, fixed, bare = lint_refs.lint_file(f, resolve_taskid, fake_typed_resolver({}))
        self.assertTrue(new_text.splitlines()[5].startswith("# T20260611-000002:"))
        # the prose occurrence two lines later is still linkified normally
        self.assertIn("[T20260611-000002](https://github.com/o/r/issues/9) again in prose.", new_text)


class KnownSiblingReposTest(unittest.TestCase):
    """KNOWN_SIBLING_REPOS env var drives _foreign_repo_qualified() — no
    baked-in default (same os.environ.get pattern as LINT_REFS_GH,
    gh_argv()'s env-override seam)."""

    def setUp(self):
        self._saved = os.environ.pop("KNOWN_SIBLING_REPOS", None)
        self.addCleanup(self._restore)

    def _restore(self):
        if self._saved is None:
            os.environ.pop("KNOWN_SIBLING_REPOS", None)
        else:
            os.environ["KNOWN_SIBLING_REPOS"] = self._saved

    def test_unset_env_var_means_known_sibling_repos_is_empty(self):
        self.assertEqual(lint_refs.known_sibling_repos(), set())

    def test_unset_env_var_means_foreign_repo_detection_never_fires(self):
        # a line naming a real, well-known repo name is not flagged foreign
        # when KNOWN_SIBLING_REPOS is unset -- no baked-in default
        self.assertFalse(lint_refs._foreign_repo_qualified(
            "Shipped as hub-repo PR #39 last week.\n", "ccxp-skills"))
        self.assertFalse(lint_refs._foreign_repo_qualified(
            "See example-website.com PR #1 for background.\n", "ccxp-skills"))

    def test_env_var_set_only_configured_names_are_treated_as_foreign(self):
        os.environ["KNOWN_SIBLING_REPOS"] = "widget-repo,gadget-repo"
        # a configured sibling name IS flagged foreign
        self.assertTrue(lint_refs._foreign_repo_qualified(
            "See widget-repo PR #5 for background.\n", "current-repo"))
        # an old hardcoded name that's NOT in the configured list is no
        # longer treated as foreign now that the set is config-driven
        self.assertFalse(lint_refs._foreign_repo_qualified(
            "See hub-repo PR #5 for background.\n", "current-repo"))

    def test_whitespace_and_comma_parsing_for_a_multi_name_value(self):
        os.environ["KNOWN_SIBLING_REPOS"] = " widget-repo ,  gadget-repo\tthingy-repo ,,"
        self.assertEqual(
            lint_refs.known_sibling_repos(),
            {"widget-repo", "gadget-repo", "thingy-repo"})

    def test_end_to_end_typed_ref_left_bare_only_for_a_configured_name(self):
        os.environ["KNOWN_SIBLING_REPOS"] = "widget-repo"
        resolve_typed = fake_typed_resolver({"39": ("PR", "https://github.com/o/widget-repo/pull/39")})
        text = "Shipped as widget-repo PR #39 last week.\n"
        new_text, fixed, bare = lint_refs.process_text(
            text, fake_taskid_resolver({}), resolve_typed, current_repo_name="current-repo")
        self.assertEqual(fixed, 0)
        self.assertEqual(new_text, text)


class RepoSlugTest(unittest.TestCase):
    def test_repo_slug_strips_https_scheme_and_git_suffix(self):
        self.assertEqual(
            lint_refs.parse_repo_slug("https://github.com/your-org/ccxp-skills.git"),
            "your-org/ccxp-skills",
        )

    def test_repo_slug_handles_ssh_remote(self):
        self.assertEqual(
            lint_refs.parse_repo_slug("git@github.com:your-org/ccxp-skills.git"),
            "your-org/ccxp-skills",
        )


class IterRefFilesTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def test_iter_ref_files_covers_todo_and_journal_only(self):
        write_task(self.root, name="a.md", body="x", sub="TODO")
        write_task(self.root, name="b.md", body="x", sub="JOURNAL")
        write_task(self.root, name="c.md", body="x", sub="PARKING")
        write_task(self.root, name="queue.md", body="x", sub="TODO")
        found = {p.name for p in lint_refs.iter_ref_files(self.root)}
        self.assertEqual(found, {"a.md", "b.md"})


if __name__ == "__main__":
    unittest.main()
