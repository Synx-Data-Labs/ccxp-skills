---
status: Design
estimation: 3
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
scheduled: 2026-09-28
source: Conversation 2026-09-23 — grill-me vs mattpocock-skills:grilling comparison
related: T20260923-986928
---

# T20260923-140360: Add an external-skillset scan to /retro

## TLDR

- **Type**: feature
- **Problem**: `/retro` Phase 4c only grades our *own* skills — nothing
  notices when an installed external marketplace (e.g. `superpowers`,
  `mattpocock-skills`) already has a leaner/better solution to something we
  built ourselves (surfaced manually on 2026-09-23: `grill-me` vs
  `mattpocock-skills:grilling`).
- **Solution**: new `### Phase 4e: External skillset scan` sibling to
  4c/4d — cheap, frontmatter-only trigger-overlap scan against every
  *other* enabled marketplace's skills, scoped to the skills this week's
  Phase 4c evidence already touched; report-only, same bounded-vs-needs-design
  downgrade discipline as 4c step 3.

## Problem

- **Type**: feature
- `/retro` Phase 4c (`retro/SKILL.md:415`) already grades *our own*
  skills weekly and drafts a bounded fix for the single worst offender
  — but it only ever looks inward at `ccxp-skills` itself. There's no
  step that looks at other installed/known marketplaces (e.g.
  `mattpocock-skills`, `superpowers`) to see whether one of them has
  already solved a problem we have, or does something leaner/better
  than our own equivalent skill.
- Concretely surfaced 2026-09-23: comparing `ccxp-skills:grill-me`
  against the newly-installed `mattpocock-skills:grilling` showed the
  same frontier-round interview algorithm implemented two ways —
  ours with heavier repo-specific wiring, Matt's leaner and portable.
  We only found this because a human happened to install the plugin
  and ask for a diff; nothing in the suite surfaces this kind of
  comparison on its own.
- **Done when**: `/retro` gains a new phase (e.g. `Phase 4e: External
  skillset scan`, sibling to `4c`/`4d`) that periodically compares our
  skills against other installed marketplaces' skills covering similar
  triggers, and reports (not auto-adopts) candidates worth a follow-up
  design pass — same "downgrade to a filed task when it needs real
  design" discipline `4c` step 3 already uses.

## Context

- Scope this as **report-only** for the first version — surface
  candidates as `Category: quality` action items (mirroring `4c` step
  3's "needs real design" downgrade path) rather than auto-drafting a
  PR. Auto-adopting behavior from an external, independently-versioned
  plugin is a materially different trust model than `4c`'s own-repo
  bounded-edit path, and deserves its own brainstorm before any
  auto-merge is on the table.
- Open design questions for whoever picks this up (deliberately left
  unresolved here, not this task's job to settle):
  - Which marketplaces count as "worth learning from" — all installed
    plugins, or an explicit allowlist?
  - Cadence — every retro, or a slower interval (monthly)?
  - How to diff "does something similar" without just re-reading every
    other skill's SKILL.md in full each run (cost/signal tradeoff).
- Companion task T20260923-986928 (rename `/grill-me` to `/incept`,
  vendor `grilling`'s mechanics) is the first concrete instance of "we
  learned from another skillset and vendored the useful part" — this
  task is about making that discovery repeatable instead of one-off/manual.
- Verified enumeration mechanism (this host, `xlj`'s clone): enabled
  marketplaces live in `~/.claude/settings.json` → `enabledPlugins`
  (currently `ccxp-skills@ccxp-skills`, `superpowers@claude-plugins-official`,
  `synx-skills@synx-skills`, `warp@claude-code-warp`) and
  `extraKnownMarketplaces`. Each installed plugin's skills sit at
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/*/SKILL.md`
  — confirmed by listing `~/.claude/plugins/cache/claude-plugins-official/superpowers/6.4.1/skills/`.
  `ccxp-skills` and `synx-skills` are **our own** marketplaces (the ones
  `4c` already grades) and must be excluded from "external".
- `retro/SKILL.md:415-440` (`Phase 4c`) is the structural model to mirror:
  graceful-degradation signal gathering → judgment-based pick → bounded-vs-
  needs-design triage → a `## <section>` in the Phase 5 report
  (`retro/SKILL.md:530-534`) → a summary line in the Phase 6 Slack template
  (`retro/SKILL.md:587-596` — the `Skill quality:` bullet itself is at line
  `596`, not `594`).
- **Line-number caveat**: every `retro/SKILL.md:<N>` citation below is the
  **current, pre-this-change** location — it's where to make the edit, not
  where the result will end up (inserting ~40-60 new Phase 4e lines shifts
  everything after it down). Verification (Test plan / Done criteria) must
  anchor on section headers and bullet text, never re-check these same
  absolute line numbers post-edit.
- **4c step 1's own evidence isn't always a full skill inventory**: per
  `retro/SKILL.md:421`, exact per-skill attribution only exists when a
  `## Skills invoked` audit block is present in the week's JOURNAL or
  still-open task files; absent that, 4c step 1 falls back to coarse *domain buckets*
  (`drive`, `todo`, `address-pr`, …), not individual skill names. Phase 4e
  (Solution step 3 below) must consume whichever granularity 4c step 1
  actually produced this week — exact skill names when available, domain
  buckets otherwise — not assume a full name list always exists.

## Solution

- Add `### Phase 4e: External skillset scan`, inserted between Phase 4d
  (ends `retro/SKILL.md:474`) and Phase 5 (`retro/SKILL.md:476`), structured
  like 4c:
  1. **Enumerate external marketplaces** — read `enabledPlugins` from
     `~/.claude/settings.json`, excluding this suite's own marketplace
     name(s). "Our own" is **whichever repo `/retro` is currently running
     in** plus its sibling marketplaces named in *that repo's own*
     `CLAUDE.md`/`dev/guidelines.md` (e.g. in this hub repo, `ccxp-skills`
     and `synx-skills` are both ours; a different consumer repo running
     `/retro` would name its own marketplace instead) — never a hardcoded
     list, so the exclusion travels correctly to any adopting repo.
     **Resolves the "all installed vs. allowlist" open question**: scan
     every *currently enabled* external marketplace, no allowlist — an
     allowlist needs manual upkeep every time a plugin is installed, which
     defeats the goal (a human manually noticing the overlap is exactly
     the gap this task closes).
  2. **List each external marketplace's skills** — one line per skill:
     name + frontmatter `description:` (the trigger one-liner), from
     `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/*/SKILL.md`.
     Cheap: frontmatter only, never the full body.
  3. **Scope comparison to whatever Phase 4c step 1 already produced this
     week** — reuse that evidence as-is rather than diffing the *entire*
     local skill inventory against the *entire* external inventory every
     run: when a `## Skills invoked` audit block was present (exact skill
     names, per `retro/SKILL.md:421`), compare those names' descriptions
     directly; when only the coarse domain-bucket fallback is available
     (`drive`, `todo`, `address-pr`, …), compare the bucket's *member*
     skills (the repo's own skills tagged under that domain, e.g. `drive`
     → the `drive` skill itself) — never skip the phase just because the
     week had no audit block. **Resolves the "every retro vs. monthly"
     open question**: because the expensive side (full external inventory)
     is description-only and the compared side is already bounded to this
     week's handful of exercised skills/buckets, the cheap comparison can
     run **every retro** — no slower cadence needed. (A full-body diff, if
     a candidate needs one, happens only after a trigger-overlap hit — see
     alternatives below.)
  4. **Trigger-overlap judgment** — for each exercised skill, scan the
     external skill-description list for topic/trigger overlap (same
     judgment-call nature as 4c step 2's "pick the worst offender" — no
     formula, Claude's own reading of "do these two skills cover the same
     ground"). A hit is a **candidate**, not a verdict.
  5. **Report, never auto-adopt** — for each candidate, file a
     `Category: quality` action item (Source `Retro YYYY-MM-DD`) proposing
     a follow-up comparison/design pass, mirroring 4c step 3's own
     "needs real design" downgrade (never draft a bounded fix here — an
     independently-versioned external plugin is a different trust model
     than our own repo, matching the existing Context note above).
  6. **Guards**: no external marketplaces enabled → "no external
     marketplaces configured", skip. No skills exercised this week → "no
     skill activity" (same guard 4c already has at `retro/SKILL.md:436`,
     shared — not duplicated).
- **Report**: a `## External skillset scan` section in the Phase 5
  template, inserted directly after the existing `## Skill quality` block
  (`retro/SKILL.md:530-534`, current pre-edit location); an
  `External scan:` bullet in the Phase 6 Slack summary template, inserted
  directly after the `Skill quality:` bullet (`retro/SKILL.md:596`,
  current pre-edit location) — same placement pattern 4c uses for its own
  report/summary hooks.

**Alternatives considered and rejected:**

- *Full SKILL.md body diff every retro, for every external skill against
  every local skill* — rejected: O(local × external) full-text reads every
  week is exactly the cost 4c itself avoids by scoping to "skills exercised
  this week"; the cheap description-only pass already catches the kind of
  overlap this task is after (two skills claiming the same trigger),
  without reading bodies until a trigger-overlap hit justifies it.
- *Explicit per-marketplace allowlist* — rejected: requires a human to
  remember to add every newly-installed marketplace, reproducing the exact
  manual-discovery gap (a human had to notice and ask) this task exists to
  close.
- *Monthly/slower cadence* — rejected now that the comparison is scoped to
  frontmatter + this-week's-exercised-skills: the expensive full-inventory
  case that would have justified a slower cadence doesn't exist in this
  design, so there's no cost reason to defer past "every retro" (same
  cadence as 4c/4d, the two phases it's designed to pair with).
- *A standalone script/skill instead of a `/retro` sub-phase* — rejected:
  4c and 4d already establish the precedent of a prose-driven retro
  sub-phase with light script assists (judgment calls don't deterministically
  script); a separate entry point would fragment the quality-review surface
  `/retro` is meant to be the single home for.

## Test plan

- [ ] `bash _docs/lint-docs.sh retro/SKILL.md` passes after the edit
- [ ] Manual walkthrough: re-run the enumeration steps against this
  clone's real `~/.claude/settings.json` + plugin cache (the same paths
  verified in Context above) and confirm the external-skill list includes
  `superpowers`'s skills with their descriptions
- [ ] Manual walkthrough: using the 2026-09-23 `grill-me` vs
  `mattpocock-skills:grilling` example from Problem, confirm the new
  Phase 4e steps (as written) would have surfaced `grilling` as a
  candidate against `grill-me`/`incept`'s description — the concrete case
  that motivated this task
- [ ] Confirm the new Phase 5 `## External skillset scan` report block and
  Phase 6 `External scan:` Slack bullet are present, directly after their
  respective `## Skill quality` / `Skill quality:` anchors (locate by
  heading/bullet text, not a line number — see the line-number caveat in
  Context) — `retro/SKILL.md:530-534`/`596` name the pre-edit anchors
- [ ] Next real `/retro` run post-merge exercises Phase 4e at least once
  and its `## External skillset scan` section renders (post-merge item —
  can't be verified before this PR merges)

## Done criteria

- [ ] `retro/SKILL.md:475` (pre-edit anchor — locate by heading, not this number post-edit) — `### Phase 4e: External skillset scan` section exists between Phase 4d and Phase 5
- [ ] `retro/SKILL.md:475` (pre-edit anchor) — Phase 4e documents all 6 steps (enumerate marketplaces, list external skills, scope to whatever 4c step 1 produced — exact names or domain buckets, trigger-overlap judgment, report-not-adopt, guards); verified by the `## Test plan` manual walkthrough below
- [ ] `retro/SKILL.md:534` (pre-edit anchor) — `## External skillset scan` block added to the Phase 5 report template
- [ ] `retro/SKILL.md:596` (pre-edit anchor, corrected from an earlier `:594`) — `External scan:` bullet added to the Phase 6 Slack summary template
- [ ] `_docs/lint-docs.sh retro/SKILL.md` passes (see Test plan)
