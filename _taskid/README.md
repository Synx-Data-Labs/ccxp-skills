# `_taskid/` — task ID lib

Shared helpers for the canonical `TYYYYMMDD-NNNNNN` task ID. Used by every skill
that mints or references a task, so the format and link conventions live in one
place.

## Surface

### `new.sh` — mint an ID

```bash
bash ~/.claude/skills/_taskid/new.sh                 # one ID to stdout
bash ~/.claude/skills/_taskid/new.sh --check ./dev   # retry until unused under dev/{TODO,PARKING,JOURNAL}
# sourceable:
source ~/.claude/skills/_taskid/new.sh; id=$(task-id-new)
```

**Minting an ID is not filing a task.** Create `dev/TODO/<id>-<slug>.md`
(from `repo-conventions/templates/task.md`) *before* referencing the ID
anywhere else — code comments, test names, commit messages, other task
files. An ID with no task file is an orphaned reference: nothing a future
reader can open to see what it tracks. `check-orphaned-refs.sh` below is
the backstop for when this slips; it's not a substitute for doing it in
order.

### `check-orphaned-refs.sh` — catch a minted-but-never-filed ID

```bash
bash ~/.claude/skills/_taskid/check-orphaned-refs.sh                          # whole repo (excl. dev/)
bash ~/.claude/skills/_taskid/check-orphaned-refs.sh --changed-only           # vs origin/main
bash ~/.claude/skills/_taskid/check-orphaned-refs.sh --changed-only <base>    # vs a specific ref
bash ~/.claude/skills/_taskid/check-orphaned-refs.sh path/to/file.sh ...      # explicit paths
```

Scans for `T<id>` references outside `dev/` and confirms each resolves to a
`dev/{TODO,PARKING,JOURNAL}` file via the same glob `url.sh`'s `taskid-path`
uses. `dev/` itself is excluded from the default/`--changed-only` scans —
task files legitimately cross-reference sibling IDs (`related:`,
`blocked-by:`) that may not exist as files yet; that's a different,
already-handled concern (see `/todo sweep`), not this check's job. Exit 1 lists
every orphaned occurrence; exit 2 on a bad `--changed-only` base ref (fails
loud, not a silent "0 files changed" pass). Wire `--changed-only` into a
repo's `pre-merge-check.sh` to gate PRs on it.

### `url.sh` — resolve an ID to a clickable GitHub URL

Map-free (T20260610-023106): the blob path is resolved by globbing
`dev/{TODO,PARKING,JOURNAL}/` in the cwd repo (zero network), so links survive a
task file moving `TODO → JOURNAL` on close; the issue number is resolved via
`gh issue list --search` (the sync-tasks bot's issue body carries the task-file
permalink, so the search matches even issues whose titles lack the ID). Repo
slug is derived from `origin`, so it works in any repo with the `dev/` layout.

```bash
bash ~/.claude/skills/_taskid/url.sh T20260427-298901           # blob URL to the current file
bash ~/.claude/skills/_taskid/url.sh T20260427-298901 --issue   # stable issue URL (never rots)
bash ~/.claude/skills/_taskid/url.sh --slack T20260427-298901   # Slack mrkdwn <url|TID>
# sourceable:
source ~/.claude/skills/_taskid/url.sh
url=$(taskid-url  T20260427-298901)
link=$(taskid-slacklink T20260427-298901)   # for slack_send_message (mrkdwn <url|text>)
```

- **Default** target is the task's current file (`blob/main/<path>`).
- **`--issue`** targets the GitHub issue — use it when the link must never 404,
  even years later.
- **Unresolvable** tasks (no local file match / `gh` unavailable or no issue
  hit) fall back to a repo code-search link, so a reference is always clickable.
- `TASKID_URL_BRANCH` overrides the blob branch (default `main`).
- `TASKID_GH` overrides the `gh` command (tests inject a stub; defaults to the
  account-aware `_gh/gh.sh` wrapper when installed, else raw `gh`).

Consumers: `/ccxp` daily-standup Slack message. (In-repo markdown digests use
*relative* links + a move-rewrite instead — see the build-pipeline task
`T20260608-353422`; this lib is for *absolute* links on external surfaces like Slack.)

## Tests

`tests/taskid_url.bats`, `tests/taskid_check_orphaned_refs.bats` (run with `bats tests/`).
