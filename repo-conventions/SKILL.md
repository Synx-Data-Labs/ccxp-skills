---
name: repo-conventions
description: Use when setting up or checking a repo against these conventions — CLAUDE.md/guidelines.md structure, dev/ TODO lifecycle, or the conventions lint
disable-model-invocation: false
argument-hint: "[check|sync|show|setup {team|solo}]"
---

The single source of truth for how Your Company repos structure their `CLAUDE.md`, `dev/guidelines.md`, and `dev/{TODO,PARKING,JOURNAL}/` lifecycle. Each repo's `CLAUDE.md` stays repo-specific (purpose, deps), but defers conventions here so we don't re-litigate them per repo.

## Argument

- `/repo-conventions check` — lint the current repo's CLAUDE.md and guidelines.md against the rules below
- `/repo-conventions sync` — copy missing sections from templates into the current repo (interactive — asks before overwriting)
- `/repo-conventions show` — print the canonical rules (default if no arg)
- `/repo-conventions setup [team|solo] [--skip-ci-check] [--yes]` — bring the current repo fully online: convention check/sync, `dev/TODO/queue.md` init, secrets bootstrap, and branch-policy convergence, all in one pass (see `setup` below)

## Canonical Rules

### CLAUDE.md

1. **Stay small.** Hard cap: 50 lines / 3 KB. CLAUDE.md is auto-loaded into every session — bloat eats the context budget.
2. **Never journal in CLAUDE.md.** The `dev/JOURNAL/` folder IS the index. Listing entries by date duplicates content, blows the cap, and creates merge conflicts on every completed task.
3. **Point at, don't inline.** Reference `dev/guidelines.md`, `DEPENDENCIES.md`, etc. — never paste their content.
4. **Required sections** (in order):
   - One-paragraph purpose of the repo
   - **Guidelines** — link to `dev/guidelines.md` with a "MUST read" instruction
   - **Task Tracking** — point at `dev/{TODO,PARKING,JOURNAL}/`, with "the folder IS the index"
   - **Context Budget** — table with caps for CLAUDE.md, guidelines.md, memory
5. **Branch rule.** Don't update CLAUDE.md on feature branches that aren't *about* CLAUDE.md. Project-structure changes only.

### dev/guidelines.md

1. **Stay focused.** Hard cap: 200 lines / 8 KB. If it grows past that, split into topic files (`dev/guidelines/branching.md`, `dev/guidelines/scripts.md`, etc.).
2. **Required sections:** Core Principles (KISS/DRY), Branch and Merge Policy, TODO Lifecycle, Script Standards, Documentation.
3. **TODO Lifecycle** must define: task ID format (`TYYYYMMDD-NNNNNN`), status flow (Open → Design → In Progress → Review → Done), the move-to-JOURNAL completion step, and the "no CLAUDE.md journaling" rule.
4. **Documentation must instruct bullet-first writing.** Markdown docs (README, guidelines, task files, JOURNAL entries) should chunk information into bullet points, short lists, and tables rather than long prose paragraphs — write for scanning, not top-to-bottom reading. This is the "Information Mapping" / scannable-content principle: a reader should be able to find the one fact they need without parsing a paragraph to extract it. Reserve prose paragraphs for narrative that genuinely doesn't decompose (e.g. a root-cause story, a rationale). See `templates/guidelines.md`'s Documentation section for the canonical wording.

### dev/ folder layout

```
dev/
  TODO/<id>-slug.md       # Open + in-progress tasks
  PARKING/<id>-slug.md    # Valid but not actionable now
  JOURNAL/yyyy-mm-dd-<id>-slug.md  # Completed — the folder IS the index
  guidelines.md
```

Filesystem is the index — never mirror it elsewhere.

### Task-file frontmatter

Every `dev/TODO/` and `dev/PARKING/` file is linted against a strict allowlist (see `templates/task.md`):

- **Required:** `status`, `estimation`.
- **Authored-optional:** `priority`, `deadline`, `blocks`, `blocked-by`, `source`, `target-repo`, `target-path`, `related`, `owner`, `description`.
- **Runtime (tooling-written):** `scheduled`, `claimed_by`, `iteration`.

Any other top-level key is a violation. `status` must lead with a known value (Open/Design/In Progress/Review/Blocked/Parked/Done; prose suffix allowed) and `estimation` one of `{1, 2, 3, 5, 8}` (points). `dev/JOURNAL/` is exempt (archival).

### Reference linking (`lint_refs.py`)

`dev/TODO/` + `dev/JOURNAL/` files often reference other tasks (`T<id>`) or GitHub issues/PRs
(`#N`) as plain text. `repo-conventions/scripts/lint_refs.py` makes these clickable:

- **T-ids** link to the stable GitHub-issue mirror (via `_taskid/url.sh`'s `taskid-mdlink`).
- **Typed `#N` refs only** — text the author already prefixed with `PR`, `pull request`, or
  `issue` (case-insensitive), e.g. `PR #250` or `issue #99`. The type is verified (and corrected
  if the author guessed wrong) via `gh api repos/<slug>/issues/<n>`.
- **Bare, untyped `#N` is deliberately out of scope**:
  - The corpus has real non-GitHub `#N` (a street/suite number, an ordinal like "the #1
    feature") that a blind resolver would corrupt.
  - There's no reliable text-level signal that a bare `#N` is a GitHub reference at all — an
    author-typed `PR #`/`issue #` prefix is the unambiguous signal this script requires (see
    T20260616-130977 for the false-positive examples that ruled this out).
  - A future task could revisit this with a stronger heuristic (e.g. requiring the number to
    fall in GitHub's actual issue/PR range) if it proves worth the risk.
- A reference that can't be resolved (cross-repo T-id, `gh` failure) is left bare rather than
  guessed at.
- **Auto-fix only** — `lint_refs.py --fix` (wired into `/gcpr`'s doc-lint guard) rewrites files in
  place and never fails the commit; `lint_refs.py --all` (wired into `lint.sh`, read-only) reports
  and fails on any unlinked-but-linkable ref.

### Internal-identifier check (`lint_identifiers.py`)

`repo-conventions/scripts/lint_identifiers.py` catches company-internal identifiers before they
reach a public repo (T20260919-231319) — two independent signal classes:

- **Structural checks, zero config** (on by default, no identifiers hardcoded): private IPv4
  ranges, GitHub/AWS-style credential tokens, personal absolute home-dir paths (`/home/<name>`
  outside a small generic allowlist of CI-runner/cloud-image default account names).
- **An optional denylist, injected only via env var/file, never committed** —
  `INTERNAL_IDENTIFIERS`/`INTERNAL_IDENTIFIERS_FILE` (company/product terms + real personal names,
  each optionally `term=placeholder` for a suggested replacement) and `INTERNAL_PRIVATE_REPOS`
  (private repo slugs, checked against `github.com/<org>/<repo>` links). Unset → empty → a no-op,
  the same env-var-config-not-committed-data posture as `lint_refs.py`'s `KNOWN_SIBLING_REPOS`
  above — this is what keeps the check itself company-agnostic.

- `--all` defaults to `dev/TODO/*.md` + `dev/JOURNAL/*.md` (same `lint_refs.py`-style scope) —
  a whole-repo scan is available but not the CI-wired default; it produced false positives from
  illustrative example IPs and synthetic test-fixture paths elsewhere in this repo, well outside
  the task/journal-authoring channel the two real leak incidents both came through.
- `--fix` substitutes any denylist hit that carries a mapped placeholder; a hit with no mapping
  (or any structural hit) still fails even under `--fix` — nothing safe to substitute — which is
  what gives `/migrate-task` (see that skill) its genericize-or-refuse behavior on its
  `--dry-run` staged copy.

### Authoring a skill

To author or edit a SKILL.md, use the `/skill-conventions` skill — it documents this suite's conventions (Use-when descriptions, dual invocation, argument design, `_<prefix>/` shared libs, BATS, structure) and defers generic authoring to `superpowers:writing-skills`.

## Workflow

### `check` (lint)

Run the lint script and report violations:

```bash
bash ../repo-conventions/scripts/lint.sh
```

Checks (each is a separate exit-code-bearing assertion):

- `CLAUDE.md` exists, ≤ 50 lines, ≤ 3 KB
- `CLAUDE.md` does not contain a journal index (heuristic: no `## YYYY` month headers followed by `dev/JOURNAL/` links)
- `dev/guidelines.md` exists, ≤ 200 lines, ≤ 8 KB
- `dev/{TODO,JOURNAL}/` exist
- `dev/guidelines.md` mentions "TODO Lifecycle"
- each `dev/TODO/` + `dev/PARKING/` file conforms to the task-frontmatter schema (`lint_tasks.py --all`)
- every `T<id>` / typed `PR #N`/`issue #N` reference in `dev/TODO/` + `dev/JOURNAL/` is a clickable link (`lint_refs.py --all`)
- `dev/TODO/` + `dev/JOURNAL/` carry no internal identifier — company/personal denylist hit (config-driven, unset by default), private IPv4, credential token, or personal home path (`lint_identifiers.py --all`)

Report `✅` per check or `❌ <reason>` and exit non-zero on any failure.

### `sync` (templates)

For each missing or empty file, offer to copy from the template:

- `../repo-conventions/templates/CLAUDE.md`
- `../repo-conventions/templates/guidelines.md`

**Always show a diff and ask before overwriting** an existing non-empty file. Never clobber silently.

The `templates/` dir also holds the **per-task scaffolds** — `task.md` (new TODO files, used by `/todo`) and `design-doc.md` (design sections, used by `/drive`). These are copied per *task*, not stamped into a repo, so `sync` leaves them alone.

### `show` (default)

Print this skill's "Canonical Rules" section above. Useful when prepping a new repo.

### `setup [team|solo]` (bring a repo fully online)

Absorbs what `/spinup` used to do, plus branch-policy convergence
(formerly the standalone `mode` verb) — one pass, cwd-scoped like every
other verb here (no `[path]` arg — `/spinup`'s was unused generality;
no caller ever passed a non-default one).

```
/repo-conventions setup [team|solo] [--skip-ci-check] [--yes]
```

The policy arg defaults to `team` only when the repo has **no** existing
policy configured yet (a genuinely fresh repo). On an already-configured
repo (solo or team), omitting the arg preserves the current policy
instead of overriding it — see step 3/7 below. `solo` is still the
explicit choice for a repo that wants it.

1. Verify cwd is a git repo.
2. If `CLAUDE.md` is missing: report that the built-in `/init` command
   generates one first (a skill cannot invoke a built-in slash command on
   the user's behalf), then stop — nothing else here is safe to run
   without a `CLAUDE.md` to check conventions against.
3. **Snapshot the current branch policy before anything below can change
   it.** If no explicit `team|solo` arg was given:
   - Detect the repo's *current* policy right now, using the same
     doc-resolution order and heuristic `mode.sh` uses internally:
     `dev/guidelines.md` first if it has a `## Branch and Merge Policy`
     section, else `CLAUDE.md`, then `grep -qi "no ci"` + `grep -qi
     "direct.to.main"`.
   - Store **both** the result (`solo`, `team`, or `none` if neither doc
     has the section yet) **and which file it came from** — step 7 needs
     both, not a re-detection after step 4's `sync` has run (a
     freshly-`sync`-created `dev/guidelines.md` would otherwise silently
     out-rank a legacy repo's real policy living only in `CLAUDE.md`).
4. **Repo conventions**:
   - Run `sync` unconditionally first — it already does its own per-file
     missing-or-empty detection (see `sync` above) and only acts on
     `CLAUDE.md`/`guidelines.md` when one qualifies, so it's a safe no-op
     on an already-compliant repo.
   - Don't gate this on `check`'s report: `check`'s own line/size caps
     only catch a *missing* or *oversized* `CLAUDE.md`, not a
     present-but-empty one — relying on `check` to decide whether to run
     `sync` would silently miss that case.
   - Then run `check` and report everything it finds (task-frontmatter
     schema, unlinked `T<id>`/`#N` references, etc.) — `sync` doesn't
     touch any of this.
   - Report it to the user as-is: file paths plus whatever fix command
     `check`'s own output names (e.g. `lint_refs.py --fix`). This
     category is outside `setup`'s fix surface by design, not an
     unfinished loop.
5. **Queue init**: if `dev/TODO/*.md` files exist but `dev/TODO/queue.md`
   is missing, dispatch `/todo sweep` to initialize it. Conditional, not
   unconditional — mirrors the `.env.tpl`-presence-gated pattern in the
   next step.
6. **Secrets bootstrap**: independent of step 4's outcome — run this
   regardless of whether step 4 found or fixed anything.
   - If `.env.tpl` exists, dispatch `/1password-env-setup`. Otherwise
     skip — most repos don't use the 1Password-backed secrets flow, and
     "skip" here means don't interrupt mid-flow to announce it, not omit
     it from step 8's summary.
   - Note: `1password-env-setup` replaces a non-identical `.envrc` with
     no confirmation prompt (only a byte-identical file is left alone) —
     it does not ask before overwriting, despite the name.
   - `1password-env-setup`'s own description gates on "the user
     explicitly asks" — here, the explicit ask is `setup` itself; a user
     asking to bring a repo fully online subsumes its setup sub-steps,
     the same precedent `/drive` already sets dispatching
     `/address-pr`/`/gcpr` without a separate per-call ask.
7. **Apply branch policy**, using step 3's snapshot:
   - An explicit `setup team` or `setup solo` arg always wins — use it,
     ignoring the snapshot.
   - Otherwise, use step 3's snapshot:
     - **`solo` or `team` snapshotted** (from doc `<snapshotted-doc>`):
       - Default to that value, and pass `--doc <snapshotted-doc>`
         explicitly: `bash ../repo-conventions/scripts/mode.sh <resolved>
         --doc <snapshotted-doc> [--skip-ci-check] [--yes]`.
       - The explicit `--doc` is required, not cosmetic — `mode.sh`
         always re-resolves its own target doc when `--doc` is omitted,
         `dev/guidelines.md` first, and by the time step 7 runs, step
         4's `sync` may have created a *new* `dev/guidelines.md` that
         would out-rank the `CLAUDE.md` the snapshot actually came from.
       - Pinning makes this a true convergence no-op: `mode.sh`
         re-checks the exact file the snapshot read, and verifies live
         GitHub branch-protection state actually agrees before exiting
         as a no-op — one read-only GET, no mutating call, when live
         state and the resolved arg agree; if they disagree, it falls
         through to the real apply path instead of a false no-op.
     - **`none` snapshotted** (neither doc had the section at snapshot
       time): default to `team`, no `--doc` override (let `mode.sh`
       resolve naturally).
       - Common case — a genuinely fresh repo: step 4's `sync` creates a
         team-worded `guidelines.md`; `mode.sh` resolves to it and
         verifies live state before any no-op. On a repo where
         protection was never actually enabled, live state disagrees
         with the freshly-seeded text, so `mode.sh team` correctly falls
         through and makes the real `PUT` call, gated by the normal
         CI-presence check and confirmation prompt.
       - **Rare edge case**: `guidelines.md` exists, is non-empty, but
         simply lacks the section (so step 4's `sync`, which only fires
         on missing/empty, doesn't touch it, and `check`'s own lint list
         doesn't flag it either).
         - `mode.sh team` hard-errors with its existing "no section
           found — run /repo-conventions sync first" message.
         - `setup` reports this as an open item in step 8, same as any
           other out-of-scope `check` finding, rather than treating it
           as a `setup` failure.
         - Teaching `mode.sh` to *create* a missing section is a
           pre-existing gap, out of scope here.
   - **Known accepted residual**: when the snapshot pins `CLAUDE.md`
     (legacy repo, no pre-existing `dev/guidelines.md`) and step 4's
     `sync` creates a fresh `dev/guidelines.md` from the generic
     team-worded template, the repo ends up with two policy docs that
     disagree in wording:
     - `CLAUDE.md` correctly says `solo`; `dev/guidelines.md` says
       `team`, unused by this run because of the `--doc` pin.
     - Documentation-consistency side-effect, not a safety issue — no
       unwanted mutation occurs — accepted rather than solved here, same
       spirit as the `mode.sh` section-creation gap above.
8. Report a summary: what was checked/fixed/applied; what's still open
   and why (user declined an overwrite, or it's outside `setup`'s fix
   surface per step 4). Point at `/skill-conventions` +
   `superpowers:writing-skills` for anything that needs a brand-new skill
   authored — `setup` never authors skills itself.

Idempotent — re-running on an already-onboarded repo is a no-op at every
step (`check`/`sync` clean, `queue.md` present, no `.env.tpl`, `mode.sh`
already in the snapshotted policy per its live-state verification).

`mode.sh` itself is unchanged by `setup` — same CI-presence hard-refuse,
confirm-unless-`--yes` gate, and live-state-verified no-op as always.
`setup` only resolves which policy arg and `--doc` to pass it (step 7
above) and forwards `--skip-ci-check`/`--yes` straight through:

```bash
bash ../repo-conventions/scripts/mode.sh <solo|team> [--repo OWNER/NAME] [--doc PATH] [--skip-ci-check] [--yes]
```

## Pointing a repo at this skill

Add this single line near the top of the repo's `CLAUDE.md`:

```markdown
**Conventions**: see `/repo-conventions` skill — it defines CLAUDE.md/guidelines.md structure and the dev/ TODO lifecycle.
```

That keeps the host CLAUDE.md small and routes future-Claude here when in doubt.
