#!/usr/bin/env python3
"""task-query: filter and group dev/TODO tasks by time / place / person / event
(T20261114-380745, part 2 of the task dimensions from T20261114-352324).

Read-only. Order inside every group is queue.md order (tasks missing from the
queue follow, by file name); a `when` never reorders anything. Aliases are
printed as stored and never resolved to a real name or address.

Usage: task-query.sh [filters] [--group-by when|place|person|type] [--json]
  --when today|tomorrow|week|overdue|<date>   comma list = union. `week` is today..today+6.
                                              A when..when-end window matches if it overlaps.
  --place <slug>      task lists that place
  --here              place absent (anywhere) or in the `here:` list of the profile file
  --person <alias>    task lists that person
  --waiting-on <alias|any>   status `Blocked by person:<alias>`
  --type <t>          chore|feature|bug|event|research|spike|rca|support|other
  --all               include Done / Parked / Revisit (default: open only)
  --json              machine-readable output
Env: TODO_QUEUE_DIR (default .), SESSION_TODAY=YYYY-MM-DD or CCXP_RITUAL_NOW
(epoch seconds or ISO) with CCXP_RITUAL_TZ for the clock, CCXP_ROUTINES_PROFILE_FILE
(default ${CLAUDE_CONFIG_DIR:-~/.claude}/ccxp-routines.yml) for `here:`.
Exit: 0 ok (also when nothing matches), 2 bad usage.
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")
TYPES = {"chore", "feature", "bug", "event", "research", "spike", "rca", "support", "other"}
CLOSED = ("done", "closed", "revisit", "parked")
QUEUE_RE = re.compile(r"^- \[([^\]]+)\]\(([^)]+)\): (.*)$")


def usage(msg=None):
    if msg:
        print("task-query: " + msg, file=sys.stderr)
    print("usage: task-query.sh [--when W] [--place P|--here] [--person A] "
          "[--waiting-on A|any] [--type T] [--group-by G] [--all] [--json]", file=sys.stderr)
    sys.exit(2)


def today_date():
    s = os.environ.get("SESSION_TODAY")
    if s:
        try:
            return datetime.date.fromisoformat(s)
        except ValueError:
            usage("bad SESSION_TODAY: " + s)
    now = os.environ.get("CCXP_RITUAL_NOW")
    tz = None
    if os.environ.get("CCXP_RITUAL_TZ"):
        try:
            import zoneinfo
            tz = zoneinfo.ZoneInfo(os.environ["CCXP_RITUAL_TZ"])
        except Exception:
            tz = None
    if now:
        if now.isdigit():
            return datetime.datetime.fromtimestamp(int(now), tz).date()
        try:
            dt = datetime.datetime.fromisoformat(now.replace("Z", "+00:00"))
            if dt.tzinfo is not None and tz is not None:
                dt = dt.astimezone(tz)
            return dt.date()
        except ValueError:
            pass
    return datetime.datetime.now(tz).date()


def frontmatter(path):
    keys = {}
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return keys, ""
    h1 = ""
    if lines and lines[0].strip() == "---":
        for ln in lines[1:]:
            if ln.strip() == "---":
                break
            m = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", ln)
            if m:
                v = re.sub(r"\s+#.*$", "", m.group(2)).strip()
                keys[m.group(1)] = v
    for ln in lines:
        if ln.startswith("# "):
            h1 = ln[2:].strip()
            break
    return keys, h1


def as_list(v):
    v = (v or "").strip()
    if not v:
        return []
    if v.startswith("["):
        v = v[1:].rstrip("]")
    return [i.strip().strip("'\"") for i in v.split(",") if i.strip().strip("'\"")]


def parse_date(v):
    if not (v and DATE_RE.match(v)):
        return None
    try:
        return datetime.date.fromisoformat(v[:10])
    except ValueError:
        return None   # impossible date: treated as no date, never a crash (lint reports it)


def status_open(status):
    head = re.split(r"[\s—-]", status.strip().lower(), maxsplit=1)[0] if status.strip() else ""
    return head not in CLOSED


def waiting_on(status):
    if not re.match(r"^blocked\b", status.strip(), re.I):
        return []
    return [m.group(1).rstrip(",;.") for m in re.finditer(r"\bperson:(\S+)", status)]


def last_edit(path):
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", os.path.basename(path)],
                             cwd=os.path.dirname(path) or ".", capture_output=True, text=True, timeout=10).stdout.strip()
        if DATE_RE.match(out):
            return out
    except Exception:
        pass
    try:
        return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    except OSError:
        return ""


def here_places():
    prof = os.environ.get("CCXP_ROUTINES_PROFILE_FILE") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "ccxp-routines.yml")
    try:
        lines = open(prof, encoding="utf-8").read().split("\n")
    except OSError:
        return []
    for i, ln in enumerate(lines):
        m = re.match(r"^here:\s*(.*)$", ln)
        if not m:
            continue
        rest = re.sub(r"\s+#.*$", "", m.group(1)).strip()
        if rest:
            return as_list(rest)
        out = []
        for nxt in lines[i + 1:]:
            mm = re.match(r"^\s+-\s*(\S.*?)\s*(#.*)?$", nxt)
            if not mm:
                break
            out.append(mm.group(1).strip("'\""))
        return out
    return []


def load_tasks(root):
    tdir = os.path.join(root, "dev", "TODO")
    order, titles = [], {}
    q = os.path.join(tdir, "queue.md")
    if os.path.isfile(q):
        for ln in open(q, encoding="utf-8").read().split("\n"):
            m = QUEUE_RE.match(ln)
            if m and m.group(2) not in order:
                order.append(m.group(2))
                titles[m.group(2)] = m.group(3)
    for f in sorted(glob.glob(os.path.join(tdir, "T*.md"))):
        b = os.path.basename(f)
        if b not in order:
            order.append(b)
    tasks = []
    for b in order:
        path = os.path.join(tdir, b)
        if not os.path.isfile(path):
            continue
        k, h1 = frontmatter(path)
        idm = re.match(r"^(T\d+-\d+)", b)
        if not idm:
            continue
        title = titles.get(b) or re.sub(r"^T\d+-\d+:\s*", "", h1)
        tasks.append({
            "id": idm.group(1), "title": title, "status": k.get("status", ""),
            "type": re.sub(r"['\"]", "", k.get("type", "")).strip().lower(),
            "when": k.get("when", "").strip("'\""), "when_end": k.get("when-end", "").strip("'\""),
            "place": as_list(k.get("place")), "person": as_list(k.get("person")),
            "waiting_on": waiting_on(k.get("status", "")), "deadline": k.get("deadline", ""),
            "_path": path,
        })
    return tasks


def when_matches(t, tokens, today):
    start = parse_date(t["when"])
    if start is None:
        return False
    end = max(parse_date(t["when_end"]) or start, start)
    for tok in tokens:
        if tok == "today":
            lo = hi = today
        elif tok == "tomorrow":
            lo = hi = today + datetime.timedelta(days=1)
        elif tok == "week":
            lo, hi = today, today + datetime.timedelta(days=6)
        elif tok == "overdue":
            if end < today:
                return True
            continue
        else:
            d = parse_date(tok)
            if d is None:
                usage("bad --when value: " + tok)
            lo = hi = d
        if start <= hi and end >= lo:
            return True
    return False


def group_keys(t, by):
    if by == "when":
        return [t["when"][:10]] if t["when"] else [""]
    if by == "place":
        return t["place"] or [""]
    if by == "person":
        return t["person"] or [""]
    return [t["type"]]


def main(argv):
    f = {"when": [], "place": None, "here": False, "person": None, "waiting": None,
         "type": None, "group": None, "all": False, "json": False}
    i = 0

    def val():
        nonlocal i
        if i + 1 >= len(argv) or argv[i + 1].startswith("--") or not argv[i + 1].strip():
            usage(argv[i] + " needs a value")
        i += 1
        return argv[i]
    while i < len(argv):
        a = argv[i]
        if a == "--when":
            f["when"] += [x.strip().lower() for x in val().split(",") if x.strip()]
        elif a == "--place":
            f["place"] = val()
        elif a == "--here":
            f["here"] = True
        elif a == "--person":
            f["person"] = val()
        elif a == "--waiting-on":
            f["waiting"] = val()
        elif a == "--type":
            f["type"] = val().lower()
            if f["type"] not in TYPES:
                usage("bad --type value: " + f["type"])
        elif a == "--group-by":
            f["group"] = val()
            if f["group"] not in ("when", "place", "person", "type"):
                usage("bad --group-by value: " + f["group"])
        elif a == "--all":
            f["all"] = True
        elif a == "--open":
            pass
        elif a == "--json":
            f["json"] = True
        else:
            usage("unknown argument: " + a)
        i += 1

    for tok in f["when"]:
        if tok not in ("today", "tomorrow", "week", "overdue") and parse_date(tok) is None:
            usage("bad --when value: " + tok)
    today = today_date()
    here = here_places() if f["here"] else []
    out = []
    for t in load_tasks(os.environ.get("TODO_QUEUE_DIR", ".")):
        if not f["all"] and not status_open(t["status"]):
            continue
        if f["when"] and not when_matches(t, f["when"], today):
            continue
        if f["place"] and f["place"] not in t["place"]:
            continue
        if f["here"] and t["place"] and not set(t["place"]) & set(here):
            continue
        if f["person"] and f["person"] not in t["person"]:
            continue
        if f["waiting"]:
            if f["waiting"] == "any":
                if not t["waiting_on"]:
                    continue
            elif f["waiting"] not in t["waiting_on"]:
                continue
        if f["type"] and t["type"] != f["type"]:
            continue
        t["last_edit"] = last_edit(t["_path"])
        le = parse_date(t["last_edit"])
        t["age_days"] = (today - le).days if le else None
        out.append(t)
    for t in out:
        del t["_path"]
    if f["type"] == "event" and not f["group"]:
        out.sort(key=lambda t: t["when"] or "9999")   # stable: queue order within a date

    groups = None
    if f["group"]:
        buckets = {}
        for t in out:
            for key in group_keys(t, f["group"]):
                buckets.setdefault(key, []).append(t)
        groups = [{"key": k or None, "tasks": buckets[k]} for k in sorted(buckets, key=lambda k: (k == "", k))]

    if f["json"]:
        doc = {"today": today.isoformat(), "count": len(out), "tasks": out}
        if groups is not None:
            doc["group_by"] = f["group"]
            doc["groups"] = groups
        print(json.dumps(doc, ensure_ascii=False))
        return 0

    def line(t):
        bits = [t["id"], t["status"] or "-"]
        if t["when"]:
            bits.append("when=" + t["when"] + ("/" + t["when_end"] if t["when_end"] else ""))
        if t["place"]:
            bits.append("place=" + ",".join(t["place"]))
        if t["person"]:
            bits.append("person=" + ",".join(t["person"]))
        if t["type"]:
            bits.append("type=" + t["type"])
        return "  ".join(bits) + "  " + t["title"]
    if not out:
        print("(no matching tasks)")
    elif groups is None:
        for t in out:
            print(line(t))
    else:
        for g in groups:
            print("## " + (g["key"] or "(none)"))
            for t in g["tasks"]:
                print(line(t))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
