#!/usr/bin/env python3
"""Check that relative markdown links under dev/ point at files that exist.

Why: a task's relative links rot when the close step moves it
(dev/TODO -> dev/JOURNAL/dev/PARKING). Nothing else re-checks them.

Rules:

- Scans ``dev/**/*.md``. Fenced code blocks and inline code spans are ignored.
- Skipped: external links (``scheme:``), ``mailto:``, pure ``#anchor``.
  ``#fragment`` / ``?query`` are stripped before the existence check.
- A target resolving OUTSIDE the repo root is a cross-repo path (not
  verifiable from one clone) and is skipped.
- A leading ``/`` resolves from the repo root (GitHub's rendering).
- Allow-list: ``dev/.link-allowlist`` (one fnmatch glob per line, ``#``
  comments) and ``--allow GLOB``; matched against the target as written.
  ``--print-allowlist`` prints today's broken targets in that format, to use
  as a rollout baseline.
- Repair by task id: a missing target whose basename contains ``T<id>`` that
  resolves to a file in dev/TODO, dev/PARKING or dev/JOURNAL is reported with
  the new relative path; ``--fix`` rewrites it (idempotent).

Read-only by default; exit 1 if any broken link remains.
"""
import argparse
import fnmatch
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote

LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
CODE_SPAN_RE = re.compile(r"`[^`]*`")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
TASK_ID_RE = re.compile(r"T\d{8}-\d{6}")
TASK_DIRS = ("TODO", "PARKING", "JOURNAL")
ALLOWLIST_REL = "dev/.link-allowlist"


def load_allowlist(root, extra=()):
    globs = list(extra)
    f = Path(root) / ALLOWLIST_REL
    if f.is_file():
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                globs.append(line)
    return globs


def is_allowed(target, globs):
    return any(fnmatch.fnmatch(target, g) for g in globs)


def split_target(raw):
    """-> (path, suffix) where suffix is the '#frag'/'?query' tail."""
    m = re.search(r"[#?]", raw)
    if not m:
        return raw, ""
    return raw[:m.start()], raw[m.start():]


def find_by_task_id(root, tid):
    for d in TASK_DIRS:
        base = Path(root) / "dev" / d
        if base.is_dir():
            for p in sorted(base.glob("*.md")):
                if tid in p.name:
                    return p
    return None


def check_link(root, src, raw, globs):
    """Return None if fine, else (reason, suggestion_or_None)."""
    path, suffix = split_target(raw)
    if not path or SCHEME_RE.match(raw) or raw.startswith("#"):
        return None
    path = unquote(path)
    base = Path(root) if path.startswith("/") else src.parent
    target = Path(os.path.normpath(base / path.lstrip("/")))
    root_abs = Path(os.path.normpath(root))
    try:
        target.relative_to(root_abs)
    except ValueError:
        return None  # cross-repo: not verifiable here
    if target.exists() or is_allowed(raw, globs):
        return None
    m = TASK_ID_RE.search(Path(path).name)
    if m:
        found = find_by_task_id(root_abs, m.group(0))
        if found is not None:
            rel = os.path.relpath(found, src.parent)
            return ("missing", rel + suffix)
    return ("missing", None)


def process_text(text, root, src, globs, fix=False):
    """-> (new_text, broken, fixed): broken = [(lineno, raw, suggestion)]."""
    out, broken, fixed = [], [], 0
    in_fence = False
    for n, line in enumerate(text.split("\n"), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        spans = [(m.start(), m.end()) for m in CODE_SPAN_RE.finditer(line)]

        def repl(m):
            nonlocal fixed
            if any(s <= m.start() < e for s, e in spans):
                return m.group(0)
            raw = m.group(1)
            res = check_link(root, src, raw, globs)
            if res is None:
                return m.group(0)
            _, sug = res
            if fix and sug:
                fixed += 1
                return m.group(0).replace(raw, sug, 1)
            broken.append((n, raw, sug))
            return m.group(0)

        out.append(LINK_RE.sub(repl, line))
    return "\n".join(out), broken, fixed


def dev_files(root):
    base = Path(root) / "dev"
    return sorted(base.rglob("*.md")) if base.is_dir() else []


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--all", action="store_true", help="scan dev/**/*.md (default)")
    ap.add_argument("--fix", action="store_true", help="rewrite links resolvable by T<id>")
    ap.add_argument("--allow", action="append", default=[], metavar="GLOB")
    ap.add_argument("--print-allowlist", action="store_true")
    args = ap.parse_args(argv)

    root = Path(args.repo).resolve()
    globs = load_allowlist(root, args.allow)
    all_broken, total_fixed = [], 0
    for f in dev_files(root):
        text = f.read_text(encoding="utf-8")
        new, broken, fixed = process_text(text, root, f, globs, fix=args.fix)
        if fixed:
            f.write_text(new, encoding="utf-8")
            total_fixed += fixed
        all_broken += [(f, *b) for b in broken]

    if args.print_allowlist:
        for t in sorted({b[2] for b in all_broken}):
            print(t)
        return 0
    for f, n, raw, sug in all_broken:
        hint = f" -> try {sug}" if sug else ""
        print(f"  ❌ {f.relative_to(root)}:{n}: broken link {raw}{hint}")
    if total_fixed:
        print(f"  fixed {total_fixed} link(s) by task id")
    if all_broken:
        print(f"❌ {len(all_broken)} broken relative link(s)")
        return 1
    print("✅ all relative links under dev/ resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
