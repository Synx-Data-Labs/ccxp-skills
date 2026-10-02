---
status: Done
scheduled: 2026-09-28
estimation: 2
source: T20260914-412750 (research: learn from mattpocock/skills)
related: T20260914-412750
description: Adopt disable-model-invocation:true for skills that must be human-typed only, instead of relying on prose-only guardrails
claimed_by:
claimed_role:
---

# T20260922-409644: `disable-model-invocation` is never set to `true` anywhere in ccxp-skills — action-taking skills rely on prose alone to avoid surprise auto-fire

## Problem

- `grep -rl "disable-model-invocation: true" --include="SKILL.md" .` returns
  0 hits. This repo has 45 total `SKILL.md` files; 34 of them declare
  `disable-model-invocation` at all (all as `false`), and the other 11
  omit it (same effective default) — none use the `true` branch, meaning
  every skill, including clearly action-taking, side-effecting ones
  (`/autopilot`, `/drive`, `/gcpr`, `/land`), is technically model-invocable.
- The only guardrail against a model surprise-firing one of these is prose:
  `skill-conventions/SKILL.md` §1's own wording ("Use when the user
  explicitly asks to …") is a request to the model to self-restrain, not a
  hard mechanism enforced by the harness.
- `mattpocock/skills` (`.agents/invocation.md`) documents a harder pattern:
  a skill that must be human-typed-only sets `disable-model-invocation:
  true` in its `SKILL.md` frontmatter (paired, in their Codex support layer,
  with `policy.allow_implicit_invocation: false` — not applicable here since
  `ccxp-skills` is Claude-Code-only), gated by an explicit test: "could the
  model usefully reach for this autonomously?" If no, it should be
  user-invoked only, not merely discouraged by wording.

## Context

- Discovered via T20260914-412750's research pass comparing
  `mattpocock/skills`' authoring conventions against
  `skill-conventions/SKILL.md` and `dev/guidelines.md`.
- `skill-conventions/SKILL.md`'s §1 "Guardrail" bullet already implicitly
  acknowledges the risk this closes — it just stops at a prose mitigation
  instead of the frontmatter mechanism that already exists and is unused.

## Design

Grilled via `/incept` 2026-10-01 — supersedes this Solution section's
original candidate list below (kept for history; the bucket assignments
here are the authoritative, fact-checked outcome).

- **Audit scope**: all 48 `SKILL.md` files now in the repo (grown from 45
  since filing), classified against "could the model usefully reach for
  this autonomously?"
- **Bucket A (flip to `true` now)**: `/autopilot`, `/bottom`,
  `/cleanup-branch`, `/memory-to-skill` — hard-to-reverse or
  high-blast-radius, confirmed via repo-wide grep never nested-invoked by
  any other skill's workflow. (`/memory-to-skill` wasn't in the original
  candidate list — found during grilling: its default, no-argument mode
  deletes memory files that live outside any git repo, no revert path at
  all, strictly more irreversible than any of the original candidates.)
- **Bucket B (bundled into this same task, gated on empirical
  validation)**: `/gcpr`, `/land`, `/address-pr`, `/slack`, `/top`,
  `/1password-env-setup`, `/migrate-task` — each is invoked as a
  same-session workflow step by another skill's own documented prose
  (confirmed by grep, not assumed — e.g. `/todo sweep`/`/rca`/`/stage` all
  invoke `/top`; `/spinup` invokes `/1password-env-setup`). Official docs
  confirm `disable-model-invocation: true` blocks the model's *autonomous*
  discovery but don't explicitly address whether it also blocks a
  same-session call that another skill's prose explicitly instructs —
  flipping blind risks silently breaking `/ccxp`/`/drive`'s orchestration
  chain. Implementation order:
  1. Create two throwaway skills purely for this test:
     `_test-nested-invoker` (prose: "invoke `_test-nested-target` now") and
     `_test-nested-target` (`disable-model-invocation: true`, echoes a
     harmless marker string).
  2. Dispatch a **fresh subagent** via the `Agent` tool, instructed to
     invoke `_test-nested-invoker` — a subagent's skill registry resolves
     fresh at dispatch time, so this exercises the real mechanism without
     touching any real orchestration skill.
  3. If `_test-nested-target` fires: flip all of Bucket B to `true`. If
     blocked/unavailable: leave Bucket B at `false`, record the concrete
     result in `## Closed`, don't gamble on breaking orchestration.
  4. Keep the two throwaway skills permanently as regression coverage for
     this exact question (cheap insurance against re-breaking this later).
- **Bucket C (permanent exclusion, documented)**: `/drive` — official docs
  confirm `disable-model-invocation: true` "prevents the skill from being
  preloaded into subagents"; `/autopilot` Phase 3 dispatches a fresh
  subagent specifically instructed to run `/drive`, so flipping this
  breaks a different, already-confirmed-working mechanism regardless of
  Bucket B's validation outcome. Not just deferred — a permanent "never
  flip this" with the reason documented inline, so nobody re-proposes it
  later without rediscovering why.
- `skill-conventions/SKILL.md` gets updated to document both guardrail
  mechanisms side by side (prose-only scoping vs. the hard
  `disable-model-invocation: true` flag), with `/drive` as a worked
  "never flip this" counter-example.
- **Out of scope**: physically migrating/renaming any skill directory
  (that's T20260922-413132's separate maturity-tiering question); changing
  what any skill actually *does* — this only gates who can invoke it.

Estimation revised from 2h to 4h: the original estimate covered a
classify-and-flip pass; the actual scope now includes building and
running a throwaway empirical test harness, a 9-skill classification
across three buckets (not a blanket flip), and a `skill-conventions`
doc update with a worked counter-example.

### Test Plan

- Throwaway harness: `_test-nested-invoker`/`_test-nested-target` exist,
  the dispatched-subagent test actually ran, and its outcome (fired /
  blocked) is recorded verbatim in this task's `## Closed` section —
  not inferred or assumed.
- Bucket A's 4 skills have `disable-model-invocation: true` and no other
  skill's `SKILL.md` references invoking any of them.
- Bucket B's 7 skills match whichever branch the harness result dictates
  (all `true`, or all left `false` with the reason recorded) — never a
  mixed, per-skill guess.
- `/drive`'s `SKILL.md` carries an inline comment explaining why it must
  never set `disable-model-invocation: true`.
- `skill-conventions/SKILL.md` documents both mechanisms with the
  "could the model usefully reach for this autonomously?" test and the
  `/drive` counter-example.

## Solution (original candidate list — superseded by Design above)

- Audit all 45 `SKILL.md` files and classify each by the "could the model
  usefully reach for this autonomously?" test from `.agents/invocation.md`:
  - Reference/diagnostic skills (e.g. `/rca`, `/proof-read`,
    `/skill-conventions`) — keep `disable-model-invocation: false`, they're
    genuinely useful for the model to reach for on its own.
  - Deliberate, side-effecting action skills where an unattended/surprise
    invocation would be risky or confusing (candidates: `/autopilot`,
    `/land`, `/gcpr`, possibly `/drive`, `/top`, `/bottom`) — flip to
    `disable-model-invocation: true` and confirm each skill's own
    description no longer needs the prose-only "Use when the user
    explicitly asks" framing to do that job (the frontmatter now does it).
  - Everything else — leave as-is; this is not a blanket flip.
- Update `skill-conventions/SKILL.md` §1 (or add a new numbered convention)
  to document the two mechanisms side by side: prose-only scoping for
  reference skills that stay model-invocable but shouldn't fire eagerly,
  vs. `disable-model-invocation: true` for skills that must never fire
  without a human typing the name.
- **Alternatives rejected**:
  - *Leave it prose-only, it's worked so far* — rejected: the whole point
    of finding this gap is that a real mechanism already exists in the
    frontmatter schema and is simply unused; there's no cost to using it
    for the highest-risk skills, and it removes reliance on the model
    reliably self-restraining from a wording cue alone.

## Test plan

- [x] After the audit, `grep -rl "disable-model-invocation: true"
      --include="SKILL.md" .` returns at least one hit (the flipped
      skills) — this is a test of the audit outcome, not a script. 6 hits:
      `autopilot/SKILL.md`, `bottom/SKILL.md`, `cleanup-branch/SKILL.md`,
      `memory-to-skill/SKILL.md` (Bucket A, actual frontmatter flips),
      `_test-nested-target/SKILL.md` (throwaway harness, actual flip), and
      `skill-conventions/SKILL.md` (a prose mention of the literal string
      in its own documentation, not a frontmatter flip).
- [x] `skill-conventions/SKILL.md` documents both mechanisms with the
      "could the model usefully reach for this autonomously?" test —
      manual read-through test. See §1's new "A second, harder mechanism
      exists" paragraphs.

## Done criteria

- [x] Every action-taking skill judged risky under the invocation test has
      `disable-model-invocation: true` — manual audit test, see Design.
      Bucket A (4 skills) flipped; Bucket B (7 skills) left `false` per the
      empirical-test fallback (see `## Closed`); Bucket C (`/drive`)
      permanently excluded with an inline frontmatter comment.
- [x] `skill-conventions/SKILL.md` documents when to use each mechanism —
      manual read-through test.

## Closed (2026-10-01)

Shipped in PR [#213](https://github.com/Synx-Data-Labs/ccxp-skills/pull/213).

- **Bucket A flipped to `disable-model-invocation: true`**: `autopilot/SKILL.md`,
  `bottom/SKILL.md`, `cleanup-branch/SKILL.md`, `memory-to-skill/SKILL.md`.
  Confirmed by `grep -rln "/<skill>\b" --include="SKILL.md" .` (precise
  invocation-syntax match, not a bare-word search — `bottom`/`top` are
  common English words that false-positive heavily otherwise) that no
  other `SKILL.md`'s workflow prose nested-invokes any of the four. Every
  hit outside each skill's own file is a descriptive/cross-reference
  mention, never an instruction to invoke the skill as a step:
  `statusline-setup/SKILL.md`, `drive/SKILL.md`, `top/SKILL.md`,
  `stage/SKILL.md` (bottom/autopilot cross-references), `slack/SKILL.md`
  (a file-path mention, `` `autopilot/SKILL.md` Phase 5 ``, not a `/`
  invocation), and `ccxp/SKILL.md` (mentions `/cleanup-branches` —
  plural, a differently-named reference — while explicitly *inlining*
  that workflow "so the cron-driven ccxp run stays self-contained, no
  nested skill dispatch needed").
- **Empirical Bucket B test — ran, result: inconclusive/blocked, not
  "fired."** Built the throwaway harness exactly as designed
  (`_test-nested-invoker/SKILL.md`, `_test-nested-target/SKILL.md`,
  committed permanently per the design's instruction) and dispatched a
  fresh `general-purpose` subagent via the `Agent` tool, instructed to
  invoke `_test-nested-invoker`. **Verbatim result**: the Skill tool call
  failed with `Unknown skill: _test-nested-invoker` — the dispatched
  subagent's skill registry did not contain the newly-created throwaway
  skill at all, so the nested-invocation question (does
  `disable-model-invocation: true` block a same-session nested call) was
  never actually reached. This is a test-infrastructure limitation of this
  session's environment (the Skill tool's available-skill list appears
  fixed per session rather than rescanned per dispatch), not a finding
  about the flag itself — the same root class of problem as
  [T20260922-201976](T20260922-201976-skill-tool-stale-cached-content-vs-live-repo.md)
  (Skill tool serving stale/cached content vs. the live repo checkout),
  filed separately and still open. Per the design's own explicit
  fallback ("if blocked/unavailable: leave Bucket B at `false`, record the
  concrete result, don't gamble on breaking orchestration"): **Bucket B
  (`/gcpr`, `/land`, `/address-pr`, `/slack`, `/top`,
  `/1password-env-setup`, `/migrate-task`) stays at `disable-model-invocation:
  false`, unchanged.** The two throwaway skills are kept permanently per
  the design (cheap regression coverage — re-run the same dispatch from an
  environment where the Skill tool registry does rescan per-dispatch to
  get a real answer).
- **Known trade-off, called out explicitly (independent review finding):**
  `README.md`'s "Shared helpers (`_<name>/`)" section documents that
  leading-underscore dirs stay invisible to Claude Code specifically
  *because they contain no `SKILL.md`* — not because of the underscore
  itself. `_test-nested-invoker/SKILL.md` and `_test-nested-target/SKILL.md`
  break that invariant: they **are** real, registered skills (the repo's
  `SKILL.md` count is now 50, not 48), so they show up in every downstream
  consumer's skill listing, and `_test-nested-invoker` (`false`, by design —
  it must stay directly dispatchable to exercise the mechanism under test)
  is technically model-discoverable. Both also deviate from
  `skill-conventions/SKILL.md` §2's kebab-case naming rule. This is the
  literal mechanism the merged `/incept`-reviewed design specified (naming
  included), and both skills are zero-side-effect no-ops with descriptions
  that say so plainly, so the blast radius of leaving this as designed is
  low — but it is a real, deliberate wart, not an oversight, and is
  recorded here rather than silently accepted.
- **Bucket C (`/drive`) — permanently excluded, documented inline.**
  `drive/SKILL.md`'s frontmatter now carries a `#`-comment directly under
  `disable-model-invocation: false` explaining why it must never flip
  (breaks `/autopilot` Phase 3's fresh-subagent dispatch of `/drive`), with
  a citation ([code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills),
  verified via WebFetch during this close — the original Design section
  above asserted the same claim without a link).
- **`skill-conventions/SKILL.md` updated** (§1) to document both guardrail
  mechanisms side by side — the prose-only `"Use when…"` convention vs. the
  hard `disable-model-invocation: true` flag — with the "could the model
  usefully reach for this autonomously?" test and `/drive` as the worked
  "never flip this" counter-example.
- **Quality-score note**: `skill-conventions/SKILL.md`'s structural score
  (`skill-conventions/scripts/skill_score.py`) dropped from 99 to 98 after
  this addition, entirely from the byte-budget `size` sub-check (new body
  size nudges past the linear-scaling rounding threshold for full marks)
  — prose was already tightened twice to minimize this. Baseline
  (`dev/quality/skill-scores.json`) re-written via `--write-baseline` in
  this same PR to match, per §10's documented ratchet mechanism; this is a
  deliberate, recorded 1-point trade for the new, required documentation
  content, not an unnoticed regression.
- **Follow-up**: none filed. The Bucket B empirical question remains open
  — re-attempt the harness dispatch from a session where fresh-subagent
  skill discovery actually works (tracked implicitly by
  T20260922-201976's resolution, not a new task).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (all
  changes are `SKILL.md`/task-file markdown; Phase 3.0 classifier).
- Verification (`superpowers:verification-before-completion`): yes —
  Phase 3.6 (markdown lint, bats, skill-quality scripts run locally before
  PR) and Phase 7.0 (this close).
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck; the skill-score regression was root-caused directly (byte
  budget vs. the linear size-scoring formula) without needing the
  hypothesis-driven process.
- Receiving code review (`superpowers:receiving-code-review`): no — no
  Copilot/Claude Code review comments at claim-PR time; applies if the
  implementation PR gets findings.
