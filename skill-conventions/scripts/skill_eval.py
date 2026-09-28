#!/usr/bin/env python3
"""Run a skill's behavior evals (<skill>/evals/evals.json) and grade them
with deterministic, script-checked assertions — no LLM judge.

The model's run is stochastic; the GRADE is not: each assertion is a regex /
file check over the run's stream-json transcript and working dir, and a
case's verdict is its pass count over N runs against a fixed threshold.

Usage:
  skill_eval.py SKILL [--runs N] [--case ID] [--model M] [--record]
  skill_eval.py --grade TRANSCRIPT --evals EVALS_JSON --case ID [--workdir D]

--record appends a summary line to dev/quality/skill-evals.jsonl (read by
skill_score.py's maturity ladder). --grade re-grades a saved transcript
offline — how the grader itself is unit-tested.

evals.json:
  {"skill_name": "todo", "evals": [{
     "id": "next-picks-top", "prompt": "/todo next",
     "fixture": "fixtures/basic",          # optional, copied as the cwd
     "runs": 3, "max_turns": 15,           # optional
     "allowed_tools": ["Read", "Bash"],    # optional, see DEFAULT_TOOLS
     "assertions": [
       {"type": "skill_invoked", "skill": "todo"},
       {"type": "command_ran", "pattern": "todo/scripts/todo-next\\.sh"},
       {"type": "command_not_ran", "pattern": "gh pr merge"},
       {"type": "output_matches", "pattern": "T\\d{8}-\\d{6}"},
       {"type": "file_matches", "path": "dev/TODO/queue.md",
        "pattern": "^1\\. T20260101"}]}]}

Assertion types: skill_invoked, skill_not_invoked, command_ran,
command_not_ran, command_succeeded (ran AND never errored), tool_called, tool_not_called, output_matches,
output_not_matches, file_exists, file_absent, file_matches.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PASS_THRESHOLD = 0.9
DEFAULT_RUNS = 3
# Evals run unattended: never hand them credentials that can mutate GitHub
# or post to Slack. Cases that need network must stub it in their fixture.
SCRUB_ENV = ("GH_TOKEN", "GITHUB_TOKEN", "SESSION_TOKEN", "PROJECT_PAT")
SCRUB_PREFIX = ("SLACK_",)
DEFAULT_TOOLS = ["Read", "Glob", "Grep", "Skill", "Bash", "Write", "Edit"]


# --- transcript parsing -------------------------------------------------------

def parse_transcript(lines):
    """stream-json lines -> {"tools": [(name, input)], "failed": [input],
    "output": str}. "failed" holds the inputs of tool calls whose result
    came back is_error (e.g. a script path that doesn't resolve)."""
    tools, ids, failed, output = [], {}, [], ""
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        content = ev.get("message", {}).get("content", []) \
            if isinstance(ev.get("message"), dict) else []
        if not isinstance(content, list):
            content = []
        if ev.get("type") == "assistant":
            for block in content:
                if block.get("type") == "tool_use":
                    call = (block.get("name", ""), block.get("input") or {})
                    tools.append(call)
                    ids[block.get("id")] = call
                elif block.get("type") == "text":
                    output += block.get("text", "") + "\n"
        elif ev.get("type") == "user":
            for block in content:
                if block.get("type") == "tool_result" and \
                        block.get("is_error") and block.get("tool_use_id") in ids:
                    failed.append(ids[block["tool_use_id"]][1])
        elif ev.get("type") == "result" and ev.get("result"):
            output += str(ev["result"])
    return {"tools": tools, "failed": failed, "output": output}


def skills_invoked(run, prompt=""):
    # A "/name args" prompt is expanded by the CLI before the model runs, so
    # it never shows up as a Skill tool call in the transcript.
    slash = re.match(r"^/([\w:.-]+)", prompt.strip())
    return ([slash.group(1)] if slash else []) + \
        [i.get("skill", "") for n, i in run["tools"] if n == "Skill"]


def commands(run):
    return [i.get("command", "") for n, i in run["tools"] if n == "Bash"]


# --- grading --------------------------------------------------------------------

def _skill_match(names, skill):
    # Plugin skills are namespaced ("ccxp-skills:todo").
    return any(re.search(rf"(^|:){re.escape(skill)}$", n) for n in names)


def check(assertion, run, workdir, prompt=""):
    """Return (passed: bool, evidence: str) for one assertion."""
    t = assertion["type"]
    pat = assertion.get("pattern", "")
    rx = re.compile(pat, re.M) if pat else None
    if t in ("skill_invoked", "skill_not_invoked"):
        names = skills_invoked(run, prompt)
        hit = _skill_match(names, assertion["skill"])
        return hit == (t == "skill_invoked"), f"skills: {names}"
    if t in ("command_ran", "command_not_ran"):
        hits = [c for c in commands(run) if rx.search(c)]
        return bool(hits) == (t == "command_ran"), \
            f"matching: {hits[:3]}" if hits else "no matching command"
    if t == "command_succeeded":
        hits = [c for c in commands(run) if rx.search(c)]
        bad = [i.get("command", "") for i in run.get("failed", [])
               if rx.search(i.get("command", ""))]
        return bool(hits) and not bad, \
            f"failed: {bad[:2]}" if bad else f"ran: {hits[:2]}"
    if t in ("tool_called", "tool_not_called"):
        hit = any(n == assertion["tool"] for n, _ in run["tools"])
        return hit == (t == "tool_called"), \
            f"tools: {sorted({n for n, _ in run['tools']})}"
    if t in ("output_matches", "output_not_matches"):
        m = rx.search(run["output"])
        return bool(m) == (t == "output_matches"), \
            f"matched: {m.group(0)[:80]!r}" if m else "no match"
    path = Path(workdir or ".") / assertion.get("path", "")
    if t == "file_exists":
        return path.exists(), str(path)
    if t == "file_absent":
        return not path.exists(), str(path)
    if t == "file_matches":
        if not path.is_file():
            return False, f"missing: {path}"
        m = rx.search(path.read_text(encoding="utf-8", errors="replace"))
        return bool(m), f"matched: {m.group(0)[:80]!r}" if m else "no match"
    raise ValueError(f"unknown assertion type: {t}")


def grade(case, run, workdir):
    results = []
    for a in case["assertions"]:
        ok, evidence = check(a, run, workdir, case.get("prompt", ""))
        results.append({"text": a.get("text") or json.dumps(a),
                        "passed": ok, "evidence": evidence})
    return results


# --- running --------------------------------------------------------------------

def run_case(case, evals_dir, model=None):
    """Execute one run of a case in a throwaway dir; return (run, workdir)."""
    workdir = Path(tempfile.mkdtemp(prefix="skill-eval-"))
    if case.get("fixture"):
        shutil.copytree(evals_dir / case["fixture"], workdir,
                        dirs_exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=workdir, check=False)
    env = {k: v for k, v in os.environ.items()
           if k not in SCRUB_ENV and not k.startswith(SCRUB_PREFIX)}
    cmd = ["claude", "-p", case["prompt"], "--output-format", "stream-json",
           "--verbose", "--plugin-dir", str(REPO),
           "--permission-mode", "dontAsk",
           "--max-turns", str(case.get("max_turns", 15)),
           "--allowedTools", *case.get("allowed_tools", DEFAULT_TOOLS)]
    if model:
        cmd += ["--model", model]
    proc = subprocess.run(cmd, cwd=workdir, env=env, capture_output=True,
                          text=True, timeout=case.get("timeout", 600))
    (workdir / ".eval-transcript.jsonl").write_text(proc.stdout)
    return parse_transcript(proc.stdout.splitlines()), workdir


def run_skill(skill, runs=None, only=None, model=None):
    evals_file = REPO / skill / "evals" / "evals.json"
    spec = json.loads(evals_file.read_text(encoding="utf-8"))
    report = []
    for case in spec["evals"]:
        if only and case["id"] != only:
            continue
        n = runs or case.get("runs", DEFAULT_RUNS)
        passed, last = 0, []
        for i in range(n):
            run, workdir = run_case(case, evals_file.parent, model)
            last = grade(case, run, workdir)
            ok = all(r["passed"] for r in last)
            passed += ok
            print(f"  {case['id']} run {i + 1}/{n}: "
                  f"{'PASS' if ok else 'FAIL'}  ({workdir})")
            for r in last:
                if not r["passed"]:
                    print(f"      ✗ {r['text']} — {r['evidence']}")
        report.append({"id": case["id"], "passed_runs": passed, "runs": n,
                       "pass": passed / n >= PASS_THRESHOLD})
    return report


def summarize(skill, report, model):
    total = sum(c["runs"] for c in report)
    rate = sum(c["passed_runs"] for c in report) / total if total else 0
    sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO,
                         capture_output=True, text=True).stdout.strip()
    return {"date": datetime.date.today().isoformat(), "skill": skill,
            "sha": sha, "model": model, "pass_rate": round(rate, 3),
            "cases": report}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("skill", nargs="?")
    ap.add_argument("--runs", type=int)
    ap.add_argument("--case")
    ap.add_argument("--model")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--grade", metavar="TRANSCRIPT")
    ap.add_argument("--evals", metavar="EVALS_JSON")
    ap.add_argument("--workdir")
    a = ap.parse_args(argv)

    if a.grade:
        spec = json.loads(Path(a.evals).read_text(encoding="utf-8"))
        case = next(c for c in spec["evals"] if c["id"] == a.case)
        run = parse_transcript(
            Path(a.grade).read_text(encoding="utf-8").splitlines())
        results = grade(case, run, a.workdir)
        print(json.dumps(results, indent=2))
        return 0 if all(r["passed"] for r in results) else 1

    if not a.skill:
        ap.error("SKILL is required unless --grade is given")
    report = run_skill(a.skill, a.runs, a.case, a.model)
    summary = summarize(a.skill, report, a.model)
    print(json.dumps(summary, indent=2))
    if a.record and not a.case:
        log = REPO / "dev" / "quality" / "skill-evals.jsonl"
        with log.open("a", encoding="utf-8") as f:
            f.write(json.dumps(summary) + "\n")
    return 0 if all(c["pass"] for c in report) else 1


if __name__ == "__main__":
    sys.exit(main())
