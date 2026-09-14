#!/usr/bin/env python3
"""Lint dev/TODO and dev/PARKING task files against the canonical frontmatter
schema (repo-conventions/templates/task.md). Exits non-zero on any violation.

Parsing + status tolerance mirror actions/sync-tasks/sync.py so a file never
lint-passes yet syncs wrong.
"""
import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # graceful: fall back to line-based key extraction
    yaml = None

REQUIRED = {"status", "estimation"}
ALLOWED = REQUIRED | {
    # authored-optional
    "priority", "deadline", "blocks", "blocked-by", "source",
    "target-repo", "target-path", "related", "owner", "description",
    # runtime (tooling-written: /stage, IPM, /focus)
    "scheduled", "claimed_by", "claimed_role", "iteration",
}
STATUS_TOKENS = {"open", "design", "coding", "review",
                 "blocked", "parked", "done", "closed"}
FILENAME_RE = re.compile(r"^T\d{8}-\d{6}-.+\.md$")
# Known non-task index files that legitimately live under dev/TODO/ — not
# subject to the task filename/frontmatter schema at all.
NON_TASK_FILES = {"queue.md"}
TASK_ID_RE = re.compile(r"T\d{8}-\d{6}")
ESTIMATION_RE = re.compile(r"^\d+(m|h|d|w)\b")
H1_RE = re.compile(r"^#\s+(T\d{8}-\d{6})\b")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def split_frontmatter(text):
    """Return (block_str, body_str), or (None, text) if no '---' block."""
    if not text.startswith("---\n"):
        return None, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None, text
    return parts[1], parts[2]


def parse_keys(block):
    """Top-level frontmatter as {key: value}. Uses yaml when it parses; falls
    back to a line-based scan for prose values that break yaml (unquoted ': ',
    the same case sync.py recovers from)."""
    if yaml is not None:
        try:
            meta = yaml.safe_load(block)
            if isinstance(meta, dict):
                return {str(k): v for k, v in meta.items()}
        except yaml.YAMLError:
            pass
    out = {}
    for line in block.splitlines():
        m = re.match(r"^([A-Za-z][\w-]*):(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def status_head(value):
    """Leading token of a status value, lowercased — mirrors sync.py's
    status_to_option_id tolerance (split on space/em-dash/hyphen/colon/paren)."""
    return re.split(r"[\s—:()-]", str(value).strip().lower(), 1)[0]


class Ctx:
    """Parsed task file: name, top-level keys, body, filename task-id, error."""
    def __init__(self, path):
        self.path = Path(path)
        self.name = self.path.name
        self.error = None
        self.keys = {}
        self.body = ""
        m = TASK_ID_RE.match(self.name)
        self.file_id = m.group(0) if m else None
        try:
            text = self.path.read_text(encoding="utf-8")
        except OSError as e:
            self.error = f"unreadable: {e}"
            return
        block, body = split_frontmatter(text)
        if block is None:
            self.error = "missing YAML frontmatter (--- block)"
            return
        self.keys = parse_keys(block)
        self.body = body


def check_required(ctx):
    return [f"missing required field '{r}'"
            for r in sorted(REQUIRED) if r not in ctx.keys]


def check_status(ctx):
    if "status" not in ctx.keys:
        return []
    head = status_head(ctx.keys["status"])
    if head not in STATUS_TOKENS:
        return [f"status '{ctx.keys['status']}': leading token "
                f"'{head}' is not a known status"]
    return []


def check_estimation(ctx):
    if "estimation" not in ctx.keys:
        return []
    if not ESTIMATION_RE.match(str(ctx.keys["estimation"]).strip()):
        return [f"estimation '{ctx.keys['estimation']}' must start with a "
                f"duration (e.g. 30m, 2h, 1d, 1w)"]
    return []


def check_allowlist(ctx):
    return [f"unknown field '{k}' (not in the canonical 16-key allowlist)"
            for k in sorted(ctx.keys) if k not in ALLOWED]


def check_filename(ctx):
    if not FILENAME_RE.match(ctx.name):
        return ["filename must match T<YYYYMMDD>-<NNNNNN>-<slug>.md"]
    return []


def check_h1_id(ctx):
    h1_id = None
    for line in ctx.body.splitlines():
        m = H1_RE.match(line)
        if m:
            h1_id = m.group(1)
            break
    if h1_id is None:
        return ["missing H1 title line '# T<id>: <title>'"]
    if ctx.file_id and h1_id != ctx.file_id:
        return [f"H1 id {h1_id} does not match filename id {ctx.file_id}"]
    return []


def check_scheduled_when_advanced(ctx):
    """Status beyond Open/Parked requires scheduled: present and YYYY-MM-DD.

    Mirrors the lifecycle.md § 'Iteration assignment' invariant: a task whose
    status has left Open/Parked MUST carry a valid scheduled: so sync maps it
    to the correct iteration. Leading-token tolerance mirrors sync.py — a
    prose-suffixed status like 'Coding — UNBLOCKED …' still triggers the check
    on its leading token 'Coding'. Scope is TODO/PARKING only (JOURNAL is out
    of lint scope per the design non-goal)."""
    if "status" not in ctx.keys:
        return []
    head = status_head(ctx.keys["status"])
    if head in ("open", "parked"):
        return []
    sched = ctx.keys.get("scheduled")
    sched_str = str(sched).strip() if sched is not None else ""
    if not sched_str or not DATE_RE.match(sched_str):
        reason = "missing" if not sched_str else f"'{sched_str}' is not a valid YYYY-MM-DD date"
        return [
            f"status '{ctx.keys['status']}': scheduled: is {reason} — "
            f"stamp it to the current Monday when work starts "
            f"(lifecycle.md § 'Iteration assignment')"
        ]
    return []


CHECKS = (check_required, check_status, check_estimation,
          check_allowlist, check_h1_id, check_scheduled_when_advanced)


def lint_file(path):
    """Return a list of violation strings (empty = clean)."""
    ctx = Ctx(path)
    out = list(check_filename(ctx))
    if ctx.error:
        out.append(ctx.error)
        return out
    for chk in CHECKS:
        out.extend(chk(ctx))
    return out


def is_task_file(path):
    """True for paths under dev/TODO or dev/PARKING (the lint scope),
    excluding known non-task index files (NON_TASK_FILES)."""
    p = Path(path)
    if p.name in NON_TASK_FILES:
        return False
    parts = p.parts
    return "dev" in parts and any(s in parts for s in ("TODO", "PARKING"))


def iter_task_files(repo_path):
    root = Path(repo_path)
    for sub in ("TODO", "PARKING"):
        d = root / "dev" / sub
        if d.is_dir():
            yield from (f for f in sorted(d.glob("*.md"))
                        if f.name not in NON_TASK_FILES)


def build_task_index(repo_path):
    """Return (live_ids, done_ids): the set of task ids whose file lives in
    dev/TODO+dev/PARKING (live / pickable) and dev/JOURNAL (Done), respectively.
    Used to validate that a 'Blocked by T<id>' status points at a live blocker.
    JOURNAL filenames carry a yyyy-mm-dd- prefix, so search (not match) the id;
    legacy journal files with no T<id> simply contribute nothing."""
    root = Path(repo_path)
    live, done = set(), set()
    for sub, dest in (("TODO", live), ("PARKING", live), ("JOURNAL", done)):
        d = root / "dev" / sub
        if not d.is_dir():
            continue
        for f in d.glob("*.md"):
            m = TASK_ID_RE.search(f.name)
            if m:
                dest.add(m.group(0))
    return live, done


def check_blocked_by(ctx, live_ids, done_ids):
    """If a task's status is 'Blocked by T<id>', each named blocker must be a
    *live* task file (dev/TODO or dev/PARKING). Flag a blocker that is already
    Done (moved to dev/JOURNAL) — the stale-block / missed-cascade-unblock gap —
    or that resolves to no task file at all (stale or mistyped reference).

    Keyed on `status:` only, never the free-text `blocked-by:` field: in the
    wild that field carries prose and strikethrough historical notes
    (e.g. '~~T123456~~ closed 2026-05-18') that intentionally name Done tasks.

    Scope is within-board: a `status: Blocked by T<id>` is expected to name a
    task in *this* repo's dev/ tree (the only blocker model the lifecycle and
    `/todo next` understand). A cross-repo / external dependency should NOT be
    written as `status: Blocked by T<id>` — it would resolve to "not found" —
    use `related:` or prose to record it instead."""
    status = ctx.keys.get("status")
    if status is None or status_head(status) != "blocked":
        return []
    out = []
    for bid in dict.fromkeys(TASK_ID_RE.findall(str(status))):  # ordered de-dup
        if bid == ctx.file_id:
            continue  # self-reference is a separate problem; ignore here
        if bid in live_ids:
            continue  # a live blocker wins even if a stale JOURNAL entry exists
        if bid in done_ids:
            out.append(
                f"blocker {bid} is already Done (in dev/JOURNAL/) — the block is "
                f"stale; clear it and cascade-unblock this task")
        else:
            out.append(
                f"blocker {bid} not found in dev/TODO, dev/PARKING, or "
                f"dev/JOURNAL — stale or mistyped blocker reference")
    return out


def lint_blocked_by(repo_path):
    """Board-wide cross-reference pass: returns {path: [violations]} for every
    TODO/PARKING task whose 'Blocked by' status names a non-live blocker.

    Runs over the whole board regardless of the changed-file set, because a
    block goes stale in the PR that *closes the blocker* (moves it to JOURNAL) —
    that PR never touches the blocked file, so a changed-files-only check would
    miss it. This is the gate that turns the bidirectional-link convention into
    enforcement."""
    live_ids, done_ids = build_task_index(repo_path)
    out = {}
    for f in iter_task_files(repo_path):
        ctx = Ctx(f)
        if ctx.error:
            continue  # the schema pass already reports unparseable files
        violations = check_blocked_by(ctx, live_ids, done_ids)
        if violations:
            out[f] = violations
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Lint dev/ task-file frontmatter.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--all", action="store_true",
                   help="lint every dev/TODO + dev/PARKING file under repo_path")
    g.add_argument("--changed", nargs="*", metavar="FILE",
                   help="schema-lint only these files (non-task files ignored); "
                        "an empty set still runs the board-wide blocked-by pass")
    ap.add_argument("repo_path", nargs="?", default=".")
    args = ap.parse_args(argv)

    # `--changed` (even with zero files) selects changed mode; its absence means
    # lint every board file. `is not None` distinguishes "--changed" with an
    # empty list from "--all"/default — the board-wide pass below runs in both.
    if args.changed is not None:
        files = [Path(f) for f in args.changed if is_task_file(f)]
    else:
        files = list(iter_task_files(args.repo_path))

    # Per-file schema pass over the selected (changed/all) files.
    results = {}  # str(path) -> list[violations]; preserves first-seen order
    for f in files:
        results.setdefault(str(f), []).extend(lint_file(f))

    # Board-wide blocked-by cross-reference pass — independent of the changed
    # set (see lint_blocked_by). Merges into any schema violations per file.
    for path, violations in lint_blocked_by(args.repo_path).items():
        results.setdefault(str(path), []).extend(violations)

    failed = sum(1 for v in results.values() if v)
    for path, violations in results.items():
        if violations:
            print(f"❌ {path}")
            for msg in violations:
                print(f"     - {msg}")
        else:
            print(f"✅ {path}")
    total = len(results)
    if failed:
        print(f"\n❌ {failed}/{total} task file(s) violate the conventions")
        return 1
    print(f"\n✅ {total} task file(s) conform")
    return 0


if __name__ == "__main__":
    sys.exit(main())
