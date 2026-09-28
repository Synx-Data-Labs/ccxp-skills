#!/usr/bin/env python3
"""Link task/issue/PR references in dev/TODO + dev/JOURNAL task files.

Two kinds of reference become clickable:

- T-ids (``T20260611-000001``) -> the stable GitHub-issue mirror link, via
  ``_taskid/url.sh``'s ``taskid-mdlink`` (reused, not reimplemented — that
  script already owns T-id -> issue-number resolution).
- *Typed* ``#N`` refs — only text the author already prefixed with "PR",
  "pull request", or "issue" (case-insensitive). A bare ``#N`` (street
  address, ordinal, ...) is never linkified — see T20260616-130977's Context
  section for the false-positive corpus that ruled that out. Typed refs are
  verified via ``gh api repos/<slug>/issues/<n>`` (GitHub's Issues API tags a
  PR with a ``pull_request`` key) and the label is *corrected* to match, so
  "issue #250" for what's actually a PR renders as "PR #250".

A reference that can't be resolved (cross-repo T-id, network/gh failure) is
left bare rather than guessed at. Same treatment for a typed ref explicitly
qualified with a DIFFERENT repo's name ("example-website.com PR #39") — resolving
against the current repo would link to the wrong PR/issue entirely. A file
whose own frontmatter/body declares a `target-repo` (or legacy `**Target
repo**:` bullet) other than the current repo is treated as foreign for
EVERY typed ref in it, even with no per-line qualifier — a same-line-only
check can't catch a file that just says "PR #134" with no repo name nearby
when the whole file's own declared home is elsewhere (T20260616-130977
backfill review, round 2). Known residual gaps, left as documented
limitations rather than chasing arbitrary-repo NLP inference: a file with
NO declared target-repo and no per-line qualifier, whose typed refs are
nonetheless about another repo purely from surrounding prose context, isn't
detected; and a `target-repo` value that names more than one repo or is
free-form prose (e.g. "Both hub-repo + build-pipeline-repo") extracts
only its first token, which can be wrong — real in this corpus but rare
enough, and low-enough-stakes (a readability nicety, not correctness-
critical infra), not to warrant a full multi-repo parser here.
Already-linked refs (inline `[...](...)` or this corpus's `[[T-id]]`
wiki-style convention), refs inside a fenced code block or inline code span,
a file's own H1 self-reference, and a T-id embedded in a bare filename are
all skipped, so re-running is a no-op (the idempotency this script's own
tests + Done criteria require).

Two modes:

- Read-only (default) — reports unresolved-but-linkable refs and exits
  non-zero if any exist. Wired into ``lint.sh`` next to ``lint_tasks.py``.
- ``--fix`` — rewrites files in place; never fails (a ref left bare because
  it's unresolvable isn't a violation). Wired into ``/gcpr``'s doc-lint guard
  next to ``lint_paragraphs.py --changed``.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

NON_TASK_FILES = {"queue.md"}
REF_DIRS = ("TODO", "JOURNAL")

TASK_ID_RE = re.compile(r"\bT\d{8}-\d{6}\b")
TYPED_REF_RE = re.compile(r"\b(PR|pull request|issue)\s*#(\d+)\b", re.IGNORECASE)
MD_LINK_RE = re.compile(r"\[[^\]]*\]\([^)]*\)")
# This corpus also uses a [[T-id]] wiki-style cross-ref convention alongside
# the inline-link one — protect it too, or linkifying just the inner bare id
# produces a malformed [[[id](url)]].
WIKI_LINK_RE = re.compile(r"\[\[[^\]]*\]\]")
CODE_SPAN_RE = re.compile(r"`[^`]*`")
# A bare (unbacktick'd) filename can contain a T-id as a substring
# ('...-T20260611-000001-slug.md') — never splice a link into the middle of
# a path/filename token.
FILENAME_RE = re.compile(r"\S*\.md\b")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
# lint_tasks.py's H1_RE requires the H1 to start with a BARE T-id matching
# the filename ('# T<id>: <title>') — linkifying it would break that
# structural check, so the file's own H1 self-reference is never linkified.
H1_SELF_REF_RE = re.compile(r"^#\s+(T\d{8}-\d{6})\b")
# A typed ref qualified with a DIFFERENT repo's name/domain ("example-website.com
# PR #39", "PR #82 on ccxp-skills") refers to that repo's PR/issue, not this
# repo's — resolving it against the current repo would link to the wrong
# thing entirely. The sibling-repo portfolio is consumer-specific, so there
# is no baked-in default here — it's read from KNOWN_SIBLING_REPOS (same
# os.environ.get pattern as gh_argv()'s LINT_REFS_GH override, below).
# Unset/empty -> empty set -> the foreign-repo-qualification heuristic is
# simply a no-op (graceful degrade, never a crash — same posture as every
# other config-driven knob in this task).
def known_sibling_repos():
    """Sibling repo names from KNOWN_SIBLING_REPOS (comma-and/or-whitespace
    -separated, e.g. "hub-repo, build-pipeline-repo"), or an empty set
    when the env var is unset/empty. Read live on every call (not cached at
    import time) so callers — and tests — can set/unset the env var
    per-case, same as gh_argv()'s LINT_REFS_GH read."""
    raw = os.environ.get("KNOWN_SIBLING_REPOS", "")
    return {name for name in re.split(r"[,\s]+", raw.strip()) if name}

URL_SH = Path(__file__).resolve().parent.parent.parent / "_taskid" / "url.sh"


def _protected_spans(line):
    spans = [m.span() for m in MD_LINK_RE.finditer(line)]
    spans += [m.span() for m in WIKI_LINK_RE.finditer(line)]
    spans += [m.span() for m in CODE_SPAN_RE.finditer(line)]
    spans += [m.span() for m in FILENAME_RE.finditer(line)]
    h1_self_ref = H1_SELF_REF_RE.match(line)
    if h1_self_ref:
        spans.append(h1_self_ref.span(1))
    return spans


def _foreign_repo_qualified(line, current_repo_name):
    """True if `line` names a KNOWN_SIBLING_REPOS entry other than the
    current repo — a signal that a typed PR/issue ref on this line belongs
    to that other repo, not the current one. Masks out the current repo's
    own name first (rather than skipping any known_sibling_repos() entry
    that's merely a substring of it) — e.g. "hub" is a substring of
    "hub-repo", two distinct repo names, so a pairwise name-vs-name
    substring check would wrongly treat a genuine mention of the shorter
    name as a self-reference of the longer one."""
    masked = line
    if current_repo_name:
        masked = re.sub(r"\b" + re.escape(current_repo_name) + r"\b", "", masked, flags=re.IGNORECASE)
    for name in known_sibling_repos():
        if name == current_repo_name:
            continue
        if re.search(r"\b" + re.escape(name) + r"\b", masked, re.IGNORECASE):
            return True
    return False


def _overlaps(span, spans):
    start, end = span
    return any(start < pe and ps < end for ps, pe in spans)


def process_line(line, resolve_taskid, resolve_typed, current_repo_name=None, file_foreign=False):
    """Return (new_line, fixed_count, bare_count)."""
    protected = _protected_spans(line)
    replacements = []
    bare = 0
    foreign = file_foreign or (
        current_repo_name is not None and _foreign_repo_qualified(line, current_repo_name))

    for m in TASK_ID_RE.finditer(line):
        if _overlaps(m.span(), protected):
            continue
        link = resolve_taskid(m.group(0))
        if link:
            replacements.append((m.start(), m.end(), link))
        else:
            bare += 1

    for m in TYPED_REF_RE.finditer(line):
        if _overlaps(m.span(), protected):
            continue
        if foreign:
            bare += 1
            continue
        number = m.group(2)
        resolved = resolve_typed(number)
        if resolved:
            label, url = resolved
            replacements.append((m.start(), m.end(), f"[{label} #{number}]({url})"))
        else:
            bare += 1

    if not replacements:
        return line, 0, bare

    replacements.sort(key=lambda r: r[0], reverse=True)
    new_line = line
    for start, end, text in replacements:
        new_line = new_line[:start] + text + new_line[end:]
    return new_line, len(replacements), bare


def process_text(text, resolve_taskid, resolve_typed, current_repo_name=None, file_foreign=False):
    """Return (new_text, fixed_count, bare_count) for a body (no frontmatter)."""
    lines = text.splitlines(keepends=True)
    out = []
    in_fence = False
    total_fixed = 0
    total_bare = 0
    for line in lines:
        if FENCE_RE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        new_line, fixed, bare = process_line(
            line, resolve_taskid, resolve_typed, current_repo_name, file_foreign)
        out.append(new_line)
        total_fixed += fixed
        total_bare += bare
    return "".join(out), total_fixed, total_bare


def split_frontmatter(text):
    """Return (frontmatter_str_incl_delimiters, body_str). frontmatter is ''
    when there is none — mirrors lint_paragraphs.py's strip_frontmatter, kept
    here (not shared) since this module also needs the frontmatter back."""
    if not text.startswith("---\n"):
        return "", text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return "", text
    return f"---{parts[1]}---", parts[2]


TARGET_REPO_FRONTMATTER_RE = re.compile(
    r"^target-repo:\s*[\"'`]*(?:your-org/)?([\w.-]+)", re.IGNORECASE | re.MULTILINE)
TARGET_REPO_BODY_RE = re.compile(
    r"^-\s*\*\*Target repo\*\*:\s*[\"'`]*(?:your-org/)?([\w.-]+)", re.IGNORECASE | re.MULTILINE)


def declared_target_repo(full_text):
    """The repo name this FILE declares as its own (YAML `target-repo:` key,
    or a legacy `- **Target repo**:` body bullet for pre-frontmatter files),
    or None if the file declares none. Only the short repo name is returned
    (the `your-org/` org prefix, if present, is stripped)."""
    for pattern in (TARGET_REPO_FRONTMATTER_RE, TARGET_REPO_BODY_RE):
        m = pattern.search(full_text)
        if m:
            return m.group(1)
    return None


def lint_file(path, resolve_taskid, resolve_typed, current_repo_name=None):
    """Return (new_full_text, fixed_count, bare_count) for the file at path.
    Frontmatter is passed through untouched — YAML values aren't markdown."""
    text = Path(path).read_text(encoding="utf-8")
    fm, body = split_frontmatter(text)
    declared = declared_target_repo(text)
    file_foreign = bool(
        declared and current_repo_name
        and declared.lower() != current_repo_name.lower()
    )
    new_body, fixed, bare = process_text(
        body, resolve_taskid, resolve_typed, current_repo_name, file_foreign)
    return fm + new_body, fixed, bare


def is_ref_file(path):
    p = Path(path)
    if p.name in NON_TASK_FILES:
        return False
    parts = p.parts
    return "dev" in parts and any(s in parts for s in REF_DIRS)


def iter_ref_files(repo_path):
    root = Path(repo_path)
    for sub in REF_DIRS:
        d = root / "dev" / sub
        if d.is_dir():
            yield from (f for f in sorted(d.glob("*.md")) if f.name not in NON_TASK_FILES)


def parse_repo_slug(remote_url):
    url = remote_url.strip()
    if url.endswith(".git"):
        url = url[:-4]
    marker = "github.com"
    idx = url.find(marker)
    if idx == -1:
        return None
    tail = url[idx + len(marker):].lstrip(":/")
    return tail or None


def repo_slug(repo_root="."):
    try:
        out = subprocess.run(
            ["git", "remote", "get-url", "origin"], cwd=repo_root,
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return parse_repo_slug(out.stdout)


def gh_argv():
    """Account-aware gh command, mirroring _taskid/url.sh's taskid-gh chain:
    env override -> the repo's account wrapper -> raw gh."""
    override = os.environ.get("LINT_REFS_GH")
    if override:
        return [override]
    wrapper = Path.home() / ".claude" / "skills" / "_gh" / "gh.sh"
    if wrapper.is_file() and os.access(wrapper, os.X_OK):
        return ["bash", str(wrapper)]
    return ["gh"]


def make_taskid_resolver(repo_root="."):
    """A T-id resolves only when taskid-mdlink lands on a real issue URL —
    its fallback code-search link (unresolvable case) is deliberately NOT
    treated as a resolution, so an unresolvable T-id (e.g. cross-repo) is
    left bare per the task's "don't guess" design. Cached: the same T-id can
    recur many times across one file or a whole --all run."""
    cache = {}

    def _resolve(tid):
        if tid in cache:
            return cache[tid]
        try:
            out = subprocess.run(
                ["bash", "-c", 'source "$1"; taskid-mdlink "$2"', "_", str(URL_SH), tid],
                cwd=repo_root, capture_output=True, text=True, timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired):
            out = None
        link = None
        if out is not None and out.returncode == 0:
            candidate = out.stdout.strip()
            if candidate and "/issues/" in candidate:
                link = candidate
        cache[tid] = link
        return link
    return _resolve


def make_typed_ref_resolver(slug, gh_command=None):
    gh_command = gh_command or gh_argv()
    cache = {}

    def _resolve(number):
        if number in cache:
            return cache[number]
        result = None
        if slug:
            try:
                out = subprocess.run(
                    gh_command + ["api", f"repos/{slug}/issues/{number}"],
                    capture_output=True, text=True, timeout=20,
                )
            except (OSError, subprocess.TimeoutExpired):
                out = None
            if out is not None and out.returncode == 0:
                try:
                    data = json.loads(out.stdout)
                except json.JSONDecodeError:
                    data = None
                if isinstance(data, dict):
                    if "pull_request" in data:
                        result = ("PR", f"https://github.com/{slug}/pull/{number}")
                    else:
                        result = ("issue", f"https://github.com/{slug}/issues/{number}")
        cache[number] = result
        return result
    return _resolve


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Link T-id / typed PR-or-issue #N references in dev/TODO "
                    "+ dev/JOURNAL task files. Read-only mode reports and "
                    "fails on any unlinked-but-linkable ref; --fix rewrites "
                    "files in place and never fails.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true",
                   help="scan every dev/TODO + dev/JOURNAL file under repo_path")
    g.add_argument("--changed", nargs="*", metavar="FILE",
                   help="scan only these files (non-ref files ignored)")
    ap.add_argument("--fix", action="store_true",
                     help="rewrite files in place instead of reporting")
    ap.add_argument("repo_path", nargs="?", default=".")
    args = ap.parse_args(argv)

    if args.changed is not None:
        files = [Path(f) for f in args.changed if is_ref_file(f)]
        repo_root = "."
    else:
        files = list(iter_ref_files(args.repo_path))
        repo_root = args.repo_path

    slug = repo_slug(repo_root)
    current_repo_name = slug.rsplit("/", 1)[-1] if slug else None
    resolve_taskid = make_taskid_resolver(repo_root)
    resolve_typed = make_typed_ref_resolver(slug)

    total_fixed = 0
    total_bare = 0
    files_with_fixes = 0
    for f in files:
        new_text, fixed, bare = lint_file(f, resolve_taskid, resolve_typed, current_repo_name)
        total_fixed += fixed
        total_bare += bare
        if fixed:
            files_with_fixes += 1
            if args.fix:
                Path(f).write_text(new_text, encoding="utf-8")
                print(f"✏️  {f}: linked {fixed} reference(s)")
            else:
                print(f"❌ {f}: {fixed} unlinked reference(s) found (run with --fix)")

    if total_bare:
        print(f"ℹ️  {total_bare} reference(s) left unlinked "
              f"(unresolvable in this repo — cross-repo T-id or unknown #N)")

    if args.fix:
        print(f"\n✅ linked {total_fixed} reference(s) across "
              f"{files_with_fixes} file(s)")
        return 0
    if total_fixed:
        print(f"\n❌ {total_fixed} unlinked reference(s) across "
              f"{files_with_fixes} file(s) — run with --fix")
        return 1
    print("✅ no unlinked references found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
