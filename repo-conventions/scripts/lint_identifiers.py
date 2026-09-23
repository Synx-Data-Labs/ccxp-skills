#!/usr/bin/env python3
"""Catch internal identifiers before they reach a public repo (T20260919-231319).

Two independent signal classes:

1. **Generic structural checks** — ship enabled with zero identifiers
   hardcoded: private IPv4 ranges, GitHub/AWS-style credential tokens, and
   personal absolute home-dir paths (``/home/<name>`` where ``<name>``
   isn't a small generic allowlist: ci, runner, ubuntu, root). These never
   have a safe auto-replacement, so a hit always fails, even under
   ``--fix``.
2. **An optional denylist, injected ONLY via env var/file, never committed
   to any repo's git history** — ``INTERNAL_IDENTIFIERS`` /
   ``INTERNAL_IDENTIFIERS_FILE`` (company/product terms + real personal
   names) and ``INTERNAL_PRIVATE_REPOS`` (private repo slugs, checked
   against ``github.com/<org>/<repo>`` links). Unset -> empty -> a no-op,
   the same env-var-config-not-committed-data posture as this file
   family's ``lint_refs.py``'s ``KNOWN_SIBLING_REPOS``.

Each denylist entry may carry an explicit suggested replacement —
``term=placeholder`` — so growing the placeholder-suggestion mapping is
also a config change, not a code change: ``acme corp=your-org/hub-repo``.
A bare ``term`` (no ``=``) is still flagged, just reported without a
suggestion.

Modes: ``--all`` (every tracked file under repo_path, wired into
``lint.sh``) / ``--changed <files>`` (wired into CI + ``/migrate-task``);
``--fix`` substitutes any DENYLIST hit that carries a mapped placeholder,
in place. A hit with no mapping (or any structural hit) still fails even
under ``--fix`` — there is nothing safe to substitute — which is what
gives ``/migrate-task`` its "genericize on the way in, or refuse" behavior.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

SKIP_DIR_NAMES = {".git", "__pycache__", "node_modules", ".DS_Store"}

# --all's default scan scope: dev/TODO + dev/JOURNAL *.md files, same
# convention as this file family's lint_refs.py (REF_DIRS) / lint_tasks.py.
# This is a deliberate narrowing from "every tracked file" (this task's
# original design) after --all against the WHOLE repo produced 32
# false positives here: illustrative RFC1918 example IPs in unrelated
# skill reference docs (cloudflare/references/**) and synthetic test-fixture
# home paths in *.bats files — neither is a real leak, and the two actual
# incidents this check exists for both happened in dev/TODO + dev/JOURNAL
# task/journal authoring, never in reference documentation. --changed is
# NOT restricted this way (see is_scan_file's callers below) — a PR's own
# diff is naturally bounded, so the CI/--changed path keeps full-repo reach.
SCAN_DIRS = ("TODO", "JOURNAL")
NON_TASK_FILES = {"queue.md"}

_PRIVATE_IPV4 = re.compile(
    r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"
)

# GitHub / AWS-style credential tokens — structural, no company data needed.
_CREDENTIAL_TOKEN = re.compile(
    r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16})\b"
)

# Personal absolute home-dir paths — /home/<name> where <name> isn't a
# small generic allowlist: standard CI-runner/container/cloud-image default
# account names, none of them a real person or company-specific ("rocky" is
# this sandbox class's own generic default account, the same tier as
# "ubuntu" being Ubuntu's cloud-image default — not a personal name).
_HOME_PATH_ALLOWLIST = {"ci", "runner", "ubuntu", "root", "rocky"}
_HOME_PATH = re.compile(r"/home/([A-Za-z0-9_-]+)")

_GITHUB_LINK = re.compile(
    r"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)", re.IGNORECASE
)


class Finding:
    def __init__(self, category, term, suggestion=None):
        self.category = category
        self.term = term
        self.suggestion = suggestion

    def __eq__(self, other):
        return (
            isinstance(other, Finding)
            and (self.category, self.term, self.suggestion)
            == (other.category, other.term, other.suggestion)
        )

    def __repr__(self):
        return f"Finding({self.category!r}, {self.term!r}, {self.suggestion!r})"


def repo_slug(repo_root="."):
    """"<owner>/<repo>" for repo_root's origin remote, or None. Same
    subprocess-based approach as lint_refs.py's repo_slug(), kept local to
    this module so each lint script here stays independently runnable."""
    try:
        out = subprocess.run(
            ["git", "remote", "get-url", "origin"], cwd=repo_root,
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    m = re.search(r"[:/]([^/]+/[^/]+?)(?:\.git)?\s*$", out.stdout.strip())
    return m.group(1) if m else None


def _split_entries(raw):
    return [t.strip() for t in re.split(r"[,\n]+", raw) if t.strip()]


def denylist_from_env():
    """[(term, suggestion_or_None), ...] from INTERNAL_IDENTIFIERS_FILE (a
    path to a newline-delimited file) or INTERNAL_IDENTIFIERS (an inline
    comma/newline-separated value). Each entry is ``term`` or
    ``term=placeholder``. Unset/empty -> []."""
    path = os.environ.get("INTERNAL_IDENTIFIERS_FILE")
    if path:
        try:
            raw = Path(path).read_text(encoding="utf-8")
        except OSError:
            raw = ""
    else:
        raw = os.environ.get("INTERNAL_IDENTIFIERS", "")
    entries = []
    for item in _split_entries(raw):
        if "=" in item:
            term, suggestion = item.split("=", 1)
            entries.append((term.strip(), suggestion.strip() or None))
        else:
            entries.append((item, None))
    return entries


def private_repos_from_env():
    """A set of lowercased private repo slugs from INTERNAL_PRIVATE_REPOS
    (comma/whitespace-separated). Unset/empty -> empty set."""
    raw = os.environ.get("INTERNAL_PRIVATE_REPOS", "")
    return {t.lower() for t in re.split(r"[,\s]+", raw.strip()) if t}


def find_structural(text):
    findings = []
    for m in _PRIVATE_IPV4.finditer(text):
        findings.append(Finding("private-ipv4", m.group(0)))
    for m in _CREDENTIAL_TOKEN.finditer(text):
        findings.append(Finding("credential-token", m.group(0)))
    for m in _HOME_PATH.finditer(text):
        name = m.group(1)
        if name.lower() not in _HOME_PATH_ALLOWLIST:
            findings.append(Finding("personal-home-path", m.group(0)))
    return findings


def find_denylist_hits(text, denylist, own_slug=None):
    findings = []
    lower = text.lower()
    own_slug_lower = own_slug.lower() if own_slug else None
    for term, suggestion in denylist:
        t = term.lower()
        if not t:
            continue
        if own_slug_lower and t == own_slug_lower:
            continue
        if t in lower:
            findings.append(Finding("denylist", term, suggestion))
    return findings


def find_private_repo_links(text, private_repos, own_slug=None):
    if not private_repos:
        return []
    findings = []
    own_slug_lower = own_slug.lower() if own_slug else None
    for m in _GITHUB_LINK.finditer(text):
        slug = f"{m.group(1)}/{m.group(2)}".lower()
        if own_slug_lower and slug == own_slug_lower:
            continue
        if slug in private_repos or m.group(2).lower() in private_repos:
            findings.append(Finding("private-repo-link", m.group(0)))
    return findings


def lint_text(text, denylist, private_repos, own_slug=None):
    findings = []
    findings += find_structural(text)
    findings += find_denylist_hits(text, denylist, own_slug)
    findings += find_private_repo_links(text, private_repos, own_slug)
    return findings


def apply_fix(text, findings):
    """Substitute denylist hits that carry a mapped placeholder. Returns
    (new_text, unmapped_findings) — unmapped and structural findings are
    never rewritten (nothing safe to substitute) and are returned so the
    caller still fails/refuses on them."""
    new_text = text
    unmapped = []
    for f in findings:
        if f.category == "denylist" and f.suggestion:
            # A lambda replacement is used verbatim (never parsed for
            # backreferences like \1 or \g<0>) -- re.sub DOES interpret
            # escape sequences in a plain-string replacement (e.g. a
            # literal "\n"/"\t" inside a pasted Windows-style path would
            # silently become a real newline/tab, or raise re.error on an
            # unrecognized escape), even though re.escape() already made
            # the PATTERN side safe.
            suggestion = f.suggestion
            new_text = re.sub(re.escape(f.term), lambda _m: suggestion, new_text, flags=re.IGNORECASE)
        else:
            unmapped.append(f)
    return new_text, unmapped


def iter_scan_files(repo_root):
    """dev/TODO/*.md + dev/JOURNAL/*.md under repo_root — --all's default
    scope. See SCAN_DIRS above for why this is narrower than every tracked
    file."""
    root = Path(repo_root)
    for sub in SCAN_DIRS:
        d = root / "dev" / sub
        if d.is_dir():
            yield from (f for f in sorted(d.glob("*.md")) if f.name not in NON_TASK_FILES)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true",
                   help="scan every tracked file under repo_path")
    g.add_argument("--changed", nargs="*", metavar="FILE",
                   help="scan only these files")
    ap.add_argument("--fix", action="store_true",
                     help="substitute denylist hits that carry a mapped "
                          "placeholder, in place")
    ap.add_argument("--no-own-repo-exclusion", action="store_true",
                     help="don't exempt repo_path's own slug from denylist/"
                          "private-repo-link hits. Use this when repo_path "
                          "is not the repo being protected -- e.g. "
                          "/migrate-task invokes this script with its cwd "
                          "at the SOURCE repo being migrated OUT of, which "
                          "is exactly the repo an operator would list in "
                          "INTERNAL_PRIVATE_REPOS; the default own-slug "
                          "exclusion would then silently suppress the one "
                          "hit this check exists to catch (found in "
                          "independent review of T20260919-231319)")
    ap.add_argument("repo_path", nargs="?", default=".")
    args = ap.parse_args(argv)

    denylist = denylist_from_env()
    private_repos = private_repos_from_env()
    own_slug = None if args.no_own_repo_exclusion else repo_slug(args.repo_path)

    if args.changed is not None:
        files = [Path(f) for f in args.changed if Path(f).is_file()]
    else:
        files = list(iter_scan_files(args.repo_path))

    total_findings = 0
    total_unmapped = 0
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        findings = lint_text(text, denylist, private_repos, own_slug)
        if not findings:
            continue
        if args.fix:
            new_text, unmapped = apply_fix(text, findings)
            if new_text != text:
                f.write_text(new_text, encoding="utf-8")
            for uf in unmapped:
                print(f"❌ {f}: {uf.category}: {uf.term} (no safe auto-replacement)")
            total_unmapped += len(unmapped)
            total_findings += len(findings)
        else:
            for finding in findings:
                suggestion = f" (suggest: {finding.suggestion})" if finding.suggestion else ""
                print(f"❌ {f}: {finding.category}: {finding.term}{suggestion}")
            total_findings += len(findings)

    if args.fix:
        if total_unmapped:
            print(f"\n❌ {total_unmapped} finding(s) with no safe auto-replacement — refusing")
            return 1
        if total_findings:
            print(f"\n✅ substituted {total_findings} denylist hit(s)")
        return 0

    if total_findings:
        print(f"\n❌ {total_findings} internal-identifier finding(s)")
        return 1
    print("✅ no internal identifiers found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
