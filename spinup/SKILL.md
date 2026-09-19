---
name: spinup
description: Use when the user explicitly asks to set up, bootstrap, or spin up a repo against these conventions, or bring a repo fully online
disable-model-invocation: false
argument-hint: "[path]"
---

# Spinup

Brings a repo online against this suite's conventions in one pass: checks/fixes `CLAUDE.md`/`guidelines.md`/`dev/` layout via `/repo-conventions`, then dispatches any other setup skill whose trigger condition is detected in the repo (currently: `/1password-env-setup` when a `.env.tpl` is present). Composes around Claude Code's own built-in `/init` rather than duplicating its `CLAUDE.md` generation.

Out of scope: authoring brand-new skills. For that, use `/skill-conventions` + `superpowers:writing-skills` instead.

## Argument

`[path]` — optional, defaults to `.` (the current repo).

## Workflow

1. Resolve `<path>` (default `.`). Verify it's a git repo — if not, stop and report.
2. **CLAUDE.md**: if `<path>/CLAUDE.md` is missing, report that the built-in `/init` command generates one first (a skill cannot invoke a built-in slash command on the user's behalf), then stop — nothing else here is safe to run without a `CLAUDE.md` to check conventions against. If present, continue.
3. **Repo conventions**: run `/repo-conventions check` against `<path>`. One `check` run can report two independent categories at once — handle each on its own terms, don't treat "all-clean" as a loop condition to chase:
   - `CLAUDE.md`/`guidelines.md` missing or empty: run `/repo-conventions sync` — it already diffs and asks before overwriting a non-empty file, so `/spinup` inherits that safety instead of re-implementing it. Re-run `check` afterward to confirm *this category* cleared; a report on the next bullet's category is expected and not a reason to retry `sync` again.
   - Everything else `check` reports (task-frontmatter schema, unlinked `T<id>`/`#N` references, etc.): `sync` doesn't touch these. Report them to the user as-is — file paths plus whatever fix command `check`'s own output names (e.g. `lint_refs.py --fix`) — and stop there; this category is outside `/spinup`'s fix surface by design, not an unfinished loop.
4. **Secrets bootstrap**: independent of step 3's outcome — run this regardless of whether step 3 found or fixed anything. If `<path>/.env.tpl` exists, dispatch `/1password-env-setup <path>`. Otherwise skip — most repos don't use the 1Password-backed secrets flow, and "skip" here means don't interrupt mid-flow to announce it, not omit it from step 5's summary.
   - `1password-env-setup`'s own description gates on "the user explicitly asks" — here, the explicit ask is `/spinup` itself. A user asking to bring a repo fully online subsumes its setup sub-steps, the same precedent `/drive` already sets by dispatching `/address-pr`/`/gcpr` without a separate per-call ask.
5. Report a summary: what was checked (including a no-op `.env.tpl` check), what was fixed, and what's still open — for each open item, say *why* it's open (user declined an overwrite, or it's outside `/spinup`'s fix surface per step 3). Point at `/skill-conventions` + `superpowers:writing-skills` for anything that needs a brand-new skill authored — `/spinup` never authors skills itself.

## Important Notes

- Idempotent — safe to re-run; a repo already clean on every check `/spinup` itself can act on (`CLAUDE.md`/`guidelines.md` presence, `.env.tpl` absence) reports so and makes no changes. `/repo-conventions check` may still flag categories outside that surface (frontmatter schema, unlinked references) — those always get reported per step 3, never silently folded into "clean."
- Never overwrites a hand-edited file silently — inherits `/repo-conventions sync`'s and `/1password-env-setup`'s own confirm-before-overwrite behavior; `/spinup` adds no overwrite logic of its own.
- Step 4's detection is a plain file-existence signal, deliberately minimal. Adding more setup skills later (a new detected signal → a new dispatch branch) is future work, not required today.

## Cross-references

- `/repo-conventions` — CLAUDE.md/guidelines.md/`dev/` layout check + sync
- `/skill-conventions` — this suite's conventions for authoring a SKILL.md
- `/1password-env-setup` — `.env`/`.envrc` bootstrap from `.env.tpl`
- `superpowers:writing-skills` — generic skill-authoring, deferred to for authoring new skills
