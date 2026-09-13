# Design-doc template (`/drive` Phase 2)

Fill this into the task file `dev/TODO/T<id>-<slug>.md`. **Scale by change-kind** —
use the same docs/code classifier `/drive` Phase 3.0 already computes:

- **All tasks** include the §Common sections.
- **Code/bug tasks** *also* include the §Code-only sections.
- A docs/chore task **omits** the code-only sections — do not pad.

**One-pager discipline**: most tasks should read top-to-bottom on one scrolled
screen. The goal is the *right sections completed*, **not a line count** — a
`15m`/`1h`/`2h` task earns a few bullets per section; only a `2d`+ or
Critical/RCA task earns real length. The reference exemplar
`dev/JOURNAL/2026-06-09-T20260608-672829-port-bin-elf-scan-for-fcs-runtime-libs.md`
is long because it's a Critical three-factor RCA — study its anatomy, not its
size, and don't treat it as license to pad a routine task.

**Evidence discipline (every kind):** anchor each claim to a `file:line`, a git
SHA, or command output. Label what is *verified* vs *assumed*. A claim with no
anchor is a guess — mark it as one or cut it. ("could not re-verify … but the
build-script evidence is conclusive" is honest; a bare assertion is not.)

**Format discipline (every kind):** bullets, not paragraphs — chunk every
section into bullet points (~3 per level; nest a sub-list under one bullet
instead of running past that or folding the extra detail back into prose).
Reserve full paragraphs for narrative that genuinely doesn't decompose (a
root-cause story, a rationale) — see `templates/guidelines.md`'s Documentation
section for the canonical wording. Example — a Problem-section paragraph
turned into bullets:

- ❌ *"The migration shipped `is_leader`/`can_post` but the name only
  describes identity, not what it grants, and nothing enforces that granting
  `leader` also implies posting rights, which could silently break future
  code that checks `can_post` directly."*
- ✅
  - `is_leader` names identity, not capability — rename to `can_admin`.
  - Granting `leader` must set `can_admin=1` **and** `can_post=1` explicitly:
    - no implicit "leadership implies posting" assumption
    - protects future code that queries `can_post` directly

`repo-conventions/scripts/lint_paragraphs.py --changed <file>` catches the worst offenders
automatically (non-blocking — a nudge, not a gate; `/gcpr`'s doc-lint guard already runs it).

---

## Frontmatter (all tasks)

```yaml
---
estimation: <Nh (S|M|L)>
status: <Open|Design|Coding|Review|Done>
scheduled: <YYYY-MM-DD>            # set by the IPM, not by hand
source: <where this came from — conversation date, parent RCA, issue #N>
related: <T-ids / journal paths this depends on, pairs with, or follows>
---
```

## §Common — every task

### `# T<id> — <descriptive, action-oriented title>`

### `## TLDR`  ← required, scored (design-score C2) — not optional

3-5 bullets, skimmable in 10 seconds — this is the whole doc in miniature:

- **Type**: bug | feature | chore | research | spike | rca | other — `research`
  is reading-based (a question to answer, no code); `spike` is a throwaway
  prototype to verify feasibility (code, but disposable — mirrors
  `superpowers:brainstorming`'s own Spike path); `rca` investigates a
  reported failure/bug (usually links the triggering incident via `source:`
  or `related:`) and leans on `## Root cause` below
- **Problem**: one line
- **Solution**: one line

### `## Problem`

The symptom, with reproduction **evidence** — error output, the failing command,
the exact wrong value observed. Not "X is broken" → *show* it broken. Say why
it matters (impact), not just what's wrong.

### `## Context`

The surrounding situation, scoped by kind — skip the branches that don't apply:

- **Bug**: the repro environment — versions, config, the state that triggers it.
- **Feature**: the use cases driving it, and what already exists to build on
  (the current architecture/data this plugs into — don't redescribe it from
  scratch, point at it).
- **Chore**: where the friction is actually felt (which workflow, how often).

### `## Solution` (or `## Plan`/`## Scope` — same section; existing docs may already use `Plan`)

What changes, phased if multi-step. Branch by kind:

- **Bug**: the fix, and why it's the right one — the mechanism/git-archaeology
  story itself lives in `## Root cause` below, not repeated here.
- **Feature**: the architecture, how it fits the existing program, the options
  considered and their trade-offs.
- **Chore**: the expected efficiency gain and how to get there.

Inline the **alternatives considered and rejected, with the reason** for each
rejection — not just the chosen path.

### `## Test plan`

Checkbox items (`- [ ]`), ideally multi-level (unit → local → CI/dry-run →
end-to-end). For anything under `scripts/`, a BATS/unittest case is **required**
(guidelines). Mark genuinely-external verification (customer deploy, post-merge
dispatch) as a post-merge item.

### `## Done criteria`

Checkbox items. **Each criterion names the test or `file:line` that satisfies
it** — an item you can't map to a verification is either untested or too vague.
Leave a genuinely-external item unchecked and say *why* (honest beats
green-washed).

### `## Appendix` (optional)

Overflow that would otherwise bloat the sections above: a long historical
decision log, raw error dumps, extra reference links. Most tasks don't need
this — reach for it only when a `## Solution` alternative or a `## Context`
detail is too long to inline without breaking the one-pager discipline above.

### `## Closed (YYYY-MM-DD)`  ← written at Phase 7 (standardized name — never "Resolution"/"Outcome")

Shipped in **PR #N** (+ run / evidence links). What's met; what's
external/unverified and when it will be confirmed; any **follow-up tasks filed**
(T-ids).

### `## Skills invoked`  ← the Phase 7.0 audit block (verbatim from Phase 7.0)

## §Code-only — code/bug tasks *also* include

### `## Root cause`

The mechanism, anchored to `file:line`. **Git archaeology**: when was it
introduced (`<SHA>`, date) and *why* — deliberate decision or oversight? This is
what separates a real RCA from a plausible guess.

### `## Repo file references`

A table — every file the change touches or cites:

| File | Lines | Purpose |
|---|---|---|
| `path/to/file` | `NN–MM` | what it is / why it matters |
