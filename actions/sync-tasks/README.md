# tasks ↔ issues mirror (canonical)

This is the single source of truth for how adopting repos mirror their
`dev/{TODO,PARKING,JOURNAL}/*.md` task files to GitHub Issues + Project V2.
Consumer repos call it via `uses: your-org/ccxp-skills/actions/sync-tasks@v1`
— they no longer carry their own copy of the script or this doc.

## Usage (consumer caller workflow)

```yaml
- uses: actions/checkout@v6
  with: { fetch-depth: 2 }
- uses: your-org/ccxp-skills/actions/sync-tasks@v1
  with:
    mode: ${{ github.event.inputs.mode || 'sync' }}
    gh-token: ${{ secrets.GITHUB_TOKEN }}
    project-pat: ${{ secrets.PROJECT_PAT }}
    project-owner: your-org
    project-number: '1'
```

`project-owner`/`project-number` are required for Project V2 field sync — no
default is baked into the action. Without them (even with `project-pat` set)
the action degrades to Issue-only mode; see "Auth and scopes" below.

Modes: `sync` (push-driven diff), `backfill` (create missing issues),
`reconcile` (idempotent board self-heal — safe as a heartbeat), `dry-run`.

---

## What syncs and what doesn't

| Aspect | Synced? |
|--------|---------|
| File appears in `dev/TODO/` | ✅ Issue created (open) |
| File moves `dev/TODO/` → `dev/JOURNAL/` | ✅ Issue closed with reason `completed` + comment linking to the JOURNAL path |
| File moves `dev/TODO/` → `dev/PARKING/` | ✅ Issue closed with reason `not_planned`, labelled `parked` |
| File moves `dev/PARKING/` → `dev/TODO/` | ✅ Issue reopened, `parked` label removed |
| File moves `dev/PARKING/` → `dev/JOURNAL/` | ✅ `parked` label removed + comment (issue stays closed) |
| File moves `dev/JOURNAL/` → `dev/TODO/` (rare) | ✅ Issue reopened |
| File deleted entirely | ✅ Issue closed with reason `not_planned` |
| Title change in the file (H1 edit) | ❌ Not synced — title set once on Issue creation |
| Body edits to the task file | ❌ Not synced — Issue body is a fixed pointer with a permalink |
| Manual edits to the Issue body or title in the GitHub UI | ❌ Not synced back. File-is-truth. |

The Issue body is always:

```
**Task file**: [<path>](https://github.com/<repo>/blob/main/<path>)

<one-line note about TODO/PARKING/JOURNAL>

This Issue is a thin pointer ...
```

For the authoritative content (frontmatter metadata + body), read the linked file.

## Issue ↔ file linking

The task↔issue mapping is **derived at runtime** by `build_index()` in the sync
script — there is no committed state (T20260610-023106 retired the old
`.github/task-issue-map.json` sidecar; its persist-PR flow could not reliably
self-merge under branch protection and redded runs — RCA in JOURNAL
T20260608-125662):

- At the start of every run, the script lists **all** issues (REST list — the
  search API's index lags by seconds and would spawn duplicates for
  just-created issues) and recovers each issue's task ID from the body's
  task-file permalink, falling back to the title. The task ID is the join key
  (the `TYYYYMMDD-NNNNNN` pattern in the linked filename).
- Idempotency comes from the derived index: backfill skips any task that
  already has an issue, exactly as the committed map used to guarantee.
- The index also pre-resolves each issue's Project V2 item id in one paginated
  GraphQL query.
- If the repo ever exceeds the 1000-issue list cap the run logs a loud
  `index: WARNING` — raise the cap before trusting backfill again.

The derived index replaces frontmatter `issue: #N` reflection because the file
is supposed to stay declarative; the Issue # is generated metadata, not
authored metadata.

## IPM-weekly issues (T20260608-264027)

A consuming repo's `dev/JOURNAL/<Monday>-ipm-weekly.md` (the Iteration Planning
Meeting doc that commits a week's task list — see `/ccxp` Phase 2a) is also
synced to a GitHub Issue, so the Project's iteration view shows the IPM doc
alongside that iteration's task issues. This is a **separate, parallel** sync
path from the task-issue mirror above — IPM issues key on the file's own
Monday date, not a task id:

- `build_ipm_index()` derives `{date: {issue, node_id}}` the same way
  `build_index()` derives the task map, but recovers the date from a hidden
  `<!-- ipm:YYYY-MM-DD -->` marker in the Issue body (written by
  `ipm_issue_body()`) rather than a task-file permalink.
- A `/stage`-written **pre-IPM staging stub** (header `**Status**: Pre-IPM
  staging` — candidates accrued for next Monday, not yet committed) never
  gets an Issue. Only a *committed* IPM file syncs; the stub-to-committed
  transition (the IPM-commit commit that drops the staging marker) is what
  triggers issue creation.
- The synced Issue gets exactly one Project field: **Iteration**, resolved via
  the existing `find_iteration_id()` against the file's own date (same lookup
  a task's `scheduled:` value goes through).
- `sync`, `backfill`, and `reconcile` modes all participate — no new workflow
  trigger needed; the IPM scan piggybacks on the existing push/dispatch
  cadence.
- **Issue lifecycle**: the IPM issue is closed at iteration end by `/retro`
  (which already runs at iteration end), mirroring the task-issue close
  lifecycle. `sync.py` itself never closes an IPM issue — IPM files are a
  permanent `dev/JOURNAL/` record and are never moved/deleted the way task
  files are.

## Triggers

Consumer repos wire this action from their own caller workflow. A typical trigger
set (adapt paths and schedule to taste):

| Trigger | When | Mode |
|---------|------|------|
| `push` to `main` touching `dev/{TODO,PARKING,JOURNAL}/**` or the caller workflow | Every relevant merge | `sync` |
| `workflow_dispatch` with input `mode: backfill` | One-time at first rollout, or any time a file slipped through (e.g., legacy bullet-format file that lacks frontmatter and was created pre-mirror) | `backfill` |
| `workflow_dispatch` with input `mode: dry-run` | Debugging — logs intended actions without making API calls | `dry-run` |

`workflow_dispatch` is run from the Actions tab → "Sync tasks to GitHub Issues" → "Run workflow" → pick mode → Run.

## Auth and scopes

The action uses `gh-token` (typically `GITHUB_TOKEN`) for Issue create/update/close — that's sufficient for everything documented above. Issues end up in the repo's default Issues list and are eligible for any Project board configured to auto-add new Issues from this repo.

For richer integration (adding Issues directly to a Project V2 board with field values mapped from frontmatter), pass `project-pat: ${{ secrets.PROJECT_PAT }}` **plus** `project-owner`/`project-number` (the org login + board number — no default, required together with the PAT). All three unset (or `project-owner`/`project-number` alone missing while `project-pat` is set) runs Issue-only mode; all three set projects frontmatter onto Project V2 fields — see the field table below for the mapped set.

## Backfill procedure

After a consumer repo first wires the caller workflow:

1. Go to **Actions** tab → **Sync tasks to GitHub Issues** → **Run workflow** → choose `mode: backfill` → **Run workflow**.
2. The job iterates all `dev/TODO/*.md` and `dev/PARKING/*.md` files and creates one Issue per file that has no issue yet (per the runtime-derived index — nothing is committed back).
3. PARKING files get a `parked` label and are closed immediately with `not_planned`.
4. Re-running backfill is idempotent — no duplicates.

## Conflict resolution

**The file always wins.** If you edit the Issue body or title in the GitHub UI, those edits are not synced back, and the next time the action runs for this file (e.g., on file move), the Issue may be replaced with the canonical pointer body.

If you want to record a discussion or update against a task, prefer:

- Editing the task `.md` file (the canonical record), OR
- Adding a comment on the Issue (comments are not touched by the action)

## Known gaps

- **Project field sync (partial)**: With `project-pat` set, the action projects Status, Start date, End date, Estimate, Blocked by, Iteration, and the claim-lock field (`claimed_by`) from frontmatter. **Priority** and **Source Repo** are not yet mapped.
- **Title sync**: H1 edits in the task file don't propagate to the Issue title. Acceptable for now per the "no body diff" design decision; revisit if title staleness becomes a problem.
- **Legacy bullet-format files**: The script reads YAML frontmatter for the title fallback. Legacy bullet-format files (filed before the 2026-05-14 frontmatter migration) still work because we extract the H1 directly from the body, not from frontmatter.

## Cross-references

- [ccxp-skills#52](https://github.com/your-org/ccxp-skills/pull/52) — frontmatter convention codified
- [hub-repo#90](https://github.com/your-org/hub-repo/pull/90) + [build-pipeline-repo#747](https://github.com/your-org/build-pipeline-repo/pull/747) — file migration to frontmatter
