---
status: Done
estimation: 1
source: user request in this conversation, 2026-10-21
related: T20261019-181127
claimed_by:
claimed_role:
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
  - Probe `repos/O/R` first: any failure there (404/403, which is also what a private repo without access returns) is reported as "repo not readable (not found or no access; check gh auth)", never as "task missing". Then resolve the default-branch HEAD commit SHA once and **pin every later lookup to that SHA** so the listing and the permalink agree.
  - `GET contents/dev/TODO?ref=<sha>` for `<id>-*.md`, else `contents/dev/JOURNAL?ref=<sha>` for `*-<id>-*.md` (contents listings cap at 1000 entries; not found in a full listing fails loudly and says so).
  - Else open PRs: walk `pulls?state=open&per_page=100` (search/issues is rejected: it matches title/body text, not paths, lags the index and has a tight rate limit), keep PRs whose title, body or head ref mentions `<id>`, and take the one whose `pulls/<n>/files` contains `dev/TODO/<id>-*.md`.
  - Print `<kind>\t<url>\t<title>`; kind is `main`, `journal` or `pr`. Title is the task file's `# T<id>: ...` H1 read through the raw contents API.
- **Link-rot decision**: the URL is a **permalink pinned to the default-branch commit SHA** at triage time (`blob/<sha>/<path>`). A pinned blob keeps resolving after the task moves TODO -> JOURNAL, unlike `blob/main/...`. Rejected: live `blob/main` link (404 after close), posting both (the live half rots and misleads), code-search redirect (needs auth, unstable).
- PR-only task: link the file at the PR head SHA in the head repo and state that the filing PR `<url>` is still open; the PR URL is always included because a fork or head branch can be deleted after merge, and the PR page survives; JOURNAL task: pinned permalink to the journal file.
- Comment body (human text kept): `Tracked internally as [<ref>](<url>) — <title>` then a blank line and the bare `<url>`; the PR case adds a line naming the open PR.
- Missing task, unreadable repo (404/403, including a private repo without access): `transition.sh` returns non-zero with a message naming the cause and `gh auth`, **before** the comment and before the label moves. No token is ever echoed.
- `--task` argument form unchanged (`<repo>#T<id>`; `<owner>/<repo>#T<id>` newly accepted); plain `triage` unchanged.
- Docs: `customer-support/SKILL.md` triage row and a short Tracking comment note; the label names stay sourced from `label_names.sh` (no literals added).

## Test plan

- [x] BATS (fake `CS_GH`) in `tests/customer_support_task_url.bats`: task on main, task only on an open PR, task in JOURNAL, missing task, repo not readable (private, no auth), bad ref.
- [x] Update `tests/customer_support_transition.bats`: comment body now carries the URL; missing task posts nothing and moves no label; body stays one argv element even with metacharacters in the title.
- [x] CI: bats, Markdown Lint, lint-tasks, skill-quality green.
- [ ] Post-merge read-only (done in the final report, not part of this PR): list existing synxdb-support tracking comments lacking `https://` (follow-up list for the user; nothing edited).

## Done criteria

- [x] Comment carries a full https URL and keeps the readable text (`tests/customer_support_transition.bats`, triage --task test).
- [x] Main, PR-only, JOURNAL, missing, private-repo cases (`tests/customer_support_task_url.bats`).
- [x] Failure posts nothing and moves no label (`tests/customer_support_transition.bats`).
- [x] SKILL.md documents the form (`customer-support/SKILL.md` triage row).

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

## Closed (2026-10-21)

- Shipped in ccxp-skills PR #406 (design in #405, claim #403, stage #402); CI green.
- Met: URL in the comment, readable text kept, main/PR/JOURNAL/missing/private cases (`tests/customer_support_task_url.bats`, `tests/customer_support_transition.bats`), failure writes nothing, SKILL.md updated.
- Quality probe: shellcheck clean (info only); `max_fn_lines` regressed by 7 (`cs-transition` grew), recorded, not blocking.
- External: existing synxdb-support tracking comments lacking a URL are listed in the final report for the user to approve; none edited.
- No follow-up tasks filed; no idempotency marker existed, none added.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes in spirit, code-class (tests written with the code; one red-then-fix on the jq precedence)
- Verification (`superpowers:verification-before-completion`): yes, Phase 3.6 + /address-pr gates
- Systematic debugging (`superpowers:systematic-debugging`): no, bugs found were one-step (jq precedence, bash backtick in test)
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr §2.d, pushbacks on #403, fixes on #405

## Escalations

- Slack skipped by instruction; none needed.
