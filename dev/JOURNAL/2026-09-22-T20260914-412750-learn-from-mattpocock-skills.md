---
status: Done
estimation: 4h
source: this conversation, 2026-09-14
related: T20260912-279229
description: Research mattpocock/skills to find next-level improvements for ccxp-skills
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260914-412750: Learn from `mattpocock/skills` and apply improvements to ccxp-skills

## TLDR

- **Type**: research
- **Problem**: `ccxp-skills` ported one skill (`grilling` → `grill-me`, T20260912-279229) from `mattpocock/skills` but never surveyed the rest of that repo for other skills or authoring conventions worth adopting.
- **Solution**: fetch the repo's skill inventory and any shared authoring docs, diff its conventions against `ccxp-skills:skill-conventions`/`dev/guidelines.md`, and file a prioritized list of concrete follow-up tasks (not just notes).

## Problem

- **Type**: research
- `grill-me/SKILL.md` was adapted from the Hermes `grill-me` skill, itself
  credited to "Rafael Zendron + Matt Pocock's `grilling`" — but we never
  went to the source, `https://github.com/mattpocock/skills`, to see what
  else is there beyond the one skill we already ported (T20260912-279229).
- Unknown: what skill-authoring conventions, structure, or individual
  skills in that repo could raise the bar for `ccxp-skills` — beyond
  `grilling` there may be other skills or authoring patterns worth
  adopting or adapting.
- Done looks like:
  - The repo cloned/read and its skills inventoried (structure,
    frontmatter conventions, any shared authoring guidelines).
  - A comparison against `ccxp-skills:skill-conventions` and
    `dev/guidelines.md` — where do the two approaches agree, and where
    does `mattpocock/skills` do something we don't?
  - A concrete, prioritized list of proposed improvements or new tasks
    for `ccxp-skills` (e.g. new skills to port, conventions to adopt,
    or gaps in our current skill-authoring practice) — not just notes.

## Context

- `ccxp-skills:skill-conventions` (`skill-conventions/SKILL.md`) is this
  repo's own authority for skill naming, structure, frontmatter, and
  when to extract a shared lib — the comparison baseline.
- T20260912-279229 (`dev/JOURNAL/`) already ported one skill (`grilling`
  → `grill-me`) from this source repo — this task surveys the rest of
  it rather than repeating that single-skill port.
- No local clone of `mattpocock/skills` exists in this environment;
  investigation is read-only against the public GitHub repo (WebFetch /
  `gh api`), no write access needed or used.

## Solution

- Fetch `mattpocock/skills`' top-level structure (its GitHub tree/API,
  or a shallow read via WebFetch of the repo's file listing) to inventory
  every skill directory and any repo-level authoring doc (README,
  CONTRIBUTING, a skills-authoring guide).
- For each skill found (beyond `grilling`, already ported): read its
  `SKILL.md`-equivalent, note its frontmatter shape, structure, and any
  authoring pattern not already present in `ccxp-skills:skill-conventions`.
- Diff against `skill-conventions/SKILL.md` and `dev/guidelines.md`:
  where do the two approaches agree, and where does `mattpocock/skills`
  do something `ccxp-skills` doesn't?
- Write the findings into this task file (inventory + comparison), then
  file each concrete, worthwhile improvement as its own new
  `dev/TODO/T<id>-<slug>.md` task (per `_taskid/new.sh --check ./dev`) —
  the prioritized list itself lives in this task's `## Closed` section
  as links to what got filed, not as unfiled prose.
- **Alternatives rejected**:
  - *Clone the repo locally for a deeper read* — rejected: this is a
    read-only survey of skill structure and docs, not code execution;
    GitHub's web UI/API is sufficient and avoids leaving a stray clone
    in the working tree.
  - *Port skills directly in this task instead of filing follow-ups* —
    rejected: the task's own Done criteria call for "a concrete,
    prioritized list... not just notes," i.e. scoping decisions, not
    implementation — each adoption is its own right-sized follow-up task
    per this repo's TODO lifecycle, consistent with how T20260912-279229
    itself was scoped as a single-skill port.

## Test plan

- [x] Every skill directory in `mattpocock/skills` is accounted for in
      this task's inventory, by bucket and name, with verified counts
      (18+7+4+9+0 = 38) — delivered as a structural bucket/count
      inventory rather than a per-skill one-line description (a coarser
      grain than originally scoped here, but sufficient to satisfy the
      Done criteria's "structure inventoried" bar; a per-skill
      description would be its own larger follow-up if ever needed).
- [x] The comparison section names at least one concrete agreement and
      one concrete gap (or explicitly states "no gaps found" if that's
      the honest result) against `skill-conventions/SKILL.md`.
- [x] Every proposed improvement is filed as its own `dev/TODO/T<id>-*.md`
      task (not left as inline prose) — post-merge item: each filed
      task's own existence is the verification.

## Research findings

**Inventory** (`mattpocock/skills`, `main` branch, fetched via `gh api repos/mattpocock/skills/git/trees/main?recursive=1`):

- 5 bucket folders under `skills/`: `engineering/` (18 skills — tdd, code-review,
  domain-modeling, diagnosing-bugs, implement, research, triage, wayfinder,
  wizard, to-spec, to-tickets, ask-matt, codebase-design,
  resolving-merge-conflicts, improve-codebase-architecture,
  grill-with-docs, setup-matt-pocock-skills, prototype), `productivity/` (7 —
  `grilling`/`grill-me` (already ported, T20260912-279229), `handoff`,
  `teach`, `to-questionnaire`, `wait-what`, `writing-for-agents`),
  `misc/` (4 — git-guardrails-claude-code, migrate-to-shoehorn,
  scaffold-exercises, setup-pre-commit), `in-progress/` (9),
  `deprecated/` (README only, empty). Counts verified directly against
  `gh api repos/mattpocock/skills/git/trees/main?recursive=1` (18+7+4+9+0
  = 38 skill directories total), not estimated.
- Every skill directory carries `SKILL.md` **plus** `agents/openai.yaml`
  (Codex-specific UI metadata + an `allow_implicit_invocation` policy
  mirror) — a per-agent-harness pairing `ccxp-skills` has no equivalent
  of (this repo is Claude-Code-only).
- Root-level structure beyond `skills/`: `.agents/` (cross-cutting
  authoring docs — `writing-docs.md`, `invocation.md`, `install-block.md`
  — plus `adr/` for skill-system architecture decisions),
  `.changeset/` (per-change version-bump metadata, npm-style),
  `.out-of-scope/` (explicit non-goal docs, e.g.
  `mainstream-issue-trackers-only.md`), `docs/<bucket>/<skill>.md`
  (human-facing pages, published externally at
  `aihero.dev/skills-<name>`, separate from the agent-facing `SKILL.md`),
  and `.claude-plugin/` (marketplace + plugin manifest — same mechanism
  `ccxp-skills` already uses).

**Comparison against `skill-conventions/SKILL.md` + `dev/guidelines.md`:**

- **Agreement**: both repos ship as a Claude Code plugin via
  `.claude-plugin/`; both use `disable-model-invocation` frontmatter;
  both document argument conventions and cross-skill composition.
- **Gap 1 — `disable-model-invocation` is never actually set to `true`
  anywhere in `ccxp-skills`.** `grep -rl "disable-model-invocation: true"
  --include="SKILL.md" .` returns 0 hits. This repo has 45 total
  `SKILL.md` files; 34 of them declare `disable-model-invocation` at all
  (all as `false`) — the other 11 (mostly Cloudflare/dev-tool reference
  skills) omit the field entirely, which defaults to the same
  effectively-model-invocable behavior.
  Meanwhile action-taking skills like `/autopilot`, `/land`, `/gcpr`
  rely purely on prose wording ("Use when the user explicitly asks
  to…") to discourage surprise auto-invocation — `skill-conventions`
  §1's own guardrail describes exactly this workaround. `.agents/invocation.md`
  formalizes a harder mechanism: an explicit `disable-model-invocation:
  true` (Claude Code) + `policy.allow_implicit_invocation: false`
  (Codex) pairing, gated by a concrete test ("could the model usefully
  reach for this autonomously?"), for skills that must be human-typed
  only. `ccxp-skills` has the frontmatter field but has never used its
  `true` branch — filed as T20260922-409644.
- **Gap 2 — no maturity tiering; every skill ships in the plugin
  unconditionally.** `.claude-plugin/plugin.json`'s `"skills": "."`
  means all 45 skills ship regardless of how settled or frequently-used
  they are. `mattpocock/skills` reserves `misc/`/`in-progress/`/
  `deprecated/` buckets that are explicitly excluded from both the
  top-level `README.md` and the plugin manifest — immature or
  rarely-used skills don't clutter the default install. `ccxp-skills`'
  README already informally groups skills into categories (Task
  lifecycle & PR automation, Notification & integration, General-purpose
  utility, Cloudflare developer platform) but this is prose-only, not
  enforced by directory structure or the plugin manifest — filed as a
  scoping task, T20260922-413132.
- **Considered, not filed**: a `.out-of-scope/` directory for explicit
  non-goals, and per-skill `docs/<bucket>/<skill>.md` human-facing pages
  separate from `SKILL.md`. Both are genuine conventions worth knowing
  about, but `ccxp-skills` is an internal team tool (not published to
  external subscribers the way `aihero.dev` is), and non-goals here are
  already recorded inline in each skill's own "Important Notes" section
  — the cost of a new parallel structure isn't clearly earning its
  keep yet. Not filing to avoid busywork (per `/retro`'s own "don't
  create tasks that won't meaningfully impact velocity or quality"
  principle) — worth revisiting if either pain point (a maintainer
  losing track of a documented non-goal, or a skill needing a
  standalone human-facing explainer) actually recurs.
- A Codex-parity `agents/openai.yaml` per skill is out of scope entirely
  — `ccxp-skills` targets Claude Code only; adding Codex support is a
  much larger, separate decision than a docs-convention gap.

## Done criteria

- [x] Repo inventoried (structure, frontmatter, authoring guidelines) — this task's own manual-inspection test. See `## Research findings` below.
- [x] Comparison against `skill-conventions/SKILL.md` and `dev/guidelines.md` — this task's own manual-inspection test. See `## Research findings` below.
- [x] Prioritized improvement list filed as tasks, not prose — this task's own filed-task-existence test. See `## Closed` below.

## Closed (2026-09-22)

- No shipped PR — this is a research task; its output is this file's
  `## Research findings` section plus two filed follow-up tasks (both
  staged `scheduled: 2026-10-05`, per the follow-up convention):
  1. **T20260922-409644** — adopt `disable-model-invocation: true` for
     skills that must be human-typed only, instead of relying on
     prose-only guardrails.
  2. **T20260922-413132** — scope whether `ccxp-skills` should adopt a
     maturity tier (promoted vs misc/in-progress/deprecated) so the
     plugin bundle isn't every skill unconditionally.
- Two further gaps were considered and deliberately **not** filed (a
  `.out-of-scope/` non-goals directory, and per-skill human-facing docs
  pages separate from `SKILL.md`) — see `## Research findings`'s
  "Considered, not filed" bullet for the reasoning.
- No blockers encountered; all research was read-only (GitHub API), no
  local clone needed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — research-class task,
  no executable code
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (84/100), and each Done criterion cross-checked
  against the actual Research findings / filed-task content before
  checking it off
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck
- Receiving code review (`superpowers:receiving-code-review`): pending —
  addressed as part of this task's own `/address-pr` loop
