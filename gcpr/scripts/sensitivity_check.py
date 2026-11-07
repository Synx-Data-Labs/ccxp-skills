#!/usr/bin/env python3
"""Sensitivity check for /gcpr: customer/partner names in added lines and commit messages.

The deny-list is private and NEVER committed. Same posture as
repo-conventions/scripts/lint_identifiers.py (env var or file, unset = no-op),
but this check needs whole-word matching and must not echo the matched term,
so it carries its own small matcher instead of calling that linter (which
substring-matches and prints the term).

Deny-list: SENSITIVE_NAMES_DENYLIST_FILE (path to a private file) wins over
SENSITIVE_NAMES_DENYLIST (the same newline-separated content inline). One term
per line; blank lines and lines starting with # are ignored. Matching is
whole-word and case-insensitive.

Scope: lines ADDED by the working tree vs HEAD (staged, unstaged, untracked),
by every commit in <base>..HEAD, and the text of those commit messages plus
any --message-file (a drafted commit message or PR text).

Output never contains a term or the matched line: only `HIT <where>` rows and a
count. Exit 0 clean or not configured (fail-soft, warns on stderr), 1 hits.

Usage: sensitivity_check.py [--base-ref REF] [--message-file F]...
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def load_terms():
    path = os.environ.get("SENSITIVE_NAMES_DENYLIST_FILE", "")
    raw = None
    if path:
        try:
            with open(path, encoding="utf-8") as fh:
                raw = fh.read()
        except OSError:
            print("sensitivity-check: WARNING deny-list file unreadable", file=sys.stderr)
    if raw is None:
        raw = os.environ.get("SENSITIVE_NAMES_DENYLIST", "")
    terms = []
    for ln in raw.splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            terms.append(ln)
    return terms


def build_regex(terms):
    alts = "|".join(re.escape(t) for t in sorted(set(terms), key=len, reverse=True))
    return re.compile(r"(?<!\w)(?:%s)(?!\w)" % alts, re.IGNORECASE)


class GitError(Exception):
    pass


def git(*args, check=True):
    r = subprocess.run(["git", "-c", "core.quotepath=off", *args],
                       capture_output=True, text=True, errors="replace")
    if check and r.returncode != 0:
        raise GitError(args[0])
    return r.returncode, r.stdout


_UNQUOTE = {"\\\\": "\\", '\\"': '"', "\\t": "\t", "\\n": "\n"}


def clean_path(p):
    p = p.split("\t")[0] if not p.startswith('"') else p
    if p.startswith('"') and p.endswith('"'):
        p = re.sub(r'\\[\\"tn]', lambda m: _UNQUOTE[m.group(0)], p[1:-1])
    return p


def added_lines(diff_text):
    """Yield (path, lineno, text, sha_or_None) for each added line of a -U0 diff.

    Hunk lengths from the @@ header decide which rows are content, so an added
    line that itself starts with "++" or "+++ " is still scanned.
    """
    path, ln, sha = None, 0, None
    rem_add = rem_del = 0
    for row in diff_text.split("\n"):
        if rem_add or rem_del:
            if row.startswith("-") and rem_del:
                rem_del -= 1
                continue
            if row.startswith("+") and rem_add:
                rem_add -= 1
                if path:
                    yield path, ln, row[1:], sha
                ln += 1
                continue
            if row.startswith("\\"):
                continue
            rem_add = rem_del = 0
        if row.startswith("COMMIT "):
            sha, path = row[7:15], None
        elif row.startswith("+++ "):
            p = clean_path(row[4:])
            path = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
        elif row.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", row)
            if m:
                rem_del = int(m.group(1)) if m.group(1) is not None else 1
                ln = int(m.group(2))
                rem_add = int(m.group(3)) if m.group(3) is not None else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-ref", default="")
    ap.add_argument("--message-file", action="append", default=[])
    args = ap.parse_args(argv)

    terms = load_terms()
    if not terms:
        print("sensitivity-check: WARNING no deny-list configured (set "
              "SENSITIVE_NAMES_DENYLIST_FILE or SENSITIVE_NAMES_DENYLIST); "
              "customer/partner names were NOT checked", file=sys.stderr)
        print("SENSITIVITY=skipped")
        return 0
    rx = build_regex(terms)
    hits = []

    def label(path):
        # A path that itself matches is never printed: an opaque id stands in.
        if rx.search(path):
            return "file#" + hashlib.sha1(path.encode()).hexdigest()[:8]
        return path

    def scan(path, ln, text, sha=None):
        where = f"{label(path)}:{ln}" + (f" ({sha})" if sha else "")
        if rx.search(text):
            hits.append(where)

    def scan_name(path, sha=None):
        if rx.search(path):
            hits.append(f"{label(path)}:name" + (f" ({sha})" if sha else ""))

    try:
        rc, _ = git("rev-parse", "--verify", "-q", "HEAD", check=False)
        head = "HEAD" if rc == 0 else EMPTY_TREE
        _, diff = git("diff", "-U0", "--no-color", "--no-ext-diff", head)
        for path, ln, text, _ in added_lines(diff):
            scan(path, ln, text)
        _, names = git("diff", "--name-only", "-z", "--diff-filter=ACMR", head)
        _, untracked = git("ls-files", "-o", "--exclude-standard", "-z")
        for path in filter(None, (names + untracked).split("\0")):
            scan_name(path)
        for path in filter(None, untracked.split("\0")):
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\0" in data:
                continue
            for i, text in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
                scan(path, i, text)

        if args.base_ref:
            _, log = git("log", "--no-merges", "-p", "-U0", "--no-color",
                         "--no-ext-diff", "--format=COMMIT %H", f"{args.base_ref}..HEAD")
            for path, ln, text, sha in added_lines(log):
                scan(path, ln, text, sha)
            _, cnames = git("log", "--no-merges", "--name-only", "-z", "--diff-filter=ACMR",
                            "--format=", f"{args.base_ref}..HEAD")
            for path in filter(None, cnames.split("\0")):
                scan_name(path)
            _, msgs = git("log", "--format=%h%x1f%B%x1e", f"{args.base_ref}..HEAD")
            for rec in filter(str.strip, msgs.split("\x1e")):
                sha, _, body = rec.strip().partition("\x1f")
                for i, text in enumerate(body.splitlines(), 1):
                    if rx.search(text):
                        hits.append(f"commit {sha} message:{i}")
    except GitError as e:
        print(f"SENSITIVITY=blocked reason=git-{e}-failed")
        return 2

    for mf in args.message_file:
        try:
            with open(mf, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            print("sensitivity-check: WARNING message file unreadable", file=sys.stderr)
            continue
        for i, text in enumerate(lines, 1):
            if rx.search(text):
                hits.append(f"message-file:{i}")

    hits = list(dict.fromkeys(hits))
    for h in hits:
        print(f"HIT {h}")
    if hits:
        print(f"SENSITIVITY=blocked count={len(hits)}")
        print("sensitivity-check: replace names with aliases (customer A / partner B); "
              "do not print the matched term", file=sys.stderr)
        return 1
    print(f"SENSITIVITY=clean terms={len(set(terms))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
