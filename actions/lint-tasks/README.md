# lint-tasks (task-frontmatter lint)

Validates `dev/TODO/` + `dev/PARKING/` task-file frontmatter against the canonical schema (`repo-conventions/templates/task.md`). Wraps `repo-conventions/scripts/lint_tasks.py`.

Two kinds of check:

1. **Per-file schema** — required fields, status/estimation format, the field allowlist, filename, H1↔filename id. Scoped to the PR's changed task files in `changed` mode (so legacy drift never blocks an unrelated PR).
2. **Board-wide blocked-by cross-reference** — every `status: Blocked by T<id>` must name a *live* blocker (a file in `dev/TODO`/`dev/PARKING`). A blocker already Done (moved to `dev/JOURNAL/`) or resolving to no file at all fails the lint. This is the **stale-block / missed-cascade-unblock gate**: it runs over the whole board on every task PR — **regardless of the changed-file set** — because a block goes stale in the PR that *closes the blocker*, which never touches the blocked file. Keyed on `status:` only, not the free-text `blocked-by:` field (that field carries prose / strikethrough historical notes).

## Usage (consumer caller workflow)

Add to a consumer repo as `.github/workflows/lint-tasks.yml`:

```yaml
name: Lint task frontmatter
on:
  pull_request:
    # JOURNAL is required: a close-PR (TODO→JOURNAL) is what makes a dependent's
    # block go stale, so the gate must trigger on JOURNAL changes too.
    paths: ['dev/TODO/**', 'dev/PARKING/**', 'dev/JOURNAL/**']
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0   # needed so the action can diff against the base branch
      - uses: your-org/ccxp-skills/actions/lint-tasks@vN   # pin the current tag
```

`mode` defaults to `changed` (schema-gates only the PR's changed task files; the board-wide blocked-by pass always runs). Use `mode: all` for a full schema sweep.

## Versioning

Pinned by immutable `@vN` tag, same as `sync-tasks`. Ship changes by cutting a NEW tag and bumping consumers — never move a tag.
