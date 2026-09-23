---
status: Open
estimation: 4h
source: conversation with @shine, 2026-09-23
related: T20260923-584914
---

# T20260923-986928: Rename `/grill-me` to `/incept`, vendor `grilling`'s interview mechanics

## TLDR

- **Type**: feature
- **Problem**: `grill-me/SKILL.md` paraphrases the frontier-round interview
  algorithm it credits to `mattpocock-skills:grilling`, but the two have
  drifted into separately-maintained near-duplicates, and the name
  `grill-me` (matching the external plugin's own alias) invites confusion
  with `mattpocock-skills:grilling` now that both are installed side by
  side.
- **Solution**: rename the skill directory to `incept/` (verb form,
  `skill-conventions` §2), rewrite its interview-mechanics section by
  vendoring `grilling`'s tighter prose in place (no runtime plugin
  dependency), keep the repo-specific file-I/O wiring unchanged, and
  update the 3 files that reference the old name.

## Problem

- `grill-me/SKILL.md:15-18` explicitly credits "Hermes `grill-me` skill
  (Rafael Zendron + Matt Pocock's `grilling`)" but reimplements the
  algorithm in its own words rather than vendoring it directly — a
  side-by-side read (this conversation, 2026-09-23) confirmed the two are
  ~90% identical in mechanics (frontier rounds, numbered `❓ Qn` +
  `➡️ recommendation` format, fact-finding-is-the-agent's-job) with no
  meaningful divergence worth maintaining separately.
- `grill-me` (this repo) and `grilling` (`mattpocock-skills`, now
  installed as a marketplace plugin — see `/plugin marketplace add
  mattpocock/skills`, this session) are two names for the same mechanic,
  which is confusing now both are simultaneously invocable.
- **Done when**: `incept/SKILL.md` exists with `grilling`'s vendored
  mechanics + `grill-me`'s existing file-I/O wiring; `grill-me/` is
  removed (via `git mv`, preserving history); `README.md` and
  `ccxp/SKILL.md` Phase 2a.3 reference `/incept` instead of `/grill-me`;
  no repo-wide reference to `grill-me` remains outside `dev/JOURNAL/`
  (historical record, untouched).

## Context

- Companion task T20260923-584914 (extract `/ipm` from `/ccxp` Phase 2a)
  explicitly defers its own 2a.3 call-site wiring to whatever this task
  lands on — revisit that task's `/incept` reference once this merges.
- Precedent: `dev/JOURNAL/2026-09-22-T20260914-412750-learn-from-mattpocock-skills.md`
  already surveyed `mattpocock/skills` broadly and confirms `grilling` →
  `grill-me` was a deliberate single-skill port (T20260912-279229) — this
  task continues that same pattern (vendor, don't runtime-depend), not a
  new one.
- Considered and rejected (this conversation, 2026-09-23):
  - **Runtime dependency** — call `mattpocock-skills:grilling` directly
    via the `Skill` tool. Rejected: breaks this repo's "no external
    dependency" promise (`CLAUDE.md` header) — every adopting team would
    need to separately install and trust a marketplace plugin whose
    behavior can drift out from under this suite's version.
  - **Optional/try-then-fallback dependency** — rejected as needless
    complexity for one paragraph of prompt text worth just copying.
  - **Keep `grill-me`'s own bespoke wording, just rename the directory**
    — rejected: doesn't address the actual near-duplication, only the
    name collision.
- Naming alternatives considered: `/inception` (rejected — noun, not a
  verb, per `skill-conventions` §2), `/probe`/`/interrogate`/`/refine`/
  `/polish` (all valid verbs, none chosen). `/incept` chosen: a real
  (if uncommon) verb meaning "to originate an idea in someone's mind" —
  satisfies the verb rule and keeps the XP/"Inception" thematic link the
  maintainer wanted.
- Explicitly out of scope (deferred by the maintainer, 2026-09-23): making
  `/drive` Phase 2 optionally call `/incept` when it detects vague
  requirements. `/drive` Phase 2's own solo-research-and-fill fallback is
  untouched by this task (Approach A of 3 considered — see this
  conversation's transcript for the rejected alternatives B/C).

## Solution

- `git mv grill-me incept` (preserves file history).
- Rewrite `incept/SKILL.md`:
  - Frontmatter: `name: incept`; same trigger description as `grill-me`
    today (grilling/interviewing/stress-testing a plan), reworded for the
    new name; same `argument-hint`.
  - Workflow steps 1-3 (build tree → frontier rounds → synthesis):
    replace with `grilling`'s vendored mechanics, crediting the source
    the same way `grill-me` does today.
  - Workflow step 4 (record to task file — Design section, Test Plan,
    estimation revision, lint gates) and Important Notes: carry over
    unchanged — this is the repo-specific wiring `grilling` has no
    equivalent of.
- `ccxp/SKILL.md` Phase 2a.3 (`:650-680`): replace `/grill-me` mentions
  with `/incept` — wrapper logic (claim, status, escalate-on-blocking-Open-item)
  is unchanged.
- `README.md`: update the skill-list entry's name.
- **Alternatives rejected**: see `## Context` above (runtime dependency,
  optional dependency, rename-only).

## Test plan

- [ ] `git mv grill-me incept` completes cleanly, `git log --follow
      incept/SKILL.md` shows continuous history from `grill-me/SKILL.md`.
- [ ] `grep -rln "grill-me" --include="*.md" .` (repo root) returns only
      `dev/JOURNAL/**` paths — zero hits elsewhere.
- [ ] `python3 repo-conventions/scripts/lint_tasks.py` and
      `bash _docs/lint-docs.sh --fix` both pass on the touched files.
- [ ] Manual read-through: `/incept T<id>` on a throwaway task confirms
      the frontier-round flow still produces a synthesis and writes the
      Design section (docs-class change — no BATS tests apply, per
      `skill-conventions` §5, prose-only skill).

## Done criteria

- [ ] `incept/SKILL.md` exists, `grill-me/` does not — verified by the
      `git mv` + repo-wide grep above.
- [ ] `ccxp/SKILL.md` Phase 2a.3 and `README.md` reference `/incept` —
      verified by the same grep.
- [ ] Design approved in-conversation 2026-09-23 (this task file's
      `## Context`/`## Solution` sections) — per `drive/SKILL.md` Phase 2's
      "design already in the file AND maintainer has explicitly approved
      it in conversation" skip path. The Phase 1 claim PR is still
      required before implementation.
