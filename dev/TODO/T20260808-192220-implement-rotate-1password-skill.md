---
status: Open — SUPERVISED (needs a human: live 1Password/GitHub-secret rotation against a real vault, and the referenced upstream design doc at your-org/hub-repo is not accessible from this clone)
estimation: 1d
related: T20260806-374741, T20260806-240910
source: 2026-08-08 conversation — follow-on from T20260806-374741's finalized design
---

# T20260808-192220: Implement the `/rotate-1password <secret>` skill

## Problem

- [T20260806-374741](https://github.com/your-org/hub-repo/issues/441)'s brainstorm pass (2026-08-08) finalized the design for a
  `/rotate-1password <secret-name>` skill that automates rotating a tracked
  secret and propagating it to its consuming GitHub secret. That task was
  design-only by its own Done criteria — this task is the implementation.
- No code exists yet. Full design (flow, security invariant, rollback
  procedure, worked examples) lives in
  `dev/TODO/T20260806-374741-rotate-1password-skill-design.md`'s `## Solution`
  section (or its `dev/JOURNAL/` equivalent once that task closes, in
  `hub-repo`) — read it in full before starting; this file only
  summarizes.

## Design summary (see [T20260806-374741](https://github.com/your-org/hub-repo/issues/441) for the full write-up)

- **v1 scope**: single repo — `build-pipeline-repo`'s
  `dev/SECRETS-ROTATION.md` is the only fleshed-out runbook. Cross-repo
  secret discovery is explicitly out of scope for this task.
- **Tier dispatch**:
  - **Auto**: dispatch the existing `rotate-secrets.yml`, poll, report. The
    skill itself never touches 1Password for this tier.
  - **Semi-auto / Manual** (unified flow): print mint instructions from the
    runbook row → explicit confirm ("saved to 1Password?") → `op read` via
    the user's own already-authenticated CLI session → explicit
    confirm-before-overwrite ("about to overwrite live secret `<NAME>` in
    `<repo>` — proceed?") → propagate via a **single piped shell command**
    (`op read "op://vault/item/field" | gh secret set NAME --repo/--org
    <scope>`) so the raw value never enters the assistant's own
    context/transcript → dispatch `secret-health-check.yml` → report.
- **Security invariant**: the read-then-set step MUST run as one piped shell
  command in a single tool call — never split into "read into a variable,
  then set" across two calls, which would surface the value.
- **Rollback**: human-only, via 1Password's own item-version-history UI (not
  exposed by the `op` CLI — confirmed by spike, no `history` subcommand
  exists). The skill's own output, when a post-rotation health check fails,
  should print the step-by-step recovery procedure from [T20260806-374741](https://github.com/your-org/hub-repo/issues/441)'s
  design (open 1Password → "Last edited" → View previous versions → copy old
  value → reset GitHub secret → re-verify → do NOT re-save the old value
  into 1Password's current field).

## Solution

- Scaffold as a new skill in `ccxp-skills` (SKILL.md + any helper scripts),
  following this repo's existing skill conventions (see `/drive`, `/todo`,
  and the existing `1password-env-setup` skill for structure precedent).
- Implement against the 3 worked examples from the design
  (`CLOUDSMITH_ENT_TOKEN` Auto, `CLOUDSMITH_API_KEY` Semi-auto,
  `SLACK_WEBHOOK_URL` Manual) as the concrete test cases.
- Design first: this task should still get its own brainstorm/design-review
  pass for implementation details (file layout, exact confirmation prompt
  wording, how the runbook row gets parsed) before writing code, per this
  org's "design first, implement second" convention — [T20260806-374741](https://github.com/your-org/hub-repo/issues/441)
  settled the *behavior*, not the *implementation*.

## Test plan

- [ ] Dry-run against `CLOUDSMITH_ENT_TOKEN` (Auto tier) — dispatches
      `rotate-secrets.yml`, reports correctly.
- [ ] Dry-run against a Semi-auto or Manual secret with a throwaway/test
      1Password item and a scratch GitHub secret (not a real production
      secret) — confirm the piped read+propagate step never surfaces the
      value anywhere in the transcript.
- [ ] Confirm the confirm-before-overwrite gate actually blocks on a "no"
      reply.

## Done criteria

- [ ] `/rotate-1password <secret>` works end-to-end for all three worked
      examples.
- [ ] Security invariant verified: raw value never appears in the skill's
      own output, logs, or the assistant's conversation transcript.

## Out of scope

- Cross-repo secret discovery ([T20260806-374741](https://github.com/your-org/hub-repo/issues/441) v2 follow-on, not yet filed).
- The `rotate-secrets.yml` extension to write Auto-tier values into
  1Password — separate task, [T20260808-413336](https://github.com/your-org/hub-repo/issues/455).

## Dependencies

- ~~**[T20260806-374741](https://github.com/your-org/hub-repo/issues/441)** — the finalized design this implements.~~ ✅ Done (see hub-repo's dev/JOURNAL/2026-08-08-T20260806-374741-rotate-1password-skill-design.md)
- **[T20260806-240910](https://github.com/your-org/hub-repo/issues/440)** — 1Password → doc links; useful but not a hard
  blocker (the skill can work from the runbook's own item names if those
  links aren't in place yet).

## Migrated (2026-09-14)

- Migrated from `hub-repo/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: your-org/private-skills-repo` field (set 2026-08-08, before
  the ccxp-skills split shipped) is stale: this is a generic dev-tool skill
  with nothing HashData-specific, the same category `1password-env-setup`
  already lives in — landing here directly instead of `private-skills-repo`.
