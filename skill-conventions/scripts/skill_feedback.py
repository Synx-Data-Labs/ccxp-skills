#!/usr/bin/env python3
"""Log and track real-use feedback on a skill — the input side of the
novice→master loop (skill-conventions/SKILL.md §10).

Every time a skill misbehaves in real use (the user corrects it, it fires
when it shouldn't, it misses a step), log one line. An open item blocks
L4 Master; it closes only when codified as an eval case that reproduces it,
so the same mistake can never silently come back.

Usage:
  skill_feedback.py add SKILL KIND "NOTE"    KIND: correction|misfire|miss|slow
  skill_feedback.py list [SKILL] [--all]     open items (or all)
  skill_feedback.py codify ID EVAL_ID        close an item via an eval case
  skill_feedback.py dismiss ID "REASON"      close without an eval (not a bug)

Log: dev/quality/skill-feedback.jsonl (override with SKILL_FEEDBACK_LOG).
"""
import datetime
import json
import os
import sys
from pathlib import Path

KINDS = ("correction", "misfire", "miss", "slow")


def log_path():
    default = Path(__file__).resolve().parents[2] / "dev" / "quality" / \
        "skill-feedback.jsonl"
    return Path(os.environ.get("SKILL_FEEDBACK_LOG", default))


def load():
    p = log_path()
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()
            if l.strip()]


def save(items):
    p = log_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(json.dumps(i) + "\n" for i in items),
                 encoding="utf-8")


def add(skill, kind, note):
    if kind not in KINDS:
        raise SystemExit(f"KIND must be one of {', '.join(KINDS)}")
    items = load()
    today = datetime.date.today().isoformat()
    item = {"id": f"F{len(items) + 1:04d}", "date": today, "skill": skill,
            "kind": kind, "note": note, "status": "open"}
    save(items + [item])
    print(f"{item['id']} logged for {skill} ({kind})")


def close(fid, status, **fields):
    items = load()
    for i in items:
        if i["id"] == fid:
            i.update(status=status, closed=datetime.date.today().isoformat(),
                     **fields)
            save(items)
            print(f"{fid} → {status}")
            return
    raise SystemExit(f"no feedback item {fid}")


def list_items(skill=None, show_all=False):
    for i in load():
        if (skill and i["skill"] != skill) or \
                (not show_all and i["status"] != "open"):
            continue
        print(f"{i['id']}  {i['date']}  {i['skill']:<20} {i['kind']:<10} "
              f"{i['status']:<9} {i['note']}")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "add" and len(rest) == 3:
        add(*rest)
    elif cmd == "list":
        names = [a for a in rest if not a.startswith("--")]
        list_items(names[0] if names else None, "--all" in rest)
    elif cmd == "codify" and len(rest) == 2:
        close(rest[0], "codified", eval_id=rest[1])
    elif cmd == "dismiss" and len(rest) == 2:
        close(rest[0], "dismissed", reason=rest[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
