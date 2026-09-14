#!/usr/bin/env python3
"""Sync task .md files to GitHub Issues.

Modes:
- sync: react to file adds/moves/in-place edits between dev/TODO, dev/PARKING,
  dev/JOURNAL since HEAD~1 (adds create issues, moves drive state transitions,
  in-place edits resync Project fields)
- backfill: create Issues for any TODO/PARKING files not yet indexed,
  then ensure every mapped Issue is on the Project board with fields synced
- reconcile: resync Project fields for every mapped item (no issue creation) —
  one-time drift repair and a safe repeatable heartbeat
- dry-run: log what sync would do without making API calls

Body content is NOT synced — only state transitions and the initial Issue title.
The task file is the canonical source; the Issue body is a thin pointer with a
permalink back to the file.

The task↔issue mapping is derived at runtime by build_index() — list all issues
and parse the task-id from each body permalink (title as fallback). GitHub is
the source of truth; there is no sidecar file to persist (the committed
.github/task-issue-map.json was retired in T20260610-023106 — its persist-PR
flow could not reliably self-merge, RCA in T20260608-125662).
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

import yaml

REPO = os.environ["GH_REPO"]
TOKEN = os.environ.get("PROJECT_PAT") or os.environ["GH_TOKEN"]
MODE = os.environ.get("MODE", "sync")
TASK_ID_RE = re.compile(r"(T\d{8}-\d{6})")
PARKED_LABEL = "parked"

# IPM-weekly issues: a parallel synced kind, keyed by the iteration's own
# Monday date rather than a task id (see build_ipm_index()). The filename
# regex is anchored so a task journal whose slug happens to end in
# "...-to-ipm-weekly.md" (e.g. T20260513-359694's rename-*-to-ipm-weekly.md)
# never matches — only a real dated ipm-weekly.md does.
IPM_FILE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-ipm-weekly\.md$")
# Hidden marker written by ipm_issue_body(), parsed back by build_ipm_index() —
# the IPM-issue analogue of how _parse_issue_ref() recovers a task id from the
# body permalink.
IPM_MARKER_RE = re.compile(r"<!-- ipm:(\d{4}-\d{2}-\d{2}) -->")
# The /stage skill's pre-IPM staging stub header — same sniff `_ipm/current.sh`
# uses to exclude it from "the current committed IPM". A stub is candidates
# only, not yet a committed iteration, so it must not get an Issue.
_IPM_STAGING_RE = re.compile(r"Status.*Pre-IPM staging", re.IGNORECASE)
DRY_RUN = MODE == "dry-run"

# Project V2 integration. Only attempted when PROJECT_PAT is set (the PAT
# needs org-level Projects: Read and write). With GITHUB_TOKEN as the only
# token, Project ops would 403 — so we skip them. PROJECT_OWNER/PROJECT_NUMBER
# have no default — required alongside PROJECT_PAT for Project V2 sync; see
# get_project_id()'s "not configured" degrade below.
PROJECT_OWNER = os.environ.get("PROJECT_OWNER", "")
PROJECT_NUMBER = int(os.environ.get("PROJECT_NUMBER") or 0)
HAS_PAT = bool(os.environ.get("PROJECT_PAT"))


def log(msg):
    print(msg, flush=True)


# Permalink in an Issue body: **Task file**: [path](https://github.com/<repo>/blob/<ref>/<path>)
_PERMALINK_PATH_RE = re.compile(r"/blob/[^/\s]+/(\S+?\.md)")


def _parse_issue_ref(body, title):
    """Recover (task_id, path) from an Issue. The body carries the task-file
    permalink written by issue_body(); the task_id lives in the filename. Falls
    back to the title for the id. Returns (None, None) if no task_id is found."""
    body = body or ""
    title = title or ""
    m = TASK_ID_RE.search(body) or TASK_ID_RE.search(title)
    if not m:
        return None, None
    pm = _PERMALINK_PATH_RE.search(body)
    return m.group(1), (pm.group(1) if pm else None)


def build_index():
    """Derive {task_id: {issue, node_id, path, project_item_id}} by querying
    GitHub. GitHub is the source of truth, so there is no sidecar file to
    persist — which is exactly what the retired map's persist-PR flow tripped
    over (T20260608-125662). Uses the strongly-consistent REST issue *list*,
    never the search API (its index lags by seconds, which would hide a
    just-created issue and spawn a duplicate). In-run consistency is preserved
    by callers, which insert newly-created issues into this dict as they go."""
    index = {}
    r = gh(["issue", "list", "--repo", REPO, "--state", "all", "--limit", "1000",
            "--json", "number,title,body,id"], check=False)
    if r.returncode != 0:
        log("index: could not list issues — proceeding with empty index")
        return index
    try:
        issues = json.loads(r.stdout)
    except json.JSONDecodeError:
        return index
    if len(issues) >= 1000:
        log("index: WARNING — hit the 1000-issue list cap; mapping may be incomplete")
    for iss in issues:
        tid, path = _parse_issue_ref(iss.get("body"), iss.get("title"))
        if not tid:
            continue
        entry = {"issue": iss["number"], "node_id": iss.get("id")}
        if path:
            entry["path"] = path
        index.setdefault(tid, entry)  # first issue per task wins
    _attach_project_items(index)
    log(f"index: derived {len(index)} task→issue entries from GitHub")
    return index


def build_ipm_index():
    """Derive {ipm_date: {issue, node_id}} the same way build_index() derives
    the task map — list issues and parse the <!-- ipm:DATE --> marker written
    by ipm_issue_body(). A separate index (not folded into build_index())
    because IPM issues key on Monday date, not a task id, and only ever live
    in dev/JOURNAL/ — no PARKING/TODO lifecycle, so no Project-item lookup is
    needed up front (ensure_ipm_on_project() resolves it lazily)."""
    index = {}
    r = gh(["issue", "list", "--repo", REPO, "--state", "all", "--limit", "1000",
            "--json", "number,title,body,id"], check=False)
    if r.returncode != 0:
        log("ipm-index: could not list issues — proceeding with empty index")
        return index
    try:
        issues = json.loads(r.stdout)
    except json.JSONDecodeError:
        return index
    for iss in issues:
        m = IPM_MARKER_RE.search(iss.get("body") or "")
        if not m:
            continue
        date = m.group(1)
        index.setdefault(date, {"issue": iss["number"], "node_id": iss.get("id")})
    log(f"ipm-index: derived {len(index)} date→issue entries from GitHub")
    return index


def _attach_project_items(index):
    """Fill project_item_id on each entry by matching the issue's node_id to a
    Project V2 item's content id. Best-effort; skipped without a PAT."""
    if not HAS_PAT:
        return
    pid = get_project_id()
    if not pid:
        return
    node_to_item = {}
    cursor = None
    while True:
        q = ('query($id:ID!,$after:String){ node(id:$id){ ... on ProjectV2 { '
             'items(first:100, after:$after){ pageInfo{ hasNextPage endCursor } '
             'nodes { id content { ... on Issue { id } } } } } } }')
        args = ["api", "graphql", "-f", f"query={q}", "-f", f"id={pid}"]
        if cursor:
            args += ["-f", f"after={cursor}"]
        r = gh(args, check=False)
        if r.returncode != 0:
            return
        try:
            items = json.loads(r.stdout)["data"]["node"]["items"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return
        for it in items.get("nodes", []):
            content = it.get("content") or {}
            cid = content.get("id")
            if cid:
                node_to_item[cid] = it["id"]
        page = items.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            break
        cursor = page.get("endCursor")
    for entry in index.values():
        nid = entry.get("node_id")
        if nid in node_to_item:
            entry["project_item_id"] = node_to_item[nid]


def gh(args, check=True):
    env = {**os.environ, "GH_TOKEN": TOKEN}
    r = subprocess.run(["gh"] + args, capture_output=True, text=True, env=env)
    if check and r.returncode != 0:
        log(f"  ! gh {' '.join(args)} failed: {r.stderr.strip()}")
    return r


def extract_task_id(path):
    m = TASK_ID_RE.search(Path(path).name)
    return m.group(1) if m else None


def extract_ipm_date(path):
    m = IPM_FILE_RE.match(Path(path).name)
    return m.group(1) if m else None


def is_ipm_staging_stub(file_path):
    """True if the ipm-weekly.md file is still the /stage pre-IPM staging
    stub (candidates only, not yet committed). Mirrors the header-sniff
    `_ipm/current.sh` uses to exclude the same stub. Defaults to False on a
    read error rather than skipping a real file."""
    try:
        text = Path(file_path).read_text(encoding="utf-8")
    except OSError:
        return False
    return bool(_IPM_STAGING_RE.search(text))


def get_title(path):
    text = Path(path).read_text(encoding="utf-8")
    parts = text.split("---", 2)
    if text.startswith("---\n") and len(parts) >= 3:
        body = parts[2]
    else:
        body = text
    for line in body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return Path(path).stem


def get_status(path):
    return get_frontmatter(path).get("status")


def issue_body(file_path, dir_kind):
    permalink = f"https://github.com/{REPO}/blob/main/{file_path}"
    kind_note = {
        "TODO": "Active task — see file for the authoritative state.",
        "PARKING": "Parked task — not actionable now; revisited periodically.",
        "JOURNAL": "Closed task — historical record.",
    }.get(dir_kind, "")
    return f"""**Task file**: [{file_path}]({permalink})

{kind_note}

This Issue is a thin pointer to the task file (canonical source). State transitions sync automatically from file moves between `dev/TODO/`, `dev/PARKING/`, and `dev/JOURNAL/`. Body content is **not** synced — see the task file for the authoritative version.

---

Auto-managed by `.github/workflows/sync-tasks-to-issues.yml`. Manual edits may be overwritten."""


def ipm_issue_body(file_path, ipm_date):
    """Parallel to issue_body() — renders a thin-pointer body for an
    ipm-weekly.md file, with the hidden marker build_ipm_index() parses back
    to recover the date→issue mapping at runtime (no sidecar file)."""
    permalink = f"https://github.com/{REPO}/blob/main/{file_path}"
    return f"""**IPM file**: [{file_path}]({permalink})

This Issue is a thin pointer to the iteration's weekly-focus plan (canonical source). It surfaces the IPM doc on the Project's iteration view alongside that iteration's task issues.

---

Auto-managed by `.github/workflows/sync-tasks-to-issues.yml`. Manual edits may be overwritten.

<!-- ipm:{ipm_date} -->"""


def _create_issue(title, body):
    """Common create-issue mechanics shared by create_issue() (task files)
    and create_ipm_issue() (ipm-weekly files): POST then parse
    (number, node_id). Uses the REST API so we get the node_id back (needed
    for the Project V2 addProjectV2ItemById mutation)."""
    if DRY_RUN:
        return -1, None
    r = gh([
        "api", "-X", "POST", f"/repos/{REPO}/issues",
        "-f", f"title={title}",
        "-f", f"body={body}",
    ])
    if r.returncode != 0:
        return None, None
    try:
        data = json.loads(r.stdout)
        return data["number"], data["node_id"]
    except (json.JSONDecodeError, KeyError) as e:
        log(f"  ! could not parse issue creation response: {e}")
        return None, None


def create_issue(task_id, file_path, dir_kind):
    """Create an Issue and return (number, node_id)."""
    title = get_title(file_path)
    body = issue_body(file_path, dir_kind)
    log(f"  + create issue for {task_id} ({file_path})")
    return _create_issue(title, body)


def create_ipm_issue(ipm_date, file_path):
    """Create an Issue for a committed ipm-weekly.md file and return
    (number, node_id). Parallel to create_issue()."""
    title = get_title(file_path)
    body = ipm_issue_body(file_path, ipm_date)
    log(f"  + create IPM issue for {ipm_date} ({file_path})")
    return _create_issue(title, body)


def _norm_body(s):
    """Normalize an Issue body for comparison: unify line endings and strip
    surrounding whitespace, so a CRLF / trailing-newline difference between what
    GitHub stores and what issue_body() renders doesn't trigger a spurious edit."""
    return (s or "").replace("\r\n", "\n").strip()


def update_issue_body(num, file_path, dir_kind):
    """Rewrite Issue #num's body so the 'Task file' permalink points at the
    file's CURRENT location and kind-note.

    The body is written once at create_issue() and is otherwise never synced, so
    a TODO→JOURNAL (or TODO↔PARKING) move leaves the body linking to the old
    `blob/main/dev/TODO/…` path — a dead 404 link once the file has moved (the
    issue #937 symptom). This re-renders the body from the current path.

    Idempotent: reads the live body first and skips the edit when it already
    matches, so reconcile/backfill don't churn an edit on every heartbeat run.
    Best-effort: returns True only when an edit was actually applied."""
    if DRY_RUN or not num or num <= 0 or not file_path:
        return False
    new_body = issue_body(file_path, dir_kind)
    cur = gh(["issue", "view", str(num), "--repo", REPO, "--json", "body",
              "--jq", ".body"], check=False)
    if cur.returncode == 0 and _norm_body(cur.stdout) == _norm_body(new_body):
        return False
    log(f"  ~ update body for issue #{num} → {file_path} ({dir_kind})")
    r = gh(["issue", "edit", str(num), "--repo", REPO, "--body", new_body], check=False)
    return r.returncode == 0


def get_issue_node_id(num):
    """Look up an existing Issue's node_id (for backfilling Project membership
    when build_index could not supply one)."""
    r = gh(["api", f"/repos/{REPO}/issues/{num}"], check=False)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)["node_id"]
    except (json.JSONDecodeError, KeyError):
        return None


_PROJECT_ID_CACHE = None


def get_project_id():
    """Resolve Project V2 ID from owner+number. Cached. Returns None if PAT
    is missing, PROJECT_OWNER/PROJECT_NUMBER aren't configured, or the
    project can't be resolved."""
    global _PROJECT_ID_CACHE
    if _PROJECT_ID_CACHE is not None:
        return _PROJECT_ID_CACHE or None
    if not HAS_PAT:
        _PROJECT_ID_CACHE = ""
        return None
    if not PROJECT_OWNER or not PROJECT_NUMBER:
        log("  ! PROJECT_OWNER/PROJECT_NUMBER not configured — skipping Project V2 integration")
        _PROJECT_ID_CACHE = ""
        return None
    q = (
        'query($login:String!, $number:Int!) { '
        'organization(login:$login) { projectV2(number:$number) { id } } }'
    )
    r = gh([
        "api", "graphql",
        "-f", f"query={q}",
        "-f", f"login={PROJECT_OWNER}",
        "-F", f"number={PROJECT_NUMBER}",
    ], check=False)
    if r.returncode != 0:
        log(f"  ! could not resolve project id for {PROJECT_OWNER}/projects/{PROJECT_NUMBER}: {r.stderr.strip()[:200]}")
        _PROJECT_ID_CACHE = ""
        return None
    try:
        pid = json.loads(r.stdout)["data"]["organization"]["projectV2"]["id"]
        _PROJECT_ID_CACHE = pid
        return pid
    except (json.JSONDecodeError, KeyError, TypeError):
        _PROJECT_ID_CACHE = ""
        return None


def add_to_project(issue_node_id):
    """Add an Issue to Project V2. Idempotent — re-adding returns the existing
    item. Returns the projectItem id (or None on failure / skip)."""
    if DRY_RUN or not issue_node_id:
        return None
    pid = get_project_id()
    if not pid:
        return None
    mut = (
        'mutation($project:ID!, $content:ID!) { '
        'addProjectV2ItemById(input:{projectId:$project, contentId:$content}) '
        '{ item { id } } }'
    )
    r = gh([
        "api", "graphql",
        "-f", f"query={mut}",
        "-f", f"project={pid}",
        "-f", f"content={issue_node_id}",
    ], check=False)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)["data"]["addProjectV2ItemById"]["item"]["id"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


_PROJECT_FIELDS_CACHE = None


def get_project_fields():
    """Returns dict of field name → {id, type, options (for single_select), iterations}."""
    global _PROJECT_FIELDS_CACHE
    if _PROJECT_FIELDS_CACHE is not None:
        return _PROJECT_FIELDS_CACHE
    if not HAS_PAT:
        _PROJECT_FIELDS_CACHE = {}
        return {}
    pid = get_project_id()
    if not pid:
        _PROJECT_FIELDS_CACHE = {}
        return {}
    q = (
        'query($id:ID!) { node(id:$id) { ... on ProjectV2 { '
        'fields(first:50) { nodes { '
        '__typename '
        '... on ProjectV2Field { id name dataType } '
        '... on ProjectV2SingleSelectField { id name dataType options { id name } } '
        '... on ProjectV2IterationField { id name dataType configuration { '
        'iterations { id title startDate duration } '
        'completedIterations { id title startDate duration } } } '
        '} } } } }'
    )
    r = gh(["api", "graphql", "-f", f"query={q}", "-f", f"id={pid}"], check=False)
    if r.returncode != 0:
        log(f"  ! could not fetch project fields: {r.stderr.strip()[:200]}")
        _PROJECT_FIELDS_CACHE = {}
        return {}
    try:
        nodes = json.loads(r.stdout)["data"]["node"]["fields"]["nodes"]
    except (json.JSONDecodeError, KeyError, TypeError):
        _PROJECT_FIELDS_CACHE = {}
        return {}
    result = {}
    for f in nodes:
        if not f or "name" not in f:
            continue
        entry = {"id": f["id"], "type": f.get("__typename"), "dataType": f.get("dataType")}
        if f.get("__typename") == "ProjectV2SingleSelectField":
            entry["options"] = {opt["name"]: opt["id"] for opt in (f.get("options") or [])}
        elif f.get("__typename") == "ProjectV2IterationField":
            cfg = f.get("configuration") or {}
            iters = list(cfg.get("iterations") or []) + list(cfg.get("completedIterations") or [])
            entry["iterations"] = iters
        result[f["name"]] = entry
    _PROJECT_FIELDS_CACHE = result
    return result


def _parse_date(s):
    if not s:
        return None
    s = str(s).strip()
    try:
        return datetime.strptime(s[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def find_iteration_id(scheduled, iterations):
    """Find the iteration whose [startDate, startDate+duration days) contains
    the scheduled date. Returns iteration id or None."""
    target = _parse_date(scheduled)
    if not target:
        return None
    for it in iterations or []:
        start = _parse_date(it.get("startDate"))
        if not start:
            continue
        try:
            dur = int(it.get("duration") or 7)
        except (TypeError, ValueError):
            dur = 7
        if start <= target < start + timedelta(days=dur):
            return it["id"]
    return None


def journal_close_date(file_path):
    """Close-date for a CLOSED task = the YYYY-MM-DD prefix of its JOURNAL
    filename (dev/JOURNAL/YYYY-MM-DD-T<id>-<slug>.md). Used as the iteration
    fallback for completed tasks that never carried `scheduled`. Returns the
    date string (YYYY-MM-DD) or None when the filename has no date prefix."""
    m = re.match(r"(\d{4}-\d{2}-\d{2})-", Path(file_path).name)
    return m.group(1) if m else None


def status_to_option_id(status_text, options):
    """Map frontmatter status to Project Status option id. Handles direct
    match, 'Blocked by T...' → Blocked, 'Closed ...' → Done. Option-name
    lookup is case-insensitive on both sides so callers don't have to know
    the exact casing Project V2 returns."""
    if not status_text or not options:
        return None
    s = str(status_text).strip().lower()
    lower_opts = {name.lower(): oid for name, oid in options.items()}
    if s in lower_opts:
        return lower_opts[s]
    if s.startswith("blocked"):
        return lower_opts.get("blocked")
    if s.startswith("closed") or s.startswith("done"):
        return lower_opts.get("done")
    # Prose-suffixed status (e.g. "Coding — UNBLOCKED 2026-06-06: picked B"):
    # match the leading word against a known option, the same tolerance the
    # "blocked"/"closed" prefixes already get. Split on the first separator
    # (whitespace, em-dash, hyphen, colon, paren).
    head = re.split(r"[\s—:()-]", s, 1)[0]
    if head and head in lower_opts:
        return lower_opts[head]
    return None


def status_for_location(file_path, frontmatter_status):
    """Derive the Project Status from file location, falling back to
    frontmatter status. PARKING and JOURNAL override frontmatter; TODO
    respects frontmatter (Open/Design/Coding/Review/Blocked)."""
    kind = file_dir_kind(file_path)
    if kind == "PARKING":
        return "Parked"
    if kind == "JOURNAL":
        return "Done"
    return frontmatter_status


def _update_field(item_id, field_id, value_literal):
    """Generic field-update mutation. value_literal is the raw GraphQL input
    fragment (e.g., '{singleSelectOptionId: \"...\"}'). Returns True on success."""
    if DRY_RUN or not item_id or not field_id:
        return False
    pid = get_project_id()
    if not pid:
        return False
    mut = (
        'mutation { updateProjectV2ItemFieldValue(input: {'
        f'projectId: "{pid}", itemId: "{item_id}", fieldId: "{field_id}", '
        f'value: {value_literal}'
        '}) { projectV2Item { id } } }'
    )
    r = gh(["api", "graphql", "-f", f"query={mut}"], check=False)
    return r.returncode == 0


def update_single_select(item_id, field_id, option_id):
    return _update_field(item_id, field_id, f'{{singleSelectOptionId: "{option_id}"}}')


def update_iteration(item_id, field_id, iteration_id):
    return _update_field(item_id, field_id, f'{{iterationId: "{iteration_id}"}}')


def clear_field(item_id, field_id):
    """Clear a Project field value (e.g. remove a stale Iteration). Returns True
    on success. Mirror of _update_field but uses the clear mutation — there is
    no value literal to clear a field, so it needs its own mutation."""
    if DRY_RUN or not item_id or not field_id:
        return False
    pid = get_project_id()
    if not pid:
        return False
    mut = (
        'mutation { clearProjectV2ItemFieldValue(input: {'
        f'projectId: "{pid}", itemId: "{item_id}", fieldId: "{field_id}"'
        '}) { projectV2Item { id } } }'
    )
    r = gh(["api", "graphql", "-f", f"query={mut}"], check=False)
    return r.returncode == 0


def update_text(item_id, field_id, text):
    # json.dumps gives a properly-escaped string literal compatible with GraphQL
    return _update_field(item_id, field_id, f'{{text: {json.dumps(str(text))}}}')


def update_date(item_id, field_id, date_str):
    d = _parse_date(date_str)
    if not d:
        return False
    return _update_field(item_id, field_id, f'{{date: "{d.isoformat()}"}}')


# Scalar frontmatter keys this script consumes. Task files are human-authored
# and these values often carry prose containing an unquoted ": " (colon-space),
# which PyYAML reads as an attempted nested mapping and rejects with
# "mapping values are not allowed here". When full-document parsing fails we
# recover just these fields line-by-line so a single prose value no longer
# silently drops a task's Status + Iteration off the Project board.
_SCALAR_FM_KEYS = ("status", "scheduled", "estimation", "priority", "deadline",
                   "claimed_by", "claimed_role")
_FM_SCALAR_RE = {k: re.compile(rf"^{k}:[ \t]*(.*)$", re.MULTILINE) for k in _SCALAR_FM_KEYS}


_CLAIM_CC1_RE = re.compile(r"^cc1-([0-9a-f]{8}):[0-9a-f]{16}$")


def claim_display(claimed_by, claimed_role=None):
    """Board-facing rendering of a claimed_by value.

    The claimant id is opaque by design (T20260911-698434) — it used to be
    "<hostname>:<clone-path>", which was readable but published a machine name,
    an OS username and a filesystem path onto a board and into a public repo.
    A full "cc1-a1b2c3d4:9f8e7d6c5b4a3210" tells a human nothing extra over its
    first few characters, so shorten it and append the role, which is the part
    someone scanning the board actually wants ("was this the cron loop or a
    person?").

    Anything that is not the current shape — a legacy "<host>:<path>" claim, or
    a deliberate human assignment like "Alex" — passes through untouched, and an
    unclaimed task still renders as "" so the clear-to-empty contract holds.
    """
    raw = str(claimed_by or "").strip()
    if not raw:
        return ""
    role = str(claimed_role or "").strip()
    m = _CLAIM_CC1_RE.match(raw)
    if not m:
        return raw
    short = "cc1-" + m.group(1)[:6]
    return f"{short} ({role})" if role else short


def _lenient_scalars(block):
    """Line-based extraction of the known scalar keys from a frontmatter block.
    Robust against prose values containing an unquoted colon (invalid YAML).
    Strips one layer of matching surrounding quotes, as YAML would."""
    out = {}
    for key, rx in _FM_SCALAR_RE.items():
        m = rx.search(block)
        if not m:
            continue
        val = m.group(1).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if val:
            out[key] = val
    return out


def get_frontmatter(path):
    """Return frontmatter dict, or {} if absent. Tolerant of prose scalar
    values that contain an unquoted ": " (invalid YAML): on a parse error we
    log a warning and fall back to line-based extraction of the known scalar
    fields, rather than silently returning {} and blanking the board."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return {}
    if not text.startswith("---\n"):
        return {}
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}
    block = parts[1]
    try:
        meta = yaml.safe_load(block) or {}
        return meta if isinstance(meta, dict) else {}
    except yaml.YAMLError as e:
        scalars = _lenient_scalars(block)
        log(f"WARN: unparseable YAML frontmatter in {path}: {e}; "
            f"recovered {sorted(scalars)} via line-based fallback")
        return scalars


_STATUS_LINE_RE = re.compile(r"^- \*\*Status\*\*:\s*(.+)$")


def _status_from_text(text):
    """Extract status value from a task-file string — handles YAML frontmatter
    and legacy bullet format."""
    if text.startswith("---\n"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            try:
                meta = yaml.safe_load(parts[1]) or {}
                if isinstance(meta, dict):
                    return meta.get("status")
            except yaml.YAMLError:
                # Prose-colon (invalid YAML): try the line-based scalar reader
                # before falling through to legacy bullet-format parsing. A
                # malformed block isn't fatal — either fallback can recover the
                # status on files that carry it.
                status = _lenient_scalars(parts[1]).get("status")
                if status:
                    return status
    for line in text.splitlines():
        m = _STATUS_LINE_RE.match(line)
        if m:
            return m.group(1).strip()
    return None


def get_start_date(file_path):
    """Walk git log of this file (oldest first); return the YYYY-MM-DD of the
    first commit where status was non-'Open' (i.e., the task moved into
    active development). Falls back to None if always 'Open' or no history."""
    r = subprocess.run(
        ["git", "log", "--reverse", "--pretty=format:%H %aI", "--", file_path],
        capture_output=True, text=True, check=False
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    for line in r.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        sha, date = parts
        show = subprocess.run(
            ["git", "show", f"{sha}:{file_path}"],
            capture_output=True, text=True, check=False
        )
        if show.returncode != 0:
            continue
        status = _status_from_text(show.stdout)
        if status and status.strip().lower() != "open":
            return date[:10]
    return None


def extract_blockers(meta):
    """Collect blocker task IDs for the `Blocked by` Project field. Sources:
    the `blocked-by` / `blocked_by` frontmatter field (value may be a markdown
    link, so regex over it) and a `Blocked by T...` status string (the
    lifecycle.md convention). Returns comma-joined unique IDs in first-seen
    order, or '' if none."""
    ids = []
    bb = meta.get("blocked-by") or meta.get("blocked_by")
    if bb:
        ids += TASK_ID_RE.findall(str(bb))
    status = meta.get("status")
    if status and str(status).strip().lower().startswith("blocked"):
        ids += TASK_ID_RE.findall(str(status))
    seen = set()
    out = []
    for i in ids:
        if i not in seen:
            seen.add(i)
            out.append(i)
    return ", ".join(out)


def sync_fields(item_id, file_path, fields):
    """Push frontmatter values to Project fields for one item. Returns count
    of successful updates."""
    if DRY_RUN or not item_id:
        return 0
    meta = get_frontmatter(file_path)
    updates = 0

    # Status — derive from location (PARKING/JOURNAL override), then frontmatter
    sf = fields.get("Status")
    if sf:
        st = status_for_location(file_path, meta.get("status"))
        opt = status_to_option_id(st, sf.get("options") or {})
        if opt and update_single_select(item_id, sf["id"], opt):
            updates += 1

    # Blocked by — blocker task IDs from frontmatter (`blocked-by` field or a
    # `Blocked by T...` status). Always written (cleared to "" when none) so an
    # unblocked task never keeps a stale blocker on the board.
    bbf = fields.get("Blocked by")
    if bbf:
        if update_text(item_id, bbf["id"], extract_blockers(meta)):
            updates += 1

    # Claim lock — claimed_by is the on-main session lock (see
    # _session/task_claim.sh). Project it onto the same-named TEXT field,
    # always writing (clear-to-empty when unclaimed) so a released claim never
    # leaves a stale owner on the board — same clear-to-empty contract as
    # Blocked-by above. No-op when the board has no such column.
    for fm_key in ("claimed_by",):
        cf = fields.get(fm_key)
        if cf and update_text(item_id, cf["id"],
                              claim_display(meta.get(fm_key),
                                            meta.get("claimed_role"))):
            updates += 1

    # Iteration — mirrors `scheduled` for LIVE tasks: a TODO/PARKING task with no
    # `scheduled` is uncommitted backlog and must carry no iteration (no stale
    # leftovers). For CLOSED (JOURNAL) tasks the work is finished and its "when"
    # is known, so when `scheduled` is absent or unmapped we fall back to the
    # close-date (the dev/JOURNAL/YYYY-MM-DD- filename prefix) — otherwise the
    # ~90% of closed tasks that never carried `scheduled` show no iteration on
    # the board and drop out of the Iterations view's completed-work history.
    itf = fields.get("Iteration")
    if itf:
        iters = itf.get("iterations") or []
        sched = meta.get("scheduled")
        it_id = find_iteration_id(sched, iters) if sched else None
        if not it_id and file_dir_kind(file_path) == "JOURNAL":
            it_id = find_iteration_id(journal_close_date(file_path), iters)
        if it_id:
            if update_iteration(item_id, itf["id"], it_id):
                updates += 1
        elif clear_field(item_id, itf["id"]):
            updates += 1

    # Estimate — TEXT field
    ef = fields.get("Estimate")
    if ef and meta.get("estimation"):
        if update_text(item_id, ef["id"], meta["estimation"]):
            updates += 1

    # End date — DATE field, from `deadline`. Parse before calling update_date
    # so an unparseable deadline (e.g. "TBD") doesn't burn a no-op API call.
    edf = fields.get("End date")
    if edf and meta.get("deadline") and _parse_date(meta["deadline"]):
        if update_date(item_id, edf["id"], meta["deadline"]):
            updates += 1

    # Start date — DATE field, derived from git log
    sdf = fields.get("Start date")
    if sdf:
        sd = get_start_date(file_path)
        if sd and update_date(item_id, sdf["id"], sd):
            updates += 1

    return updates


# `gh issue close --reason` accepts only {completed | not planned | duplicate}.
# Internal callers use the underscore form "not_planned"; passing it through
# verbatim makes gh reject the call (`invalid argument "not_planned"`), which
# silently left completed/parked issues OPEN for days (T20260615-322892). Map to
# the accepted token here, in one place.
_GH_CLOSE_REASONS = {
    "completed": "completed",
    "not_planned": "not planned",
    "not planned": "not planned",
    "duplicate": "duplicate",
}

# Count close failures so a stuck-open issue surfaces as a non-zero run exit
# (main()) instead of being swallowed into a green "success" run.
_close_failures = 0


def close_issue(num, reason, comment=None):
    """Close an issue with a gh-accepted reason. Returns True on success; False
    if the reason is unknown or the close call failed — never swallows a failure
    (a stuck-open issue must be visible)."""
    global _close_failures
    gh_reason = _GH_CLOSE_REASONS.get(reason)
    if gh_reason is None:
        log(f"  ! close issue #{num}: unknown reason {reason!r} — not closing")
        _close_failures += 1
        return False
    log(f"  x close issue #{num} ({gh_reason})")
    if DRY_RUN:
        return True
    if comment:
        gh(["issue", "comment", str(num), "--repo", REPO, "--body", comment], check=False)
    r = gh(["issue", "close", str(num), "--repo", REPO, "--reason", gh_reason], check=False)
    if r.returncode != 0:
        log(f"  ! WARN: failed to close issue #{num} (reason '{gh_reason}'): {r.stderr.strip()}")
        _close_failures += 1
        return False
    return True


def reopen_issue(num, comment=None):
    log(f"  ^ reopen issue #{num}")
    if DRY_RUN:
        return
    if comment:
        gh(["issue", "comment", str(num), "--repo", REPO, "--body", comment])
    gh(["issue", "reopen", str(num), "--repo", REPO])


def add_label(num, label):
    if DRY_RUN:
        return
    gh(["issue", "edit", str(num), "--repo", REPO, "--add-label", label], check=False)


def remove_label(num, label):
    if DRY_RUN:
        return
    gh(["issue", "edit", str(num), "--repo", REPO, "--remove-label", label], check=False)


def issue_is_open(num):
    """Return True if GitHub issue #num is OPEN. Best-effort: False on error or
    a missing/synthetic number."""
    if not num or num <= 0:
        return False
    r = gh(["issue", "view", str(num), "--repo", REPO, "--json", "state",
            "--jq", ".state"], check=False)
    return r.returncode == 0 and r.stdout.strip().upper() == "OPEN"


def reconcile_issue_state(entry, kind):
    """Ensure a GitHub issue's open/closed state matches its file's folder.
    Catches orphans left when a move-sync failed (e.g. the 2026-05-26
    account-suspension outage): a JOURNAL/PARKING file whose issue stayed open,
    or a TODO file whose issue was closed. Guarded by issue_is_open so it never
    re-closes/re-opens needlessly. Returns the action taken, or None for a no-op."""
    num = entry.get("issue")
    if not num or num <= 0:
        return None
    open_ = issue_is_open(num)
    if kind == "JOURNAL" and open_:
        close_issue(num, reason="completed",
                    comment="reconcile: task file is in dev/JOURNAL/ (done) — closing stale-open issue.")
        return "closed-completed"
    if kind == "PARKING" and open_:
        add_label(num, PARKED_LABEL)
        close_issue(num, reason="not_planned",
                    comment="reconcile: task file is in dev/PARKING/ — closing stale-open issue.")
        return "closed-parked"
    if kind == "TODO" and not open_:
        remove_label(num, PARKED_LABEL)
        reopen_issue(num, comment="reconcile: task file is in dev/TODO/ — reopening stale-closed issue.")
        return "reopened"
    return None


def find_task_file(tid):
    """Locate a task's current .md by id across dev/{TODO,PARKING,JOURNAL}.
    Returns a posix path or None. Prefers TODO > PARKING > JOURNAL when
    (abnormally) present in more than one. Lets reconcile self-heal an index
    path left stale (e.g. an issue body whose permalink still points at the
    file's pre-move location)."""
    if not tid:
        return None
    for d in ("dev/TODO", "dev/PARKING", "dev/JOURNAL"):
        base = Path(d)
        if not base.is_dir():
            continue
        hits = sorted(base.glob(f"*{tid}*.md"))
        if hits:
            return hits[0].as_posix()
    return None


def file_dir_kind(path):
    """Return TODO | PARKING | JOURNAL | OTHER from a file path."""
    p = Path(path).as_posix()
    if p.startswith("dev/TODO/"):
        return "TODO"
    if p.startswith("dev/PARKING/"):
        return "PARKING"
    if p.startswith("dev/JOURNAL/"):
        return "JOURNAL"
    return "OTHER"


def _resolve_project_item_id(entry):
    """Resolve (and cache onto entry) the Project V2 item id for an issue
    entry, recovering node_id from the issue number if needed. Shared by
    ensure_ipm_on_project() and the per-line IPM sync handler — the IPM
    analogue of the node_id/project_item_id recovery _resync_fields_for()
    does for task entries."""
    item_id = entry.get("project_item_id")
    if item_id:
        return item_id
    node_id = entry.get("node_id")
    if not node_id and entry.get("issue"):
        node_id = get_issue_node_id(entry["issue"])
        if node_id:
            entry["node_id"] = node_id
    if not node_id:
        return None
    item_id = add_to_project(node_id)
    if item_id:
        entry["project_item_id"] = item_id
    return item_id


def sync_ipm_fields(item_id, ipm_date, fields):
    """Push the IPM's own Monday date to the Project Iteration field. Unlike
    sync_fields() (frontmatter-driven, task-only), an IPM issue has exactly
    one field to sync — Iteration — keyed on the file's own date rather than
    a `scheduled:` frontmatter value."""
    if DRY_RUN or not item_id:
        return 0
    itf = fields.get("Iteration")
    if not itf:
        return 0
    it_id = find_iteration_id(ipm_date, itf.get("iterations") or [])
    if it_id and update_iteration(item_id, itf["id"], it_id):
        return 1
    return 0


def ensure_ipm_on_project(ipm_map):
    """Idempotent reconcile for IPM issues: add each to Project V2 and sync
    its Iteration field. Parallel to ensure_on_project() but far simpler — no
    move/state lifecycle (IPM files live permanently in dev/JOURNAL/), no
    frontmatter fields beyond Iteration."""
    if DRY_RUN:
        log("ipm-project: skipping (dry-run)")
        return
    if not HAS_PAT:
        log("ipm-project: skipping (no PROJECT_PAT — Project V2 needs org-level Projects RW)")
        return
    pid = get_project_id()
    if not pid:
        log("ipm-project: skipping (could not resolve project id)")
        return
    fields = get_project_fields()
    added = 0
    field_updates = 0
    for date, entry in ipm_map.items():
        item_id = _resolve_project_item_id(entry)
        if not item_id:
            continue
        added += 1
        if fields:
            field_updates += sync_ipm_fields(item_id, date, fields)
    log(f"ipm-project: ensured {added}/{len(ipm_map)} IPM items in {PROJECT_OWNER}/projects/{PROJECT_NUMBER}")
    if fields:
        log(f"ipm-project: applied {field_updates} IPM field updates")


def mode_backfill(issue_map, ipm_map=None):
    """Create Issues for any current TODO/PARKING file not in the map, then
    ensure every mapped Issue is on Project V2. Also backfills committed
    ipm-weekly.md files in dev/JOURNAL/ into ipm_map (a separate index — see
    build_ipm_index()) — a /stage staging stub is skipped, not backfilled."""
    if ipm_map is None:
        ipm_map = {}
    created = 0
    for d in ("dev/TODO", "dev/PARKING"):
        if not Path(d).is_dir():
            continue
        for f in sorted(Path(d).glob("*.md")):
            tid = extract_task_id(f)
            if not tid:
                continue
            if tid in issue_map:
                continue
            kind = file_dir_kind(f)
            num, node_id = create_issue(tid, str(f), kind)
            if num is None:
                continue
            entry = {"issue": num, "path": str(f)}
            if node_id:
                entry["node_id"] = node_id
            issue_map[tid] = entry
            if kind == "PARKING" and num > 0:
                add_label(num, PARKED_LABEL)
                close_issue(num, reason="not_planned")
            created += 1
    log(f"backfill: {created} issues created")
    ensure_on_project(issue_map)

    ipm_created = 0
    journal = Path("dev/JOURNAL")
    if journal.is_dir():
        for f in sorted(journal.glob("*-ipm-weekly.md")):
            date = extract_ipm_date(f)
            if not date or date in ipm_map or is_ipm_staging_stub(f):
                continue
            num, node_id = create_ipm_issue(date, str(f))
            if num is None:
                continue
            entry = {"issue": num}
            if node_id:
                entry["node_id"] = node_id
            ipm_map[date] = entry
            ipm_created += 1
    log(f"backfill: {ipm_created} IPM issues created")
    ensure_ipm_on_project(ipm_map)


def ensure_on_project(issue_map):
    """Idempotently reconcile the whole board to the files. For every Issue in
    the index: re-discover the task's real file location (self-healing a
    path left stale by a failed move-sync), reconcile the issue's open/closed
    state from that folder (closing orphans), add it to Project V2, and sync
    frontmatter fields (Status, Iteration, Estimate, End date, Start date).

    Populates node_id and project_item_id in the map for entries missing them
    (legacy entries created before those fields were tracked). This is what
    `reconcile`/`backfill` run; unlike incremental `sync`, it does not rely on a
    git diff, so it repairs drift left behind when a push-triggered sync failed."""
    if DRY_RUN:
        log("project: skipping (dry-run)")
        return
    if not HAS_PAT:
        log("project: skipping (no PROJECT_PAT — Project V2 needs org-level Projects RW)")
        return
    pid = get_project_id()
    if not pid:
        log("project: skipping (could not resolve project id)")
        return
    fields = get_project_fields()
    if not fields:
        log("project: warning — could not fetch field schema; will add items but skip field-sync")
    added = 0
    field_updates = 0
    path_heals = 0
    state_fixes = 0
    body_fixes = 0
    for tid, entry in issue_map.items():
        # Self-heal a stale index path: a failed move-sync can leave
        # entry['path'] pointing at a folder the file has since left.
        actual = find_task_file(tid)
        if actual and actual != entry.get("path"):
            entry["path"] = actual
            path_heals += 1
        path = actual
        stale_path = entry.get("path")
        if not path and stale_path and Path(stale_path).exists():
            path = stale_path
        kind = file_dir_kind(path) if path else None
        # Reconcile the issue's open/closed state from the file's folder —
        # closes orphans whose move-sync failed. Uses the issue number, so it
        # runs independent of Project membership.
        if kind in ("TODO", "PARKING", "JOURNAL") and reconcile_issue_state(entry, kind):
            state_fixes += 1
        # Repair a stale body link from the file's current location (issue #937):
        # closed/moved Issues created before move-aware body sync still link to
        # their old dev/TODO/ path. Uses the issue number, so — like the state
        # reconcile above — it runs independent of Project membership and before
        # the node_id/project `continue`s below.
        if kind in ("TODO", "PARKING", "JOURNAL") and entry.get("issue") \
                and update_issue_body(entry["issue"], path, kind):
            body_fixes += 1
        node_id = entry.get("node_id")
        if not node_id and entry.get("issue"):
            node_id = get_issue_node_id(entry["issue"])
            if node_id:
                entry["node_id"] = node_id  # backfill the map
        if not node_id:
            continue
        item_id = add_to_project(node_id)
        if not item_id:
            continue
        entry["project_item_id"] = item_id
        added += 1
        if fields and path:
            field_updates += sync_fields(item_id, path, fields)
    log(f"project: ensured {added}/{len(issue_map)} items in {PROJECT_OWNER}/projects/{PROJECT_NUMBER}")
    log(f"project: healed {path_heals} stale path(s), reconciled {state_fixes} issue state(s), "
        f"repaired {body_fixes} stale body link(s)")
    if fields:
        log(f"project: applied {field_updates} field updates across items")


def _resync_fields_for(entry, path, fields):
    """Push current frontmatter+location to Project fields for one entry.
    Reuses `project_item_id` cached by build_index; if missing, recovers
    it via an idempotent add_to_project call. Returns count of field
    updates applied."""
    if not entry or not fields or not path:
        return 0
    item_id = entry.get("project_item_id")
    if not item_id:
        node_id = entry.get("node_id")
        if not node_id and entry.get("issue"):
            node_id = get_issue_node_id(entry["issue"])
            if node_id:
                entry["node_id"] = node_id
        if node_id:
            item_id = add_to_project(node_id)
            if item_id:
                entry["project_item_id"] = item_id
    if not item_id:
        return 0
    return sync_fields(item_id, path, fields)


def _apply_move(num, old_kind, new_kind, new, sha):
    """Apply the issue-state transition for a task-file move old_kind→new_kind.
    Shared by the git-detected rename (R) path and the D+A path (a rename git's
    -M missed because the completion commit also rewrote the body). Repoints the
    body link, then closes/reopens/labels per the transition. Returns 1 if a
    state transition fired, else 0 (e.g. a same-dir TODO→TODO slug rename)."""
    if new_kind in ("TODO", "PARKING", "JOURNAL"):
        update_issue_body(num, new, new_kind)
    if old_kind == "TODO" and new_kind == "JOURNAL":
        close_issue(num, reason="completed",
                    comment=f"Task moved to JOURNAL ({new}) in {sha}.")
        return 1
    if old_kind == "TODO" and new_kind == "PARKING":
        add_label(num, PARKED_LABEL)
        close_issue(num, reason="not_planned",
                    comment=f"Task moved to PARKING ({new}) in {sha}.")
        return 1
    if old_kind == "PARKING" and new_kind == "TODO":
        remove_label(num, PARKED_LABEL)
        reopen_issue(num, comment=f"Task moved back to TODO ({new}) in {sha}.")
        return 1
    if old_kind == "JOURNAL" and new_kind == "TODO":
        reopen_issue(num, comment=f"Task moved back to TODO from JOURNAL ({new}) in {sha}.")
        return 1
    if old_kind == "PARKING" and new_kind == "JOURNAL":
        remove_label(num, PARKED_LABEL)
        gh(["issue", "comment", str(num), "--repo", REPO,
            "--body", f"Task moved from PARKING to JOURNAL ({new}) in {sha}."], check=False)
        return 1
    return 0


def _sync_ipm_line(status, old, new, ipm_date, ipm_map, fields):
    """Handle one git-diff line for an ipm-weekly.md file. IPM files have a
    simpler lifecycle than task files — no TODO/PARKING/JOURNAL moves, just
    A (created, possibly still a /stage staging stub) and M (in-place edits:
    the 2a.5 commit that drops the staging marker and commits the iteration,
    or a later Tier-3 mid-week append). Returns (actions, field_updates)."""
    path = new or old
    if status == "D" or not path:
        # An IPM file is a permanent JOURNAL record; deletion is not part of
        # its normal lifecycle. No issue action here — closing at iteration
        # end is /retro's job (the design's resolved open question), not
        # sync.py's.
        return 0, 0
    if is_ipm_staging_stub(path):
        # Still a /stage candidates stub — not a committed IPM yet.
        return 0, 0
    entry = ipm_map.get(ipm_date)
    actions = 0
    if not entry:
        num, node_id = create_ipm_issue(ipm_date, path)
        if num is None:
            return 0, 0
        entry = {"issue": num}
        if node_id:
            entry["node_id"] = node_id
        ipm_map[ipm_date] = entry
        actions = 1
    item_id = _resolve_project_item_id(entry)
    field_updates = sync_ipm_fields(item_id, ipm_date, fields) if (item_id and fields) else 0
    return actions, field_updates


def mode_sync(issue_map, ipm_map=None):
    """React to file moves since HEAD~1."""
    if ipm_map is None:
        ipm_map = {}
    r = subprocess.run(
        ["git", "diff", "--name-status", "-M", "HEAD~1", "HEAD"],
        capture_output=True, text=True, check=True,
    )
    fields = get_project_fields() if (HAS_PAT and not DRY_RUN) else {}
    actions = 0
    field_updates = 0
    ipm_actions = 0
    ipm_field_updates = 0
    # Pre-index every Add destination by task-id. git's -M rename detection can
    # miss a move when the destination file's body was also rewritten (a
    # TODO→JOURNAL completion that appends the journal entry drops below the
    # similarity threshold), surfacing the move as a separate D + A sharing one
    # task-id. Pairing them lets the D handler apply the real transition instead
    # of a bare not_planned delete (T20260615-322892).
    added_dest = {}
    for _line in r.stdout.splitlines():
        _parts = _line.split("\t")
        if len(_parts) >= 2 and _parts[0] == "A":
            _atid = extract_task_id(_parts[1])
            if _atid:
                added_dest[_atid] = (file_dir_kind(_parts[1]), _parts[1])
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if not parts:
            continue
        status = parts[0]
        if status.startswith("R"):
            # rename: R{score}\told\tnew
            old, new = parts[1], parts[2]
        elif status in ("A", "M"):
            old, new = parts[1], parts[1]
        elif status == "D":
            old, new = parts[1], None
        else:
            continue

        # Skip files we don't care about
        relevant = (old and file_dir_kind(old) != "OTHER") or (new and file_dir_kind(new) != "OTHER")
        if not relevant:
            continue

        ipm_date = extract_ipm_date(new or old)
        if ipm_date:
            ia, ifu = _sync_ipm_line(status, old, new, ipm_date, ipm_map, fields)
            ipm_actions += ia
            ipm_field_updates += ifu
            continue

        tid = extract_task_id(new or old)
        if not tid:
            continue

        old_kind = file_dir_kind(old) if old else None
        new_kind = file_dir_kind(new) if new else None

        # Cases:
        # A: file added — create issue if in TODO/PARKING
        # D: file deleted — close issue (not_planned) if mapped
        # R: file renamed — handle transitions
        # M: file modified in place — resync Project fields (Status/Iteration/
        #    dates), never body. State transitions happen via moves (R), so M
        #    only refreshes field values from the edited frontmatter.

        if status == "A":
            if new_kind in ("TODO", "PARKING") and tid not in issue_map:
                num, node_id = create_issue(tid, new, new_kind)
                if num is not None:
                    entry = {"issue": num, "path": new}
                    if node_id:
                        entry["node_id"] = node_id
                    issue_map[tid] = entry
                    if node_id:
                        item_id = add_to_project(node_id)
                        if item_id:
                            entry["project_item_id"] = item_id
                    if new_kind == "PARKING" and num > 0:
                        add_label(num, PARKED_LABEL)
                        close_issue(num, reason="not_planned")
                    actions += 1
                    field_updates += _resync_fields_for(entry, new, fields)
        elif status == "D":
            entry = issue_map.get(tid)
            if entry:
                dest = added_dest.get(tid)
                if dest:
                    # git split a real move into D + A (its -M missed the rename
                    # because the destination body was also rewritten). Apply the
                    # true transition (e.g. TODO→JOURNAL = completed) instead of a
                    # bare not_planned delete.
                    dst_kind, dst_path = dest
                    sha = (os.environ.get("GITHUB_SHA") or "unknown")[:8]
                    issue_map[tid]["path"] = dst_path
                    actions += _apply_move(entry["issue"], file_dir_kind(old),
                                           dst_kind, dst_path, sha)
                    field_updates += _resync_fields_for(issue_map[tid], dst_path, fields)
                else:
                    close_issue(entry["issue"], reason="not_planned",
                                comment=f"Task file deleted from `{old}` in {os.environ.get('GITHUB_SHA', '')[:8]}.")
                    actions += 1
                    # Explicitly flip Status to "Done" since the file (frontmatter)
                    # is gone and sync_fields can't read it. Best-effort.
                    item_id = entry.get("project_item_id")
                    if not item_id and entry.get("node_id"):
                        item_id = add_to_project(entry["node_id"])
                        if item_id:
                            entry["project_item_id"] = item_id
                    if item_id and fields:
                        sf = fields.get("Status")
                        if sf:
                            opt = status_to_option_id("Done", sf.get("options") or {})
                            if opt and update_single_select(item_id, sf["id"], opt):
                                field_updates += 1
        elif status.startswith("R"):
            entry = issue_map.get(tid)
            num = entry["issue"] if entry else None
            sha = (os.environ.get("GITHUB_SHA") or "unknown")[:8]
            if not num:
                # No prior Issue — create one for the destination if appropriate
                if new_kind in ("TODO", "PARKING"):
                    num, node_id = create_issue(tid, new, new_kind)
                    if num is not None:
                        entry = {"issue": num, "path": new}
                        if node_id:
                            entry["node_id"] = node_id
                        issue_map[tid] = entry
                        if node_id:
                            item_id = add_to_project(node_id)
                            if item_id:
                                entry["project_item_id"] = item_id
                        if new_kind == "PARKING" and num > 0:
                            add_label(num, PARKED_LABEL)
                            close_issue(num, reason="not_planned",
                                        comment=f"Task moved to PARKING ({new}) in {sha}.")
                        actions += 1
                        field_updates += _resync_fields_for(entry, new, fields)
                continue
            issue_map[tid]["path"] = new
            # Apply the move transition — body repoint (keeps the "Task file"
            # link off the dead dev/TODO/ path, issue #937) + close/reopen/label.
            # Shared with the D+A path; see _apply_move. Combinations it doesn't
            # match (e.g. a same-dir TODO→TODO slug rename) are state no-ops.
            actions += _apply_move(num, old_kind, new_kind, new, sha)
            # Push current Project field values for the new location.
            field_updates += _resync_fields_for(entry, new, fields)
        elif status == "M":
            # In-place frontmatter edit (e.g. IPM rewriting `scheduled:`, or a
            # status change within dev/TODO). Refresh field values only; M
            # never creates/closes/transitions issues.
            entry = issue_map.get(tid)
            if entry and new_kind in ("TODO", "PARKING"):
                field_updates += _resync_fields_for(entry, new, fields)

    log(f"sync: {actions} actions taken")
    if fields:
        log(f"sync: applied {field_updates} field updates across items")
    log(f"ipm-sync: {ipm_actions} IPM actions taken")
    if fields:
        log(f"ipm-sync: applied {ipm_field_updates} IPM field updates")


def main():
    global _close_failures
    _close_failures = 0
    log(f"mode: {MODE} | repo: {REPO} | dry-run: {DRY_RUN}")
    issue_map = build_index()
    ipm_map = build_ipm_index()
    if MODE == "backfill":
        mode_backfill(issue_map, ipm_map)
    elif MODE == "reconcile":
        ensure_on_project(issue_map)
        ensure_ipm_on_project(ipm_map)
    elif MODE in ("sync", "dry-run"):
        mode_sync(issue_map, ipm_map)
    else:
        log(f"unknown mode: {MODE}")
        sys.exit(2)
    log(f"map: {len(issue_map)} entries (derived, not persisted)")
    log(f"ipm-map: {len(ipm_map)} entries (derived, not persisted)")
    if _close_failures:
        log(f"sync: FAILED — {_close_failures} issue close(s) did not succeed; "
            "failing the run so the stuck-open issue(s) are visible, not swallowed")
        sys.exit(1)


if __name__ == "__main__":
    main()
