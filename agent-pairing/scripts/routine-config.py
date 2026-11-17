#!/usr/bin/env python3
"""routine-config.py: merge and lint the routine config layers (T20261114-144275).

  routine-config.py --default F [--tracked F] [--profile F] [--skills-root DIR] (rows | check | show NAME)

Layers merge by routine name, later wins; dicts deep-merge, lists and scalars replace.
  rows   TSV of enabled routines (declaration order) for routine-due.sh; problems go to stderr (record+warn)
  check  print every problem as "<file>[:<line>]: <message>"; exit 1 when there is one
  show   the merged routine as key: value lines
A routine whose override is invalid keeps its previous (built-in) definition; a file that does not parse
is skipped whole. YAML: PyYAML (line numbers, duplicate-name detection), else `yq -o=json` (file only).
"""
import json
import os
import re
import subprocess
import sys

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
ROUTINE_KEYS = {"description", "enabled", "schedule", "steps", "on_failure", "report", "tz", "also_claims", "allow", "scope"}
SCHEDULE_KEYS = {"every", "at", "days", "once_per", "not_before", "not_after"}
TOP_KEYS = {"routines", "here", "routines-file"}
HHMM = re.compile(r"([01]\d|2[0-3]):[0-5]\d")
EVERY = re.compile(r"([1-9]\d*)([smhd])")
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
UNIT = {"s": 1, "m": 60, "h": 3600, "d": 86400}

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only where PyYAML is absent
    yaml = None


class Problem(Exception):
    pass


def load(path):
    """-> (data, lines) where lines maps 'routines.<name>' / top key to a 1-based line; raises Problem."""
    try:
        return _load(path)
    except Problem:
        raise
    except Exception as exc:  # unreadable, not UTF-8, unhashable keys...: skip the file, never crash the run
        raise Problem("cannot read: %s: %s" % (type(exc).__name__, exc))


def _load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = {}
    if yaml is not None:
        class Loader(yaml.SafeLoader):
            pass
        try:
            node = yaml.compose(text, Loader=Loader)
            if node is not None:
                if not isinstance(node, yaml.MappingNode):
                    raise Problem("top level must be a mapping")
                seen = set()
                for k, v in node.value:
                    lines[k.value] = k.start_mark.line + 1
                    if k.value in seen:
                        raise Problem("duplicate key '%s'" % k.value, k.start_mark.line + 1)
                    seen.add(k.value)
                    if k.value == "routines" and isinstance(v, yaml.MappingNode):
                        rseen = set()
                        for rk, _ in v.value:
                            lines["routines." + str(rk.value)] = rk.start_mark.line + 1
                            if rk.value in rseen:
                                raise Problem("duplicate routine name '%s'" % rk.value, rk.start_mark.line + 1)
                            rseen.add(rk.value)
            data = yaml.load(text, Loader=Loader)
        except yaml.YAMLError as exc:
            mark = getattr(exc, "problem_mark", None)
            raise Problem("not valid YAML: %s" % getattr(exc, "problem", exc), mark.line + 1 if mark else None)
    else:
        try:
            out = subprocess.run(["yq", "-o=json", "."], input=text, capture_output=True, text=True, check=True).stdout
            data = json.loads(out)
        except (OSError, subprocess.CalledProcessError, ValueError) as exc:
            raise Problem("cannot read YAML (need PyYAML or yq): %s" % exc)
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise Problem("top level must be a mapping")
    return data, lines


def deep_merge(a, b, path=()):
    """dicts merge key by key; None deletes a key; a new schedule `every` replaces an old `at` and vice versa."""
    if not isinstance(b, dict):
        return b
    if not isinstance(a, dict):
        a = {}
    out = dict(a)
    if path == ("schedule",):
        if "every" in b and "at" not in b:
            out.pop("at", None)
        if "at" in b and "every" not in b:
            out.pop("every", None)
    for k, v in b.items():
        if v is None:
            out.pop(k, None)
        else:
            out[k] = deep_merge(a.get(k), v, path + (k,)) if isinstance(v, dict) else v
    return out


def tz_known(tz):
    try:
        from zoneinfo import ZoneInfo
        ZoneInfo(tz)
        return True
    except ImportError:
        return True  # cannot check
    except Exception:
        return False


def skill_exists(name, root):
    if not isinstance(name, str) or not name.strip():
        return False
    n = name.strip().lstrip("/")
    if ":" in n:
        prefix, n = n.split(":", 1)
        if prefix != "ccxp-skills":
            return True  # another plugin's skill: cannot be checked from here
    return bool(n) and os.path.isfile(os.path.join(root, n, "SKILL.md"))


def validate(name, r, root):
    """-> list of messages for one merged routine."""
    errs = []
    if not isinstance(r, dict):
        return ["routine '%s' must be a mapping" % name]
    for k in r:
        if k not in ROUTINE_KEYS:
            errs.append("routine '%s': unknown key '%s'" % (name, k))
    if "enabled" in r and not isinstance(r["enabled"], bool):
        errs.append("routine '%s': enabled must be true or false" % name)
    steps = r.get("steps")
    if not isinstance(steps, list) or not steps:
        errs.append("routine '%s': steps must be a non-empty list" % name)
    else:
        for i, st in enumerate(steps):
            if not isinstance(st, dict) or not set(st) <= {"skill", "args"} or "skill" not in st:
                errs.append("routine '%s': step %d must be {skill: ..., args: ...}" % (name, i + 1))
            elif not skill_exists(st["skill"], root):
                errs.append("routine '%s': unknown skill '%s'" % (name, st["skill"]))
    sch = r.get("schedule", {})
    if not isinstance(sch, dict):
        errs.append("routine '%s': schedule must be a mapping" % name)
        sch = {}
    for k in sch:
        if k not in SCHEDULE_KEYS:
            errs.append("routine '%s': unknown schedule key '%s'" % (name, k))
    if "every" in sch and "at" in sch:
        errs.append("routine '%s': schedule takes every or at, not both" % name)
    if "every" in sch and not (isinstance(sch["every"], str) and EVERY.fullmatch(sch["every"])):
        errs.append("routine '%s': bad every '%s' (use 5m, 2h, 1d)" % (name, sch["every"]))
    for k in ("at", "not_before", "not_after"):
        if k in sch and not (isinstance(sch[k], str) and HHMM.fullmatch(sch[k])):
            errs.append("routine '%s': bad %s %r (a quoted \"HH:MM\"; unquoted 10:30 parses as the integer 630)" % (name, k, sch[k]))
    d = sch.get("days", "daily")
    if not (d in ("daily", "weekdays") or (isinstance(d, list) and d and all(x in DAYS for x in d))):
        errs.append("routine '%s': bad days %r (daily, weekdays or a list of mon..sun)" % (name, d))
    if "once_per" in sch and sch["once_per"] not in ("day", "week"):
        errs.append("routine '%s': once_per must be day or week" % name)
    if sch.get("once_per") == "week" and isinstance(d, list) and all(x in DAYS for x in d) and {"sun", "mon"} <= set(d) and len(set(d)) < 7:
        errs.append("routine '%s': a once_per week window cannot wrap from sun to mon" % name)
    if r.get("on_failure", "stop") not in ("stop", "continue"):
        errs.append("routine '%s': on_failure must be stop or continue" % name)
    if r.get("report", "journal") not in ("slack", "journal", "none"):
        errs.append("routine '%s': report must be slack, journal or none" % name)
    if r.get("scope", "repo") not in ("repo", "any"):
        errs.append("routine '%s': scope must be repo or any" % name)
    for k in ("also_claims", "allow"):
        if k in r and not (isinstance(r[k], list) and all(isinstance(x, str) for x in r[k])):
            errs.append("routine '%s': %s must be a list of names" % (name, k))
    if isinstance(r.get("also_claims"), list):
        for x in r["also_claims"]:
            if isinstance(x, str) and (not NAME.fullmatch(x) or x == name):
                errs.append("routine '%s': bad also_claims entry '%s'" % (name, x))
    nb, na = sch.get("not_before"), sch.get("not_after")
    lim = [v for v in (sch.get("at"), nb) if isinstance(v, str) and HHMM.fullmatch(v)]
    if isinstance(na, str) and HHMM.fullmatch(na) and any(v > na for v in lim):
        errs.append("routine '%s': at/not_before is later than not_after (the routine would never be due)" % name)
    if "tz" in r and not (isinstance(r["tz"], str) and re.fullmatch(r"[A-Za-z0-9_+./-]+", r["tz"]) and tz_known(r["tz"])):
        errs.append("routine '%s': bad or unknown tz %r" % (name, r["tz"]))
    return errs


def resolve(args):
    probs = []  # (file, line, message)
    merged = {}
    top_here = None

    def layer(path, label, is_profile=False):
        nonlocal top_here
        if not path or not os.path.isfile(path):
            return None
        try:
            data, lines = load(path)
        except Problem as exc:
            probs.append((path, exc.args[1] if len(exc.args) > 1 else None, exc.args[0] + "; file skipped"))
            return None
        for k in list(data):
            if not isinstance(k, str):
                probs.append((path, None, "non-string top-level key %r" % (k,)))
                del data[k]
                continue
            if k not in TOP_KEYS or (k == "routines-file" and not is_profile):
                probs.append((path, lines.get(k), "unknown top-level key '%s'" % k))
        if "here" in data:
            h = data["here"]
            if isinstance(h, list) and all(isinstance(x, str) for x in h):
                top_here = h
            else:
                probs.append((path, lines.get("here"), "here must be a list of place slugs"))
        rs = data.get("routines", {})
        if rs is None:
            rs = {}
        if not isinstance(rs, dict):
            probs.append((path, lines.get("routines"), "routines must be a mapping"))
            return data
        for name, entry in rs.items():
            if not isinstance(name, str) or not NAME.fullmatch(name):
                probs.append((path, None, "bad routine name %r (letters, digits, _ . -; quote names like yes/no/on)" % (name,)))
                continue
            line = lines.get("routines." + name)
            if not isinstance(entry, dict):
                probs.append((path, line, "routine '%s' must be a mapping; keeping previous definition" % name))
                continue
            entry = dict(entry)
            if "allow" in entry and not is_profile:
                probs.append((path, line, "routine '%s': allow is honored only from the profile file; ignored" % name))
                del entry["allow"]
            try:
                cand = deep_merge(merged.get(name, {}), entry)
                errs = validate(name, cand, args["skills_root"])
                json.dumps(cand, default=str)  # a recursive alias fails here, not later in show
            except (Exception, RecursionError) as exc:  # a malformed value must not take every routine down
                errs = ["routine '%s': cannot validate (%s)" % (name, type(exc).__name__)]
            if errs:
                for e in errs:
                    probs.append((path, line, e + ("; keeping previous definition" if name in merged else "; routine dropped")))
                continue
            merged[name] = cand
        return data

    layer(args["default"], "default")
    prof = None
    if args.get("profile") and os.path.isfile(args["profile"]):
        # the profile may point the tracked layer elsewhere (routines-file:)
        try:
            prof = load(args["profile"])[0]
        except Problem:
            prof = None
    tracked = args.get("tracked")
    if isinstance(prof, dict) and isinstance(prof.get("routines-file"), str):
        tracked = os.path.expanduser(prof["routines-file"])
    layer(tracked, "tracked")
    layer(args.get("profile"), "profile", True)
    return merged, probs, top_here


def days_dows(sch):
    d = sch.get("days", "daily")
    if d == "daily":
        return [1, 2, 3, 4, 5, 6, 7]
    if d == "weekdays":
        return [1, 2, 3, 4, 5]
    return sorted({DAYS.index(x) + 1 for x in d})


def rows(merged):
    for name, r in merged.items():
        if r.get("enabled", True) is False:
            continue
        sch = r.get("schedule", {})
        kind, every = "at", 0
        if "every" in sch:
            m = EVERY.fullmatch(sch["every"])
            kind, every = "every", int(m.group(1)) * UNIT[m.group(2)]
        once = sch.get("once_per", "day")
        f = [name, kind, sch.get("at", "-"), str(every), ",".join(map(str, days_dows(sch))), once,
             sch.get("not_before", "-"), sch.get("not_after", "-"), r.get("tz", "-"), r.get("scope", "repo"),
             ",".join(r.get("also_claims", [])) or "-"]
        print("\t".join(f))


def main(argv):
    args = {"default": None, "tracked": None, "profile": None,
            "skills_root": os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))}
    i = 0
    rest = []
    while i < len(argv):
        a = argv[i]
        if a in ("--default", "--tracked", "--profile", "--skills-root"):
            if i + 1 >= len(argv):
                print("routine-config: %s needs a value" % a, file=sys.stderr)
                return 2
            args[a[2:].replace("-", "_")] = argv[i + 1]
            i += 2
        else:
            rest.append(a)
            i += 1
    if not rest:
        print("usage: routine-config.py [--default F --tracked F --profile F --skills-root D] rows|all|check|show NAME", file=sys.stderr)
        return 2
    merged, probs, _here = resolve(args)
    mode = rest[0]
    if mode == "check":
        for f, ln, msg in probs:
            print("%s%s: %s" % (f, ":%d" % ln if ln else "", msg))
        return 1 if probs else 0
    for f, ln, msg in probs:
        print("routine-due: warning: %s%s: %s" % (f, ":%d" % ln if ln else "", msg), file=sys.stderr)
    if mode == "rows":
        rows(merged)
        return 0
    if mode == "all":
        # every routine, disabled ones included: name, enabled, schedule (for /routine list)
        for name, r in merged.items():
            print("%s\t%s\t%s" % (name, "false" if r.get("enabled", True) is False else "true",
                                  json.dumps(r.get("schedule", {}), default=str, sort_keys=True)))
        return 0
    if mode == "show":
        r = merged.get(rest[1] if len(rest) > 1 else "")
        if r is None:
            print("routine-due: unknown routine '%s'" % (rest[1] if len(rest) > 1 else ""), file=sys.stderr)
            return 3
        for k, v in r.items():
            print("%s: %s" % (k, json.dumps(v, default=str)))
        return 0
    print("routine-config: unknown mode '%s'" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
