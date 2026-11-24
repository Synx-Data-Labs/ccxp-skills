#!/usr/bin/env python3
"""Lint dev/TODO and dev/PARKING task files against the canonical frontmatter
schema (repo-conventions/templates/task.md). Exits non-zero on any violation.

Parsing + status tolerance mirror actions/sync-tasks/sync.py so a file never
lint-passes yet syncs wrong.
"""
import argparse
import datetime
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
    # dependency chain (epic E3, T20261124-320024): inverse of blocks, and
    # human-only conditions that are NOT task dependencies
    "depends_on", "needs",
    "target-repo", "target-path", "related", "owner", "description",
    "source-url", "support-issue", "support-report",
    # task dimensions (T20261114-352324): time / place / person / type
    "when", "when-end", "place", "person", "type",
    # autopilot tier (T20261124-345756): 1..4, default 3
    "tier",
    # runtime (tooling-written: /stage, IPM, /focus)
    "scheduled", "claimed_by", "claimed_role", "claimed_takeover_from", "iteration",
}
STATUS_TOKENS = {"open", "design", "in progress", "review",
                 "blocked", "parked", "done", "closed"}
FILENAME_RE = re.compile(r"^T\d{8}-\d{6}-.+\.md$")
# Known non-task index files that legitimately live under dev/TODO/ — not
# subject to the task filename/frontmatter schema at all.
NON_TASK_FILES = {"queue.md"}
TASK_ID_RE = re.compile(r"T\d{8}-\d{6}")
ESTIMATION_RE = re.compile(r"^(1|2|3|5|8)(\s|$)")
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
    status_to_option_id tolerance (split on space/em-dash/hyphen/colon/paren).

    "In Progress" (T20260809-355059) is the one two-word status name, so its
    own two-word phrase is matched as a unit — ahead of the general
    single-token split below — when followed by a delimiter or end-of-string
    (never for a longer word like "Progressive" or a typo)."""
    v = str(value).strip().lower()
    if re.match(r"^in progress(?=[\s—:()-]|$)", v):
        return "in progress"
    return re.split(r"[\s—:()-]", v, 1)[0]


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
        return [f"estimation '{ctx.keys['estimation']}' must be one of "
                f"the Fibonacci-style points {{1, 2, 3, 5, 8}} "
                f"(T20260924-232855 — duration buckets retired, no "
                f"compatibility window)"]
    return []


TIER_RE = re.compile(r"^[1-4]$")


def check_tier(ctx):
    if "tier" not in ctx.keys:
        return []
    v = re.sub(r"\s+#.*$", "", str(ctx.keys["tier"]).strip()).strip("\"'")
    if not TIER_RE.match(v):
        return [f"tier '{ctx.keys['tier']}' must be an integer 1..4 "
                f"(1 urgent, 2 support, 3 default, 4 low)"]
    return []


def check_allowlist(ctx):
    return [f"unknown field '{k}' (not in the canonical "
            f"{len(ALLOWED)}-key allowlist)"
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
    prose-suffixed status like 'In Progress — UNBLOCKED …' still triggers the
    check on its leading token 'In Progress'. Scope is TODO/PARKING only
    (JOURNAL is out of lint scope per the design non-goal)."""
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


DONE_EQUIVALENT_HEADS = {"done", "closed"}


def check_not_done_in_todo(ctx):
    """A dev/TODO/ file whose status leads with 'done' or 'closed' should
    already have been journal-moved to dev/JOURNAL/ (T20260914-422854: every
    close journal-moves immediately — there is no deferred-close path left).

    'closed' is included alongside 'done': actions/sync-tasks/sync.py's
    status_to_option_id treats a 'closed'-leading status as Done-equivalent
    for the Project-board sync (`s.startswith("closed") or
    s.startswith("done")` -> Done), so a dev/TODO file reading 'status:
    Closed' already syncs to the board as Done — it must trip this guard the
    same way 'status: Done' does, or the exact symptom this check exists for
    (a Done-equivalent file stranded in dev/TODO) slips through via the
    other spelling. Caught in independent review of PR #219.

    Scope is dev/TODO/ only, never dev/PARKING/: a parked task keeps
    whatever status it had when parked, and 'parked' can never collide with
    either Done-equivalent leading token anyway, so no PARKING case can trip
    this. Catches the symptom regardless of cause — a stale-skill-cache miss
    (T20260922-201976), a hand-edited close, or any other path that can
    produce a dev/TODO/ file with a Done-equivalent status — not just the
    one incident that prompted it."""
    if "status" not in ctx.keys:
        return []
    if "TODO" not in ctx.path.parts:
        return []
    head = status_head(ctx.keys["status"])
    if head not in DONE_EQUIVALENT_HEADS:
        return []
    return [
        f"status '{ctx.keys['status']}': file is still in dev/TODO but "
        f"should have been journal-moved to dev/JOURNAL (T20260914-422854 — "
        f"every close journal-moves immediately)"
    ]


WHEN_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:?\d{2})?)?$")
TYPES = {"chore", "feature", "bug", "event", "research", "spike", "rca",
         "support", "other"}
SLUG_RE = re.compile(r"^[A-Za-z0-9][\w.-]*$")


def _text(v):
    """Stringify a frontmatter scalar; yaml turns 2026-11-14 into a date and
    2026-11-14T14:00 into a datetime, so format checks run on the ISO text."""
    if isinstance(v, datetime.datetime):
        return v.isoformat(timespec="minutes") if v.tzinfo is None else v.isoformat()
    if isinstance(v, datetime.date):
        return v.isoformat()
    return str(v).strip()


def _as_list(v):
    """Return (items, error). yaml lists pass through; the line-based fallback
    parser hands raw text, so '[a, b]' / 'a, b' / 'a' are split on commas."""
    if isinstance(v, list):
        return [str(i).strip() for i in v], None
    if isinstance(v, (dict, bool, int, float)) or v is None:
        return [], "must be a slug or a list of slugs"
    t = _text(v)
    if t.startswith("[") and t.endswith("]"):
        t = t[1:-1]
    return [i.strip().strip("'\"") for i in t.split(",") if i.strip()], None


def check_dimensions(ctx):
    """Optional when / when-end / place / person / type (T20261114-352324).
    Absent means no constraint. Hard errors only; soft nudges live in
    warn_dimensions."""
    out, k = [], ctx.keys
    for key in ("when", "when-end"):
        if key in k and not WHEN_RE.match(_text(k[key])):
            out.append(f"{key} '{_text(k[key])}' must be YYYY-MM-DD or "
                       f"YYYY-MM-DDTHH:MM (optional seconds, Z or offset)")
    if "when" in k and "when-end" in k:
        a, b = _text(k["when"]), _text(k["when-end"])
        if WHEN_RE.match(a) and WHEN_RE.match(b) and b[:min(len(a), len(b), 16)] < a[:min(len(a), len(b), 16)]:
            out.append(f"when-end '{b}' is before when '{a}'")
    for key in ("place", "person"):
        if key not in k:
            continue
        items, err = _as_list(k[key])
        if err:
            out.append(f"{key}: {err}")
        for it in items:
            if "@" in it:
                out.append(f"{key} '{it}' looks like an email address — use an alias")
            elif not SLUG_RE.match(it):
                out.append(f"{key} '{it}' must be a slug without whitespace "
                           f"(letters, digits, '-', '_', '.')")
    if "type" in k:
        t = _text(k["type"]).lower()
        if t not in TYPES:
            out.append(f"type '{_text(k['type'])}' must be one of "
                       f"{', '.join(sorted(TYPES))}")
        elif t == "event" and not _text(k.get("when") or ""):
            out.append("type: event requires 'when' (an event is a dated "
                       "task, never implementation work)")
    return out


def check_typed_blockers(ctx):
    """`Blocked by person:<alias>` / `ext:<text>` are typed non-task blockers
    (T20261114-352324). A person alias must be a slug (no email, no
    whitespace); ext text must not contain a T<id>-shaped string, which the
    task-id blocker check would misread as a task blocker."""
    status = ctx.keys.get("status")
    if status is None or status_head(status) != "blocked":
        return []
    out = []
    for m in re.finditer(r"\b(person|ext):(\S*)", str(status)):
        if m.group(1) == "person":
            alias = m.group(2).rstrip(",;")
            if not alias:
                out.append("Blocked by person: needs an alias")
            elif "@" in alias:
                out.append(f"Blocked by person:{alias} looks like an email — use an alias")
            elif not SLUG_RE.match(alias):
                out.append(f"Blocked by person:{alias} must be a slug without whitespace")
    em = re.search(r"\bext:(.*)$", str(status))
    if em and TASK_ID_RE.search(em.group(1)):
        out.append("Blocked by ext: text must not contain a T<id>-shaped string "
                   "(it would be read as a task blocker)")
    return out


def id_list(value):
    """Task ids named by a frontmatter value: a yaml list, or a string
    (flow list text, comma or space separated). Order kept, duplicates dropped."""
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        text = " ".join(str(v) for v in value if v is not None)
    else:
        text = re.sub(r"#.*$", "", str(value), flags=re.M)  # drop yaml comments
    return list(dict.fromkeys(TASK_ID_RE.findall(text)))


def legacy_blocker_ids(ctx):
    """Ids named by a legacy `status: Blocked by T<id>` (compat reader)."""
    status = ctx.keys.get("status")
    if status is None or status_head(status) != "blocked":
        return []
    return id_list(status)


def dependency_ids(ctx):
    """A task's dependencies: `depends_on:` plus any legacy `Blocked by` ids,
    so mixed old and new files read the same during the rollout."""
    return list(dict.fromkeys(id_list(ctx.keys.get("depends_on"))
                              + legacy_blocker_ids(ctx)))


def check_depends_on(ctx):
    """depends_on must be a list of well-formed T<id>s, never the task itself."""
    if "depends_on" not in ctx.keys:
        return []
    v = ctx.keys["depends_on"]
    if v is None or str(v).strip() in ("", "~", "null"):
        return []  # a bare `depends_on:` means none
    items = v if isinstance(v, (list, tuple)) else re.split(r"[\s,\[\]]+", str(v))
    items = [str(i).strip() for i in items if str(i).strip()]
    out = []
    for i in items:
        if not re.fullmatch(r"T\d{8}-\d{6}", i):
            out.append(f"depends_on entry '{i}' is not a task id (T<YYYYMMDD>-<NNNNNN>)")
        elif i == ctx.file_id:
            out.append("depends_on names the task itself")
    return out


def check_needs(ctx):
    """needs: a list of short tokens (human, vpn, owner-decision, ...); the
    typed forms person:<alias> and ext:<text> follow the Blocked by rules."""
    if "needs" not in ctx.keys:
        return []
    v = ctx.keys["needs"]
    if v is None or str(v).strip() in ("", "~", "null"):
        return []
    items = v if isinstance(v, (list, tuple)) else re.split(r"\s*,\s*", str(v).strip("[] "))
    out = []
    for raw in items:
        i = str(raw).strip()
        if not i:
            continue
        if "\n" in i:
            out.append("needs entries must be single-line")
        elif i.startswith("person:"):
            alias = i[len("person:"):]
            if not alias or "@" in alias or not SLUG_RE.match(alias):
                out.append(f"needs '{i}': person needs a slug alias (no email)")
        elif i.startswith("ext:"):
            if not i[len("ext:"):].strip():
                out.append("needs 'ext:' needs text")
        elif not SLUG_RE.match(i):
            out.append(f"needs '{i}' must be a slug (human, vpn, owner-decision) "
                       f"or person:<alias> / ext:<text>")
    return out


def warn_blocked_by(ctx):
    """Soft nudge: `Blocked by T<id>` is deprecated for depends_on (epic E3)."""
    ids = legacy_blocker_ids(ctx)
    if ids:
        return [f"status 'Blocked by {', '.join(ids)}' is deprecated: keep the real "
                f"status and record depends_on: [{', '.join(ids)}] (epic E3)"]
    return []


def warn_dimensions(ctx, today=None):
    """Soft nudges: printed, never change the exit code."""
    today = today or datetime.date.today().isoformat()
    if "status" not in ctx.keys or "when" not in ctx.keys:
        return []
    if status_head(ctx.keys["status"]) in ("done", "closed", "parked"):
        return []
    w = _text(ctx.keys["when"])
    if WHEN_RE.match(w) and w[:10] < today:
        if _text(ctx.keys.get("type", "")).lower() == "event":
            return [f"event date {w[:10]} has passed — close it (Open to Done)"]
        return [f"when '{w[:10]}' is in the past for an open task"]
    return []


def warnings_for(path, today=None):
    ctx = Ctx(path)
    if ctx.error:
        return []
    return warn_dimensions(ctx, today) + warn_blocked_by(ctx)


CHECKS = (check_required, check_status, check_estimation,
          check_allowlist, check_tier, check_h1_id, check_scheduled_when_advanced,
          check_not_done_in_todo, check_dimensions, check_typed_blockers,
          check_depends_on, check_needs)


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


def lint_depends_on(repo_path):
    """Board-wide pass over `depends_on:` (legacy `Blocked by` is covered by
    lint_blocked_by). Returns ({path: [violations]}, {path: [warnings]}).

    - violation: an id that exists nowhere (dev/TODO, PARKING, JOURNAL), or a
      cycle among live tasks (named once, on each member).
    - warning: an id already Done (in dev/JOURNAL/): stale, sweep drops it.
      Not a violation, so closing a dependency never fails an unrelated PR."""
    live_ids, done_ids = build_task_index(repo_path)
    graph, paths = {}, {}
    bad, warn = {}, {}
    for f in iter_task_files(repo_path):
        ctx = Ctx(f)
        if ctx.error or not ctx.file_id:
            continue
        ids = id_list(ctx.keys.get("depends_on"))
        graph[ctx.file_id] = [i for i in ids if i != ctx.file_id]
        paths[ctx.file_id] = f
        for i in graph[ctx.file_id]:
            if i in live_ids:
                continue
            if i in done_ids:
                warn.setdefault(f, []).append(
                    f"depends_on {i} is already Done (in dev/JOURNAL/): drop it")
            else:
                bad.setdefault(f, []).append(
                    f"depends_on {i} not found in dev/TODO, dev/PARKING, or "
                    f"dev/JOURNAL: stale or mistyped reference")
    # Cycle detection: iterative DFS with colors (linear, no path explosion on
    # DAGs). Legacy `Blocked by` edges count, so mixed boards are checked too.
    edges = {}
    for f in iter_task_files(repo_path):
        ctx = Ctx(f)
        if ctx.error or not ctx.file_id:
            continue
        edges[ctx.file_id] = [i for i in dependency_ids(ctx) if i != ctx.file_id]
    color = {}  # absent = white, 1 = on the stack, 2 = done
    cyc = set()
    for root in edges:
        if root in color:
            continue
        stack = [(root, iter(edges[root]))]
        trail = [root]
        color[root] = 1
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                color[node] = 2
                stack.pop()
                trail.pop()
            elif nxt in edges:
                if color.get(nxt) == 1:
                    loop = trail[trail.index(nxt):] + [nxt]
                    for member in loop[:-1]:
                        cyc.add((member, " -> ".join(loop)))
                elif nxt not in color:
                    color[nxt] = 1
                    trail.append(nxt)
                    stack.append((nxt, iter(edges[nxt])))
    for member, text in sorted(cyc):
        if member in paths:
            bad.setdefault(paths[member], []).append("depends_on cycle: " + text)
    return bad, warn


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

    # Board-wide depends_on pass (unknown ids and cycles fail; Done ids warn).
    dep_bad, dep_warn = lint_depends_on(args.repo_path)
    for path, violations in dep_bad.items():
        results.setdefault(str(path), []).extend(violations)

    # Warning channel: printed, exit code unaffected.
    warned = 0
    for path, msgs in dep_warn.items():
        for msg in msgs:
            warned += 1
            print(f"⚠️  {path}: {msg}")
    for f in files:
        for msg in warnings_for(f):
            warned += 1
            print(f"⚠️  {f}: {msg}")

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
    print(f"\n✅ {total} task file(s) conform"
          + (f" ({warned} warning(s))" if warned else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
