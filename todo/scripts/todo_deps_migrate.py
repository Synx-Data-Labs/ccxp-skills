#!/usr/bin/env python3
"""Rewrite legacy `blocks:` lines into `depends_on` entries (T20261125-366351).

For each task A with `blocks: [X, ...]`: add A's id to X's `depends_on` (key
created when absent, de-duplicated, trailing comments and notes kept), then
remove the `blocks:` key from A. An id with no task file on the board cannot be
placed: it is reported and stays in A's `blocks:` (nothing is dropped silently).
Idempotent. `--dry-run` reports and writes nothing.

Usage: todo_deps_migrate.py [--dry-run] DIR [DIR ...]
Exit: 0 ok, 2 usage.
"""
import os
import re
import sys

ID = re.compile(r"T\d{8}-\d{6}")


def read_lines(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read().split("\n")


def fm_bounds(lines):
    """(start, end) line indexes of the frontmatter body, or None."""
    if not lines or lines[0].rstrip("\r") != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r") == "---":
            return (1, i)
    return None


def find_key(lines, key):
    """(first, last_exclusive) of `key:` and its block-list continuation, or None."""
    b = fm_bounds(lines)
    if not b:
        return None
    for i in range(b[0], b[1]):
        if lines[i].startswith(key + ":"):
            j = i + 1
            while j < b[1] and re.match(r"^\s*(-|#|$)", lines[j].rstrip("\r")):
                j += 1
            # trailing blank/comment lines belong to what follows, not the list
            while j > i + 1 and not lines[j - 1].lstrip().startswith("-"):
                j -= 1
            return (i, j)
    return None


def ids_of(lines, span):
    text = "\n".join(re.sub(r"#.*$", "", l) for l in lines[span[0]:span[1]])
    return list(dict.fromkeys(ID.findall(text)))


def add_dep(lines, dep):
    """Add `dep` to depends_on in place. Returns 'added' or 'already'."""
    span = find_key(lines, "depends_on")
    if span is None:
        b = fm_bounds(lines)
        lines.insert(b[1], "depends_on: [%s]" % dep)
        return "added"
    if dep in ids_of(lines, span):
        return "already"
    first = lines[span[0]]
    eol = "\r" if first.endswith("\r") else ""
    body = first.rstrip("\r")
    if span[1] - span[0] == 1:
        m = re.match(r"^(depends_on:\s*)\[(.*?)\](\s*(#.*)?)$", body)
        if m:
            inner = m.group(2).strip()
            inner = (inner + ", " + dep) if inner else dep
            lines[span[0]] = "%s[%s]%s%s" % (m.group(1), inner, m.group(3), eol)
            return "added"
        m = re.match(r"^(depends_on:)\s*(#.*)?$", body)
        if m:  # bare key: becomes a flow list, keeping the comment
            c = (" " + m.group(2)) if m.group(2) else ""
            lines[span[0]] = "depends_on: [%s]%s%s" % (dep, c, eol)
            return "added"
        lines[span[0]] = "depends_on: [%s]%s" % (dep, eol)  # scalar text: replace by list
        return "added"
    last = lines[span[1] - 1]
    indent = re.match(r"^(\s*)-", last).group(1)
    lines.insert(span[1], "%s- %s%s" % (indent, dep, "\r" if last.endswith("\r") else ""))
    return "added"


def main(argv):
    dry = False
    dirs = []
    for a in argv:
        if a == "--dry-run":
            dry = True
        elif a.startswith("-"):
            sys.stderr.write(__doc__)
            return 2
        else:
            dirs.append(a)
    if not dirs:
        sys.stderr.write(__doc__)
        return 2
    files = {}
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if re.match(r"^T\d{8}-\d{6}-.+\.md$", n):
                files.setdefault(n[:16], os.path.join(d, n))
    docs = {}  # id -> lines (loaded lazily, edited in memory)
    dirty = set()

    def load(i):
        if i not in docs:
            docs[i] = read_lines(files[i])
        return docs[i]

    stats = dict(files=0, relations=0, added=0, already=0, unknown=0, self=0)
    print("%s: blocks -> depends_on" % ("DRY RUN" if dry else "MIGRATE"))
    for a in sorted(files):
        lines = load(a)
        span = find_key(lines, "blocks")
        if span is None:
            continue
        stats["files"] += 1
        keep = []
        for x in ids_of(lines, span):
            stats["relations"] += 1
            if x == a:
                stats["self"] += 1
                print("  %s blocks itself: dropped" % a)
            elif x not in files:
                stats["unknown"] += 1
                keep.append(x)
                print("  %s blocks %s: unknown id, cannot convert (kept in blocks:)" % (a, x))
            else:
                r = add_dep(load(x), a)
                stats[r] += 1
                dirty.add(x)
                print("  %s blocks %s: %s in %s depends_on" % (a, x, "added" if r == "added" else "already present", x))
        lines = docs[a]
        span = find_key(lines, "blocks")
        if keep:
            lines[span[0]:span[1]] = ["blocks: [%s]" % ", ".join(keep)]
        else:
            del lines[span[0]:span[1]]
        dirty.add(a)
    print("SUMMARY files-with-blocks=%d relations=%d added=%d already=%d unknown=%d self=%d%s" % (
        stats["files"], stats["relations"], stats["added"], stats["already"],
        stats["unknown"], stats["self"], " (nothing written)" if dry else ""))
    if not dry:
        for i in sorted(dirty):
            with open(files[i], "w", encoding="utf-8", newline="") as f:
                f.write("\n".join(docs[i]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
