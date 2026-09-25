---
status: Open
estimation: 2h
source: 2026-09-25 conversation — surfaced live while /address-pr claiming
  T20260916-232402 in synxdb-build-pipeline
related: T20260809-355059 (same file, same `status:` field, different bug —
  that one is about the `Coding` literal being domain-inappropriate; this
  one is about _tc_fm_set corrupting any multi-line frontmatter value it
  overwrites, `Coding` or otherwise)
---

# T20260925-383305: `_tc_fm_set` leaves orphaned continuation lines when overwriting a multi-line YAML frontmatter value

## Problem

- **Type**: bug
- `_session/task_claim.sh:157-185` (`_tc_fm_set`, called from `acquire` at
  line 544 to set `status: Coding`) replaces frontmatter fields with a
  single-line awk match: `index($0, f":") == 1` finds the line starting
  `field:` and swaps it for the new `field: value` line — but a plain YAML
  scalar can fold across multiple lines when subsequent lines are more
  indented. The awk script never detects or consumes those continuation
  lines, so they fall through to the unconditional `print` at line 176 and
  survive as orphaned garbage under the new value.
- Reproduced live: `T20260916-232402` in `synxdb-build-pipeline` had

  ```
  status: Review — SUPERVISED (PR merged, hashdata-docmind#1; needs a human
    with a real DocMind deployment to spot-check the zh-TW UI before this
    task can close — no live backend in any sandbox we control)
  ```

  Running `task_claim.sh acquire T20260916-232402` produced:

  ```
  status: Coding
    with a real DocMind deployment to spot-check the zh-TW UI before this
    task can close — no live backend in any sandbox we control)
  ```

  — the two continuation lines from the old value are now dangling under
  `status: Coding`, technically still valid YAML (plain-scalar folding
  makes them part of the same value again), but garbled content: the
  effective `status` becomes `"Coding with a real DocMind deployment to
  spot-check the zh-TW UI before this task can close — no live backend in
  any sandbox we control)"`. Had to hand-fix by deleting the two orphaned
  lines before the file was usable.
- Any multi-line frontmatter value is at risk, not just `status` — `_tc_fm_set`
  is generic and is also called for `claimed_by`/`claimed_role`/`scheduled`
  (line 213, 534-535, 542) and elsewhere in the codebase; those happen to
  usually be single-line in practice, but nothing in the function prevents
  the same corruption if one of them ever wraps.
- What "done" looks like: `_tc_fm_set` detects the full span of the field
  it's replacing — the matched `field:` line plus every following line that
  is a continuation (more-indented, not itself `key:`-shaped, not the
  closing `---` fence) — and replaces the whole span with the single new
  `repl` line, consuming (not printing) the old continuation lines. Add a
  BATS case in whichever suite covers `task_claim.sh`/`_tc_fm_set` that sets
  a multi-line `status:` then calls `acquire`, asserting no leftover
  continuation lines and that the resulting frontmatter re-parses cleanly
  as YAML.
