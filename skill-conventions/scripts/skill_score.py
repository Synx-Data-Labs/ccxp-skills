#!/usr/bin/env python3
"""Deterministic 0-100 structural score + maturity level for every SKILL.md.

Static analysis only — same input, same score, no LLM. It grades the
conventions in skill-conventions/SKILL.md that a script CAN check (trigger
phrasing, context-window cost, broken refs, changelog noise, structure,
test coverage of bundled scripts). Judgment (is the workflow right?) is
out of scope; behavior is graded by skill_eval.py against evals/evals.json.

Usage:
  skill_score.py [--repo DIR] [--json] [SKILL ...]      score skills
  skill_score.py --check BASELINE [--repo DIR]          ratchet gate
  skill_score.py --write-baseline BASELINE [--repo DIR] (re)write baseline

--check exits 1 if any skill scores below its baseline entry (a regression)
or a new skill scores below NEW_SKILL_FLOOR. Raising a score never fails;
re-run --write-baseline to lock the gain in.
"""
import argparse
import json
import re
import sys
from pathlib import Path

import yaml

NEW_SKILL_FLOOR = 70
# Context-window budget for the SKILL.md body (bytes; ~4 bytes/token).
SIZE_FULL_BYTES = 8 * 1024    # full marks at or under ~2k tokens
SIZE_ZERO_BYTES = 32 * 1024   # zero marks at or over ~8k tokens
PARA_WORDS = 60               # same threshold as lint_paragraphs.py
TASK_ID_RE = re.compile(r"\bT\d{8}-\d{6}\b")
LINK_RE = re.compile(r"\]\(([^)\s#]+)(?:#[^)]*)?\)")
PATH_RE = re.compile(
    r"`((?:\.\.?/)?[\w.-]+(?:/[\w.-]+)+\.(?:sh|py|md|json|js|ts|css))`")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
LIST_RE = re.compile(r"^\s*([-*+|>]|\d+[.)])\s*")
WORKFLOW_HEADINGS = ("workflow", "conventions", "phase", "steps", "usage",
                     "quick start", "process", "procedure")


def split_frontmatter(text):
    """Return (frontmatter dict or None, body str)."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end == -1:
        return None, text
    try:
        fm = yaml.safe_load(text[4:end]) or {}
    except yaml.YAMLError:
        fm = None
    return (fm if isinstance(fm, dict) else None), text[end + 4:]


def prose_lines(body):
    """Yield (lineno, line) outside fenced code blocks."""
    in_fence = False
    for n, line in enumerate(body.splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield n, line


def long_paragraphs(body):
    count, words = 0, 0
    for _, line in list(prose_lines(body)) + [(0, "")]:
        if not line.strip() or line.lstrip().startswith("#") \
                or LIST_RE.match(line):
            if words > PARA_WORDS:
                count += 1
            words = 0
        else:
            words += len(line.split())
    return count


def in_repo_path(ref, skill_dir, repo):
    """True if a backticked path claims to live in THIS repo (a sibling skill,
    a _lib, or the skill's own scripts/references/...). Consumer-repo runtime
    paths (dev/..., .claude/..., .github/...) are not checkable here."""
    if ref.startswith("../"):
        return True
    first = ref.split("/", 1)[0]
    if first in ("dev", "node_modules") or first.startswith("."):
        return False
    return (repo / first).is_dir() or (skill_dir / first).is_dir()


def broken_refs(skill_dir, repo, body):
    """Markdown links and in-repo backticked paths that resolve neither from
    the skill dir nor the repo root. Placeholders (<x>, {x}, YYYY, *) and
    bare-word link targets are skipped."""
    prose = "\n".join(l for _, l in prose_lines(body))
    refs = {r for r in LINK_RE.findall(prose) if "/" in r or "." in r}
    refs |= {r for r in PATH_RE.findall(prose)
             if in_repo_path(r, skill_dir, repo)}
    broken = []
    for ref in sorted(refs):
        if re.match(r"^[a-z]+:", ref) or re.search(r"[<>{}*$]|YYYY", ref):
            continue
        if not any((base / ref).exists() for base in (skill_dir, repo)):
            broken.append(ref)
    return broken


def untested_scripts(skill_dir, repo):
    scripts = [p for p in (skill_dir / "scripts").glob("*")
               if p.suffix in (".sh", ".py") and not p.name.startswith("test_")]
    if not scripts:
        return [], 0
    corpus = ""
    for t in list((repo / "tests").glob("*.bats")) + \
            list(repo.glob("**/test_*.py")) + list(skill_dir.glob("tests/*")):
        if t.is_file():
            corpus += t.read_text(encoding="utf-8", errors="replace")
    # Python tests `import lint_tasks` (stem); bats tests call `x.sh` (name).
    def token(p):
        return p.stem if p.suffix == ".py" else p.name
    return [p.name for p in scripts if token(p) not in corpus], len(scripts)


def score_skill(skill_dir, repo):
    skill_dir, repo = Path(skill_dir), Path(repo)
    text = (skill_dir / "SKILL.md").read_text(encoding="utf-8")
    fm, body = split_frontmatter(text)
    fm_ok = fm is not None
    fm = fm or {}
    desc = str(fm.get("description") or "").strip()
    heads = [l.lstrip("#").strip().lower()
             for _, l in prose_lines(body) if re.match(r"^##\s", l)]
    size = len(body.encode("utf-8"))
    task_ids = len(TASK_ID_RE.findall(body))
    broken = broken_refs(skill_dir, repo, body)
    paras = long_paragraphs(body)
    untested, n_scripts = untested_scripts(skill_dir, repo)
    has_hint = "argument-hint" in fm

    checks = {}

    def add(name, pts, max_pts, detail=""):
        checks[name] = {"points": round(max(0, pts)), "max": max_pts,
                        "detail": detail}

    add("frontmatter", 10 if fm_ok and fm.get("name") == skill_dir.name
        and desc else 0, 10,
        "" if fm_ok else "missing/invalid YAML frontmatter")
    add("trigger", (10 if desc.lower().startswith("use when") else 0)
        + (5 if 40 <= len(desc) <= 500 else 0), 15,
        f"{len(desc)} chars; starts 'Use when': "
        f"{desc.lower().startswith('use when')}")
    add("invocation", (3 if has_hint else 0)
        + (2 if "disable-model-invocation" in fm else 0), 5,
        "argument-hint + explicit disable-model-invocation")
    frac = (SIZE_ZERO_BYTES - size) / (SIZE_ZERO_BYTES - SIZE_FULL_BYTES)
    add("size", 25 * min(1, max(0, frac)), 25,
        f"{size} bytes (~{size // 4} tokens), {len(body.splitlines())} lines")
    add("refs", 15 - 5 * len(broken), 15,
        ", ".join(broken) if broken else "all resolve")
    add("changelog_noise", 10 - max(0, task_ids - 2), 10,
        f"{task_ids} task-ID mentions (history belongs in dev/JOURNAL)")
    add("structure", (5 if not has_hint or any("argument" in h for h in heads)
                      else 0)
        + (5 if any(h.startswith(WORKFLOW_HEADINGS) or
                    any(w in h for w in WORKFLOW_HEADINGS) for h in heads)
           else 0), 10, "## Argument (if argument-hint) + ## Workflow/Conventions")
    add("prose_density", 5 - paras, 5,
        f"{paras} paragraphs over {PARA_WORDS} words")
    add("script_tests", 5 if not n_scripts else
        5 * (n_scripts - len(untested)) / n_scripts, 5,
        ("untested: " + ", ".join(untested)) if untested else
        f"{n_scripts} script(s), all referenced by a test")

    score = sum(c["points"] for c in checks.values())
    return {"skill": skill_dir.name, "score": score,
            "level": maturity(skill_dir, repo, score), "checks": checks}


# --- maturity ladder (see skill-conventions/SKILL.md §10) -------------------

LEVELS = ["L0 Draft", "L1 Novice", "L2 Apprentice", "L3 Practitioner",
          "L4 Master"]


def eval_cases(skill_dir):
    f = Path(skill_dir) / "evals" / "evals.json"
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [e for e in data.get("evals", []) if e.get("assertions")]


def read_jsonl(path):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def maturity(skill_dir, repo, score):
    name = Path(skill_dir).name
    q = Path(repo) / "dev" / "quality"
    if score < 60:
        return LEVELS[0]
    if len(eval_cases(skill_dir)) < 3:
        return LEVELS[1]
    runs = [r for r in read_jsonl(q / "skill-evals.jsonl")
            if r.get("skill") == name]
    if not runs or runs[-1].get("pass_rate", 0) < 0.9:
        return LEVELS[2]
    open_fb = [f for f in read_jsonl(q / "skill-feedback.jsonl")
               if f.get("skill") == name and f.get("status") == "open"]
    if score < 85 or open_fb or len(runs) < 3 or \
            any(r.get("pass_rate", 0) < 0.9 for r in runs[-3:]):
        return LEVELS[3]
    return LEVELS[4]


# --- CLI ---------------------------------------------------------------------

def iter_skills(repo, names=None):
    repo = Path(repo)
    dirs = sorted(p.parent for p in repo.glob("*/SKILL.md"))
    if names:
        dirs = [d for d in dirs if d.name in names]
    return dirs


def render(results):
    cols = list(results[0]["checks"]) if results else []
    short = {c: c[:6] for c in cols}
    out = ["| skill | score | level | " + " | ".join(short[c] for c in cols)
           + " |", "|---|---:|---|" + "---:|" * len(cols)]
    for r in sorted(results, key=lambda r: r["score"]):
        out.append(f"| {r['skill']} | {r['score']} | {r['level']} | " +
                   " | ".join(f"{r['checks'][c]['points']}/"
                              f"{r['checks'][c]['max']}" for c in cols) + " |")
    mean = sum(r["score"] for r in results) / max(1, len(results))
    out.append(f"\n{len(results)} skills, mean score {mean:.1f}")
    return "\n".join(out)


def check_baseline(results, baseline):
    failures = []
    for r in results:
        floor = baseline.get(r["skill"], NEW_SKILL_FLOOR)
        if r["score"] < floor:
            worst = [f"{k} {v['points']}/{v['max']} ({v['detail']})"
                     for k, v in r["checks"].items() if v["points"] < v["max"]]
            failures.append(f"{r['skill']}: {r['score']} < {floor}\n    "
                            + "\n    ".join(worst))
    return failures


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("skills", nargs="*")
    ap.add_argument("--repo", default=Path(__file__).resolve().parents[2])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check", metavar="BASELINE")
    ap.add_argument("--write-baseline", metavar="BASELINE")
    a = ap.parse_args(argv)
    results = [score_skill(d, a.repo) for d in iter_skills(a.repo, a.skills)]

    if a.write_baseline:
        Path(a.write_baseline).write_text(json.dumps(
            {r["skill"]: r["score"] for r in results}, indent=2,
            sort_keys=True) + "\n", encoding="utf-8")
        print(f"wrote {len(results)} baselines to {a.write_baseline}")
        return 0
    if a.check:
        failures = check_baseline(
            results, json.loads(Path(a.check).read_text(encoding="utf-8")))
        for f in failures:
            print(f"❌ {f}")
        if not failures:
            print(f"✅ {len(results)} skills at or above baseline")
        return 1 if failures else 0
    print(json.dumps(results, indent=2) if a.json else render(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
