#!/usr/bin/env python3
"""run-routine.py: run records and exit-code arithmetic for /routine (T20261114-400715).

Called by run-routine.sh, which supplies the record dir (RR_DIR), the merged routine text from
`routine-due.sh show` (RR_SHOW) and the claim state. Verbs:
  plan                          TSV of the steps: index, skill, args
  begin KEY                     write a fresh `running` record (attempt = previous attempt + 1)
  step KEY IDX STATUS [NOTE]    record one step; print `continue` or `stop`
  finish KEY [SUMMARY]          roll up the run; print `status=.. claim=done|release|capped|none attempt=N`
  attempts KEY                  print the attempt count; exit 1 when the retry cap is reached
  last                          print the newest record of the routine
Records hold step outcomes and a one-line summary only; every free-text field is one line, capped at 200 characters.
"""
import json
import os
import re
import sys
import time

RR_DIR = os.environ.get("RR_DIR", "")
NAME = os.environ.get("RR_NAME", "")
OUTCOMES = ("ok", "nothing-to-do", "failed", "needs-human", "skipped")
MAX_ATTEMPTS = 4  # one first run plus the 3 retries a day that part 1's design allows
KEY_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}|every|manual-\d+)$")


def die(msg, code=2):
    print("run-routine: " + msg, file=sys.stderr)
    sys.exit(code)


def definition():
    d = {}
    for line in os.environ.get("RR_SHOW", "").splitlines():
        k, _, v = line.partition(": ")
        try:
            d[k] = json.loads(v)
        except ValueError:
            d[k] = v
    return d


def oneline(text):
    return re.sub(r"\s+", " ", text or "").strip()[:200]


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def path(key):
    if not KEY_RE.fullmatch(key):
        die("bad key '%s' (use the key claim printed, or omit it for a manual run)" % key)
    return os.path.join(RR_DIR, "%s-%s.json" % (NAME, key))


def load(key):
    try:
        with open(path(key)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save(key, rec):
    os.makedirs(RR_DIR, exist_ok=True)
    p = path(key)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f, indent=2)
        f.write("\n")
    os.replace(tmp, p)


def steps_of(d):
    steps = d.get("steps")
    if not isinstance(steps, list) or not steps:
        die("routine '%s' has no steps" % NAME, 3)
    return steps


def rollup(steps):
    out = [s["status"] for s in steps]
    ran = [o for o in out if o != "skipped"]
    if "failed" in out:
        # failed = nothing succeeded and nothing was skipped; any mix, or a skipped tail, is partial
        if "skipped" in out or any(o in ("ok", "nothing-to-do", "needs-human") for o in out):
            return "partial"
        return "failed"
    if "needs-human" in out:
        return "needs-human"
    return "ok" if ran else "failed"


def main(argv):
    if len(argv) < 1:
        die("usage: run-routine.py VERB ...")
    verb, a = argv[0], argv[1:]
    d = definition()
    if verb == "plan":
        for i, st in enumerate(steps_of(d), 1):
            print("%d\t%s\t%s" % (i, st.get("skill", ""), st.get("args", "")))
        return 0
    if verb == "last":
        best = None
        try:
            names = os.listdir(RR_DIR)
        except OSError:
            names = []
        for fn in names:
            if fn.startswith(NAME + "-") and fn.endswith(".json"):
                p = os.path.join(RR_DIR, fn)
                try:
                    with open(p) as f:
                        rec = json.load(f)
                except (OSError, ValueError):
                    continue
                if rec.get("routine") != NAME:
                    continue
                stamp = (rec.get("finished") or rec.get("started") or "", fn)
                if best is None or stamp > best[0]:
                    best = (stamp, rec)
        if best is None:
            die("no run record for '%s'" % NAME, 3)
        print(json.dumps(best[1], indent=2))
        return 0
    if not a:
        die("%s needs a key" % verb)
    key = a[0]
    if verb == "attempts":
        rec = load(key)
        n = rec.get("attempt", 0) if rec else 0
        print(n)
        # an every: routine has one constant key and no per-day claim, so it has no cap
        return 1 if n >= MAX_ATTEMPTS and key != "every" else 0
    if verb == "begin":
        prev = load(key)
        steps = [{"step": i, "skill": st.get("skill", ""), "status": "pending", "started": None, "finished": None, "note": ""}
                 for i, st in enumerate(steps_of(d), 1)]
        rec = {"routine": NAME, "key": key, "attempt": 1 if key == "every" else (prev.get("attempt", 0) if prev else 0) + 1,
               "status": "running", "started": now(), "finished": None,
               "on_failure": d.get("on_failure", "stop"), "report": d.get("report", "journal"),
               "summary": "", "claim": "none", "steps": steps}
        save(key, rec)
        print(path(key))
        return 0
    rec = load(key)
    if rec is None:
        die("no record for %s-%s: run `begin` first" % (NAME, key), 3)
    if verb == "step":
        if len(a) < 3:
            die("step needs KEY INDEX STATUS [NOTE]")
        idx, status = a[1], a[2]
        if status not in OUTCOMES[:4]:
            die("bad outcome '%s' (ok, nothing-to-do, failed, needs-human)" % status)
        if not idx.isdigit() or not 1 <= int(idx) <= len(rec["steps"]):
            die("bad step index '%s'" % idx)
        st = rec["steps"][int(idx) - 1]
        st.update(status=status, started=st["started"] or now(), finished=now(), note=oneline(a[3] if len(a) > 3 else ""))
        save(key, rec)
        stop = status != "ok" and status != "nothing-to-do" and rec["on_failure"] == "stop"
        print("stop" if stop else "continue")
        return 0
    if verb == "finish":
        all_ran = all(s["status"] != "pending" for s in rec["steps"])
        for s in rec["steps"]:
            if s["status"] == "pending":
                s["status"] = "skipped"
        status = rollup(rec["steps"])
        rec.update(status=status, finished=now(), summary=oneline(a[1] if len(a) > 1 else ""))
        if key == "every" or key.startswith("manual-"):
            claim = "none" if key.startswith("manual-") else None
        else:
            claim = None
        if claim is None:
            failed = status == "failed" or any(s["status"] == "failed" for s in rec["steps"])
            if not failed:
                claim = "done"  # ok, nothing-to-do and needs-human (reported once, never retried)
            elif rec["on_failure"] == "continue" and all_ran:
                claim = "done"  # a flaky step does not re-fire the whole routine
            else:
                claim = "capped" if rec["attempt"] >= MAX_ATTEMPTS and key != "every" else "release"
        rec["claim"] = claim
        save(key, rec)
        print("status=%s claim=%s attempt=%d" % (status, claim, rec["attempt"]))
        return 0
    die("unknown verb '%s'" % verb)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
