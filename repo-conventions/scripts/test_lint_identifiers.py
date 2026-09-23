#!/usr/bin/env python3
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import lint_identifiers as li


class StructuralChecksTest(unittest.TestCase):
    def test_private_ipv4_10_range_detected(self):
        findings = li.find_structural("connect to 10.20.30.40 for the db\n")
        self.assertTrue(any(f.category == "private-ipv4" for f in findings))

    def test_private_ipv4_192_168_range_detected(self):
        findings = li.find_structural("host is 192.168.1.5\n")
        self.assertTrue(any(f.category == "private-ipv4" for f in findings))

    def test_public_ipv4_not_flagged(self):
        findings = li.find_structural("dns is 8.8.8.8\n")
        self.assertFalse(any(f.category == "private-ipv4" for f in findings))

    def test_github_credential_token_detected(self):
        findings = li.find_structural(
            "token: ghp_" + "a" * 36 + "\n"
        )
        self.assertTrue(any(f.category == "credential-token" for f in findings))

    def test_aws_credential_token_detected(self):
        findings = li.find_structural("key: AKIAABCDEFGHIJKLMNOP\n")
        self.assertTrue(any(f.category == "credential-token" for f in findings))

    def test_personal_home_path_flagged(self):
        findings = li.find_structural("see /home/jsmith/notes.txt\n")
        self.assertTrue(any(f.category == "personal-home-path" for f in findings))

    def test_generic_home_path_allowlisted(self):
        findings = li.find_structural("run from /home/ci/workspace\n")
        self.assertFalse(any(f.category == "personal-home-path" for f in findings))


class DenylistTest(unittest.TestCase):
    def test_env_var_unset_means_no_denylist(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(li.denylist_from_env(), [])

    def test_inline_env_var_parsed_with_suggestion(self):
        with patch.dict(os.environ, {"INTERNAL_IDENTIFIERS": "acme corp=your-org/hub-repo, jane doe"}, clear=True):
            terms = li.denylist_from_env()
            self.assertIn(("acme corp", "your-org/hub-repo"), terms)
            self.assertIn(("jane doe", None), terms)

    def test_file_env_var_read_when_set(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "identifiers.txt"
            p.write_text("acme corp=your-org/hub-repo\njane doe\n", encoding="utf-8")
            with patch.dict(os.environ, {"INTERNAL_IDENTIFIERS_FILE": str(p)}, clear=True):
                terms = li.denylist_from_env()
                self.assertIn(("acme corp", "your-org/hub-repo"), terms)
                self.assertIn(("jane doe", None), terms)

    def test_denylist_hit_reports_mapped_suggestion(self):
        denylist = [("acme corp", "your-org/hub-repo")]
        findings = li.find_denylist_hits("Filed under Acme Corp's internal tracker.\n", denylist)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].suggestion, "your-org/hub-repo")

    def test_denylist_hit_without_mapping_reported_bare(self):
        denylist = [("jane doe", None)]
        findings = li.find_denylist_hits("Reviewed by Jane Doe.\n", denylist)
        self.assertEqual(len(findings), 1)
        self.assertIsNone(findings[0].suggestion)

    def test_own_repo_slug_excluded_from_denylist_hits(self):
        denylist = [("synx-data-labs/ccxp-skills", None)]
        findings = li.find_denylist_hits(
            "see Synx-Data-Labs/ccxp-skills for source\n", denylist,
            own_slug="Synx-Data-Labs/ccxp-skills",
        )
        self.assertEqual(findings, [])

    def test_placeholder_vocabulary_never_trips_denylist(self):
        denylist = [("acme corp", "your-org/hub-repo")]
        findings = li.find_denylist_hits(
            "See your-org/hub-repo and /home/ci for details.\n", denylist,
        )
        self.assertEqual(findings, [])

    def test_internal_whitespace_difference_does_not_match(self):
        # Documented, current behavior: matching is exact-substring
        # (case-insensitive), so a denylist entry with different internal
        # whitespace than the text does NOT match. Not a bug fix -- a
        # regression guard for this known limitation.
        denylist = [("acme  corp", None)]  # two spaces
        findings = li.find_denylist_hits("Filed under Acme Corp's tracker.\n", denylist)
        self.assertEqual(findings, [])


class PrivateRepoLinkTest(unittest.TestCase):
    def test_configured_private_repo_link_flagged(self):
        private_repos = {"acme/internal-tools"}
        findings = li.find_private_repo_links(
            "See https://github.com/acme/internal-tools/pull/9\n", private_repos,
        )
        self.assertTrue(any(f.category == "private-repo-link" for f in findings))

    def test_unconfigured_link_not_flagged(self):
        findings = li.find_private_repo_links(
            "See https://github.com/some/public-repo\n", set(),
        )
        self.assertEqual(findings, [])

    def test_own_repo_link_excluded_even_if_misconfigured(self):
        private_repos = {"synx-data-labs/ccxp-skills"}
        findings = li.find_private_repo_links(
            "See https://github.com/Synx-Data-Labs/ccxp-skills/pull/50\n",
            private_repos, own_slug="Synx-Data-Labs/ccxp-skills",
        )
        self.assertEqual(findings, [])

    def test_mixed_case_link_still_matches_lowercase_private_repos_entry(self):
        private_repos = {"acme/internal-tools"}
        findings = li.find_private_repo_links(
            "See https://GitHub.com/ACME/Internal-Tools/pull/3\n", private_repos,
        )
        self.assertTrue(any(f.category == "private-repo-link" for f in findings))


class ApplyFixTest(unittest.TestCase):
    def test_mapped_denylist_hit_is_substituted(self):
        text = "Filed under Acme Corp's tracker.\n"
        findings = [li.Finding("denylist", "Acme Corp", "your-org/hub-repo")]
        new_text, unmapped = li.apply_fix(text, findings)
        self.assertIn("your-org/hub-repo", new_text)
        self.assertEqual(unmapped, [])

    def test_unmapped_hit_is_not_substituted_and_is_returned(self):
        text = "connect to 10.20.30.40\n"
        findings = [li.Finding("private-ipv4", "10.20.30.40", None)]
        new_text, unmapped = li.apply_fix(text, findings)
        self.assertEqual(new_text, text)
        self.assertEqual(len(unmapped), 1)

    def test_suggestion_containing_backslash_is_not_treated_as_backreference(self):
        # re.sub interprets backslash sequences (e.g. \1) in the REPLACEMENT
        # string unless the substitution avoids it -- a suggestion pasted
        # from a Windows-style path or containing a literal backslash must
        # not raise re.error or get silently mangled.
        text = "Filed under Acme Corp's tracker.\n"
        findings = [li.Finding("denylist", "Acme Corp", r"C:\new-path\team")]
        new_text, unmapped = li.apply_fix(text, findings)
        self.assertIn(r"C:\new-path\team", new_text)
        self.assertEqual(unmapped, [])


class IterScanFilesTest(unittest.TestCase):
    def test_scans_only_dev_todo_and_journal_md_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "dev" / "TODO").mkdir(parents=True)
            (root / "dev" / "JOURNAL").mkdir(parents=True)
            (root / "dev" / "TODO" / "T1-demo.md").write_text("todo\n", encoding="utf-8")
            (root / "dev" / "TODO" / "queue.md").write_text("queue\n", encoding="utf-8")
            (root / "dev" / "JOURNAL" / "2026-01-01-T1-demo.md").write_text("journal\n", encoding="utf-8")
            (root / "cloudflare").mkdir()
            (root / "cloudflare" / "notes.md").write_text("unrelated\n", encoding="utf-8")

            files = {f.name for f in li.iter_scan_files(root)}
            self.assertEqual(files, {"T1-demo.md", "2026-01-01-T1-demo.md"})

    def test_all_mode_does_not_scan_files_outside_dev_todo_journal(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "dev" / "TODO").mkdir(parents=True)
            (root / "dev" / "TODO" / "T1-demo.md").write_text("clean\n", encoding="utf-8")
            (root / "cloudflare").mkdir()
            (root / "cloudflare" / "notes.md").write_text("host 192.168.1.1\n", encoding="utf-8")

            with patch.dict(os.environ, {}, clear=True):
                rc = li.main(["--all", str(root)])
            self.assertEqual(rc, 0)  # the private-IP hit lives outside dev/TODO+JOURNAL


class MainCliTest(unittest.TestCase):
    def test_changed_mode_reports_failure_on_structural_hit(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "doc.md"
            f.write_text("host 192.168.1.1\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                rc = li.main(["--changed", str(f)])
            self.assertEqual(rc, 1)

    def test_changed_mode_clean_file_passes(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "doc.md"
            f.write_text("nothing sensitive here\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                rc = li.main(["--changed", str(f)])
            self.assertEqual(rc, 0)

    def test_fix_mode_substitutes_mapped_and_refuses_unmapped(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "doc.md"
            f.write_text("Acme Corp and Jane Doe worked on this.\n", encoding="utf-8")
            env = {"INTERNAL_IDENTIFIERS": "acme corp=your-org/hub-repo,jane doe"}
            with patch.dict(os.environ, env, clear=True):
                rc = li.main(["--changed", str(f), "--fix"])
            self.assertEqual(rc, 1)  # jane doe has no mapping -> refuse
            self.assertIn("your-org/hub-repo", f.read_text(encoding="utf-8"))

    def test_fix_mode_all_mapped_succeeds(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "doc.md"
            f.write_text("Acme Corp worked on this.\n", encoding="utf-8")
            env = {"INTERNAL_IDENTIFIERS": "acme corp=your-org/hub-repo"}
            with patch.dict(os.environ, env, clear=True):
                rc = li.main(["--changed", str(f), "--fix"])
            self.assertEqual(rc, 0)
            self.assertIn("your-org/hub-repo", f.read_text(encoding="utf-8"))

    def test_no_own_repo_exclusion_flag_disables_the_exclusion(self):
        # Regression for the /migrate-task integration bug found in
        # independent review of PR #104: main()'s own_slug is computed
        # from repo_path, which defaults to "." -- when invoked from
        # migrate.sh's cwd (the SOURCE repo being migrated OUT of), that
        # source repo's own slug is exactly what an operator would put in
        # INTERNAL_PRIVATE_REPOS, so without this flag the exclusion
        # silently defeats the check on the one case it exists to catch.
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "doc.md"
            f.write_text(
                "See https://github.com/acme/private-source-repo/pull/1\n",
                encoding="utf-8",
            )
            env = {"INTERNAL_PRIVATE_REPOS": "acme/private-source-repo"}
            with patch.dict(os.environ, env, clear=True), \
                 patch.object(li, "repo_slug", return_value="acme/private-source-repo"):
                # Without the flag: exclusion applies, hit is (wrongly, for
                # this call site) suppressed.
                rc_default = li.main(["--changed", str(f)])
                # With the flag: exclusion is disabled, the hit is caught.
                rc_disabled = li.main(["--changed", str(f), "--no-own-repo-exclusion"])
            self.assertEqual(rc_default, 0)
            self.assertEqual(rc_disabled, 1)


if __name__ == "__main__":
    unittest.main()
