---
status: Open
estimation: 1
source: conversation with Shine Zhang, 2026-10-07
---

# T20261007-104557: /refresh skill — diff-since-last-look + skill-suggestion report for a task/PR/issue

## Problem

- **Type**: feature
- No skill currently answers "what's changed in the repo since I last touched
  this task/PR/issue, and what should I update as a result" — a session has
  to manually `git log`/diff and re-read everything from scratch each time
  it revisits something.
- New `/refresh` skill, taking a `T<id>` / PR number / GitHub issue number:
  - Diff from when that item was last opened/touched to the current `HEAD` —
    surface what's new in the repo and what in the item now looks stale as a
    result (e.g. a stale `file:line` citation, a referenced script that moved,
    an assumption the diff invalidates).
  - Review the item's own content against the current skill catalog and
    suggest better-fitting skills to apply (one may not have existed, or been
    as well-scoped, when the item was first written).
  - Summarize the proposed updates — report, don't silently auto-apply.
- Concrete motivating case: while driving T20261006-227360, editing
  `drive/SKILL.md` in-place shifted every line number in the file, which
  broke two pre-existing `drive/SKILL.md:426,636` citations inside
  `autopilot/SKILL.md` — caught only by manual review, not by any skill.
- Open design questions for `/incept`/`/drive` time (not resolved here):
  - What "last opened" means per id-type — a task's last frontmatter edit vs.
    its creation commit; a PR's base-branch divergence point; an issue's
    creation vs. its last comment.
  - Whether v1 is report-only (recommended start) or also auto-fixes
    mechanical staleness (e.g. line-number drift) — auto-fixing risks
    silently papering over something that actually needs human judgment.
