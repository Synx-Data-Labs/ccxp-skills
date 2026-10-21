---
status: Design
estimation: 1
source: user request in this conversation, 2026-10-21
related: T20261019-181127
claimed_by: cc1-50ac6891:2c66f4d3357f511f
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261021-289402: customer-support triage: the tracking comment must carry a full clickable URL to the task file

## TLDR

- **Type**: bug
- **Problem**: `triage --task <repo>#T<id>` posts a comment whose reference is not a GitHub autolink, so readers cannot reach the task.
- **Solution**: new `customer-support/scripts/task_url.sh` resolves the task file via the GitHub API at triage time; `transition.sh` posts a markdown link plus the bare SHA-pinned permalink, and fails loudly before posting anything when it cannot resolve.

## Problem

- `customer-support/scripts/transition.sh:71` posts `Tracked internally as ${ref}` verbatim; `<repo>#T<id>` is not `owner/repo#<number>`, so GitHub renders plain text (seen on synxdb-support #14, #29, #33, #34; verified).
- Impact: support readers and customers-facing staff cannot open the backing task from the issue.
- The existing BATS (`tests/customer_support_transition.bats:72,81`) pin the old body text, so they change with this fix.

## Context

- `--task` was added by T20261019-181127 (PRs #366/#369); `cs-gh` (`labels.sh:15`) is the `CS_GH` seam tests already stub.
- Task files live at `dev/TODO/<id>-<slug>.md`, move to `dev/JOURNAL/<date>-<id>-<slug>.md` at close, and are filed through a PR first (file absent from the default branch until merge).
- No idempotency marker exists in the triage comment today (verified by `git grep`); none is added (scope), the label gate already makes a second triage a state-machine error.

## Solution

- New `customer-support/scripts/task_url.sh` (sourceable, `cs-task-url <ref>`), all I/O through `cs-gh api` so auth, private repos and test fakes share one path:
  - Parse `<repo>#T<id>` or `<owner>/<repo>#T<id>` (owner defaults to the support repo owner); anything else is rejected with a clear message.
  - Default branch via `repos/O/R`; `GET contents/dev/TODO?ref=<branch>` for `<id>-*.md`, else `contents/dev/JOURNAL` for `*-<id>-*.md`; else open PRs found by `search/issues` (`<id> is:pr is:open repo:O/R`) whose files include `dev/TODO/<id>-*.md`.
  - Print `<kind>\t<url>\t<title>`; kind is `main`, `journal` or `pr`. Title is the task file's `# T<id>: ...` H1 read through the raw contents API.
- **Link-rot decision**: the URL is a **permalink pinned to the default-branch commit SHA** at triage time (`blob/<sha>/<path>`). A pinned blob keeps resolving after the task moves TODO -> JOURNAL, unlike `blob/main/...`. Rejected: live `blob/main` link (404 after close), posting both (the live half rots and misleads), code-search redirect (needs auth, unstable).
- PR-only task: link the file at the PR head SHA in the head repo and state that the filing PR `<url>` is still open; JOURNAL task: pinned permalink to the journal file.
- Comment body (human text kept): `Tracked internally as [<ref>](<url>) — <title>` then a blank line and the bare `<url>`; the PR case adds a line naming the open PR.
- Missing task, unreadable repo (404/403, including a private repo without access): `transition.sh` returns non-zero with a message naming the cause and `gh auth`, **before** the comment and before the label moves. No token is ever echoed.
- `--task` argument form unchanged (`<repo>#T<id>`; `<owner>/<repo>#T<id>` newly accepted); plain `triage` unchanged.
- Docs: `customer-support/SKILL.md` triage row and a short Tracking comment note; the label names stay sourced from `label_names.sh` (no literals added).

## Test plan

- [ ] BATS (fake `CS_GH`) in `tests/customer_support_task_url.bats`: task on main, task only on an open PR, task in JOURNAL, missing task, repo not readable (private, no auth), bad ref.
- [ ] Update `tests/customer_support_transition.bats`: comment body now carries the URL; missing task posts nothing and moves no label; body stays one argv element even with metacharacters in the title.
- [ ] CI: bats, Markdown Lint, lint-tasks, skill-quality green.
- [ ] Post-merge read-only: list existing synxdb-support tracking comments lacking `https://` (follow-up list for the user; nothing edited).

## Done criteria

- [ ] Comment carries a full https URL and keeps the readable text (`tests/customer_support_transition.bats`, triage --task test).
- [ ] Main, PR-only, JOURNAL, missing, private-repo cases (`tests/customer_support_task_url.bats`).
- [ ] Failure posts nothing and moves no label (`tests/customer_support_transition.bats`).
- [ ] SKILL.md documents the form (`customer-support/SKILL.md` triage row).

## Root cause

- The convention in `transition.sh:69-72` (introduced by T20261019-181127, PR #369) treated the reference as display text; an oversight, not a decision: the task file path was never resolved.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `customer-support/scripts/transition.sh` | `62-72` | posts the comment; switch to resolved URL |
| `customer-support/scripts/task_url.sh` | new | resolver |
| `customer-support/SKILL.md` | `31` | document form |
| `tests/customer_support_transition.bats` | `60-90` | update expectations |
| `tests/customer_support_task_url.bats` | new | resolver cases |

## Escalations

- Slack skipped by instruction; none needed.
