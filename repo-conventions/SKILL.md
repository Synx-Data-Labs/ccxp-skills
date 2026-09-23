---
name: repo-conventions
description: Use when setting up or checking a repo against these conventions — CLAUDE.md/guidelines.md structure, dev/ TODO lifecycle, or the conventions lint
disable-model-invocation: false
argument-hint: "[check|sync|show|mode {solo|team}]"
---

The single source of truth for how Your Company repos structure their `CLAUDE.md`, `dev/guidelines.md`, and `dev/{TODO,PARKING,JOURNAL}/` lifecycle. Each repo's `CLAUDE.md` stays repo-specific (purpose, deps), but defers conventions here so we don't re-litigate them per repo.

## Argument

- `/repo-conventions check` — lint the current repo's CLAUDE.md and guidelines.md against the rules below
- `/repo-conventions sync` — copy missing sections from templates into the current repo (interactive — asks before overwriting)
- `/repo-conventions show` — print the canonical rules (default if no arg)
- `/repo-conventions mode {solo|team}` — switch the current repo's Branch and Merge Policy wording and its actual GitHub branch-protection state to match (see `mode` below)

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
3. **TODO Lifecycle** must define: task ID format (`TYYYYMMDD-NNNNNN`), status flow (Open → Design → Coding → Review → Done), the move-to-JOURNAL completion step, and the "no CLAUDE.md journaling" rule.
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

Any other top-level key is a violation. `status` must lead with a known value (Open/Design/Coding/Review/Blocked/Parked/Done; prose suffix allowed) and `estimation` with a duration (`30m`/`2h`/`1d`/`1w`). `dev/JOURNAL/` is exempt (archival).

### Reference linking (`lint_refs.py`)

`dev/TODO/` + `dev/JOURNAL/` files often reference other tasks (`T<id>`) or GitHub issues/PRs
(`#N`) as plain text. `repo-conventions/scripts/lint_refs.py` makes these clickable:

- **T-ids** link to the stable GitHub-issue mirror (via `_taskid/url.sh`'s `taskid-mdlink`).
- **Typed `#N` refs only** — text the author already prefixed with `PR`, `pull request`, or
  `issue` (case-insensitive), e.g. `PR #250` or `issue #99`. The type is verified (and corrected
  if the author guessed wrong) via `gh api repos/<slug>/issues/<n>`.
- **Bare, untyped `#N` is deliberately out of scope** — the corpus has real non-GitHub `#N` (a
  street/suite number, an ordinal like "the #1 feature") that a blind resolver would corrupt, and
  there's no reliable text-level signal that a bare `#N` is a GitHub reference at all. An
  author-typed `PR #`/`issue #` prefix is the unambiguous signal this script requires — see
  T20260616-130977 for the false-positive examples that ruled out resolving every bare `#N`. A
  future task could revisit this with a stronger heuristic (e.g. requiring the number to fall in
  GitHub's actual issue/PR range) if it proves worth the risk.
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

`--all` defaults to `dev/TODO/*.md` + `dev/JOURNAL/*.md` (same `lint_refs.py`-style scope) — a
whole-repo scan is available but not the CI-wired default; it produced false positives from
illustrative example IPs and synthetic test-fixture paths elsewhere in this repo, well outside the
task/journal-authoring channel the two real leak incidents both came through. `--fix` substitutes
any denylist hit that carries a mapped placeholder; a hit with no mapping (or any structural hit)
still fails even under `--fix` — nothing safe to substitute — which is what gives `/migrate-task`
(see that skill) its genericize-or-refuse behavior on its `--dry-run` staged copy.

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

### `mode {solo|team}` (branch-policy switch)

Switches the current repo between **solo** (direct-to-`main`, no CI, no
feature-branch PRs) and **team** (feature branch + PR + CI required) branch
policy — both the doc wording `/claim`/`/drive`'s solo-repo detection reads,
and the actual GitHub branch-protection state on `main`:

```bash
bash ../repo-conventions/scripts/mode.sh <solo|team> [--repo OWNER/NAME] [--doc PATH] [--skip-ci-check] [--yes]
```

- Rewrites the target repo's `## Branch and Merge Policy` section
  (`dev/guidelines.md`, falling back to `CLAUDE.md`) to the canonical
  wording for the requested mode.
- **`team`**: refuses to enable protection with no `.github/workflows/*.yml`
  configured, unless `--skip-ci-check` (for CI hosted elsewhere). Enables
  branch protection requiring PR-based merges (`required_approving_review_count: 0`
  by default — matches this suite's auto-merge tier; raise it later via
  GitHub directly for the wait-for-approval tier).
- **`solo`**: disables branch protection on `main` (tolerates it already
  being absent).
- Already in the requested mode → no-op (no doc rewrite, no API call).
- Mutates live repo security settings — asks for confirmation unless
  `--yes` (required for non-interactive/unattended use).

## Pointing a repo at this skill

Add this single line near the top of the repo's `CLAUDE.md`:

```markdown
**Conventions**: see `/repo-conventions` skill — it defines CLAUDE.md/guidelines.md structure and the dev/ TODO lifecycle.
```

That keeps the host CLAUDE.md small and routes future-Claude here when in doubt.
