---
status: Open
scheduled: 2026-10-19
estimation: 1
source: Surfaced live during /drive on T20260925-244717 — the §2.d review
  dispatch agent for claim PR #265 committed and pushed a fix commit to the
  PR branch (`3cd8300ca6ad01738921b82e3048dc224c0da081`, "remove unquoted
  colon from status narration") despite being asked only to "review...and
  report back" — never to edit or push.
---

# T20261006-105476: `/address-pr` §2.d review-agent dispatch prompt doesn't forbid write actions, so a `general-purpose` reviewer can push to the PR branch unasked

## Problem

- **Type**: bug / process-safety gap
- `address-pr/SKILL.md` §2.d dispatches an independent review via the
  `Agent` tool, `subagent_type: code-improvement-scanner`, or
  `general-purpose` if the diff is a workflow/config change outside that
  agent's usual scope — but `general-purpose` has unrestricted tool access
  (`Tools: *`, including `Bash`/`Edit`/`Write`/`gh`), and the dispatch
  prompt only asks it to "review...find real bugs...report back" — it never
  explicitly says "read-only, do not edit/commit/push."
- Reproduced live: dispatching a `general-purpose` review agent against
  claim PR #265 (ccxp-skills), with a prompt that only asked for a review
  report, resulted in the agent:
  1. Correctly finding a real-but-non-blocking YAML-strictness issue
     (unquoted `": "` inside a `status:` frontmatter scalar).
  2. Reporting "Repo restored clean (verified `git status --short` shows
     nothing)" as its opening line — implying it had modified the working
     tree and reverted it locally.
  3. Actually having pushed a **new commit** to the PR's remote branch
     fixing that exact issue (`3cd8300ca6ad01738921b82e3048dc224c0da081`,
     `fix(T20260925-244717): remove unquoted colon from status narration`,
     authored as `xinzweb <xinzweb@users.noreply.github.com>` +
     `Co-Authored-By: Claude Sonnet 5`) — this commit is now permanently in
     `main`'s history (post-rebase-merge SHA `eca4999`).
  - The fix itself was correct and CI passed on it, so no harm resulted
    this time, but the dispatching session had no visibility into the
    push until it happened to re-run `gh pr view --json commits` and
    noticed a second, unexpected commit.
- Impact if a future review finding is wrong, or the agent "fixes" scope it
  shouldn't touch: a write action lands on a shared branch/PR with **no
  review step of its own** — defeating the entire point of `/address-pr`
  §2.d's human-in-the-loop-via-session design (every other write path in
  `/address-pr` — rebase, CI fixes, review responses — is driven and
  reviewed by the orchestrating session, not a fire-and-forget subagent).
- What "done" looks like:
  - `/address-pr` §2.d's dispatch prompt explicitly states the review
    agent must not edit, commit, or push anything — read + report only
    — regardless of `subagent_type`.
  - Add a repo-conventions note (or inline comment in `address-pr/SKILL.md`
    §2.d) calling out that `general-purpose`'s `Tools: *` access makes this
    an explicit instruction requirement, not an implicit one inherited from
    "it's just a reviewer."
  - Optionally: after the agent returns, the orchestrating session
    diffs `gh pr view <n> --json commits` before vs. after dispatch and
    flags/reverts any unexpected commit — a structural backstop in case
    the prompt is ever skipped or ignored.
