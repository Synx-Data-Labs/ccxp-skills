---
status: Open
estimation: 2d
source: 2026-09-23 interactive session with Shine, split off T20260418-124634 (synxdb-team)
related: T20260418-124634 (synxdb-team — Drata/SOC2 readiness, the driving requirement)
owner: Xin Zhang (Shine)
---

# T20260923-343482: Build App-auth merge workflow using synx-merge-bot, so required-review branch protection needs no bypass list

## Problem

- Drata's SOC2 checks "Formal Code Review Process" (DCF-5) and "Only
  Authorized Employees Change Code" (DCF-4) require GitHub branch
  protection with enforced code review — currently failing on `main` for
  every repo (`Formal Code Review Process`/`Only Authorized Employees
  Change Code`, `lastPassedAt: null` since 2025-05-07).
- Today, `_gh/gh.sh`'s only real merge call site
  (`address-pr/SKILL.md:309`, `gh pr merge --rebase --delete-branch`) runs
  as whichever human `gh`-authenticated account has repo access — there is
  no formal GitHub review approval step, only PR comments from the
  independent-review agent. Turning on required-approving-reviews branch
  protection as-is would either block every existing auto-merge, or
  require bypass-listing the human account (a weak control an auditor
  would flag — the same account could then bypass review on its own
  pushes).
- A dedicated GitHub App, `synx-merge-bot` (App ID `5052747`, owned by
  `Synx-Data-Labs`, permissions: Contents read/write, Pull requests
  read/write, Metadata read-only — already created and installed on
  `synxdb-team`, `synxdb-build-pipeline`, `ccxp-skills`, and other repos),
  gives us a distinct, minimally-scoped identity to submit real approvals
  from. Credentials are in the `SYNX_MERGE_BOT_APP_ID` /
  `SYNX_MERGE_BOT_APP_PRIVATE_KEY` org secrets and in 1Password (`GitHub
  App - synx-merge-bot`, SynxDB Build vault).

## Design (agreed 2026-09-23, brainstorming session with Shine)

**Goal**: every PR gets a real, formal GitHub review approval — from a
different identity than whoever authored it — before it merges. No
bypass list needed anywhere, since nothing is being bypassed.

- **New**: `_gh/gh-app-token.sh` — mints a short-lived `synx-merge-bot`
  installation token (reads App ID + private key from the 1Password item
  above, signs a JWT, exchanges it via GitHub's App-auth flow), scoped to
  the target repo, printed to stdout.
- **Changed**: `address-pr/SKILL.md`'s merge step. Replace
  `bash ../_gh/gh.sh pr merge --rebase --delete-branch` with:
  1. Mint the bot token via the new script.
  2. `GH_TOKEN=<bot-token> gh pr review <n> --approve --body "..."` — a
     real formal approval (the body can restate what the independent
     review already found), from `synx-merge-bot`, never the PR's author.
  3. `GH_TOKEN=<bot-token> gh pr merge <n> --auto --rebase --delete-branch`
     — arms GitHub's native auto-merge; GitHub itself performs the merge
     once the approval and CI are both satisfied.
- **Consistent policy, no tiers exempted** (Shine's explicit call): every
  merge tier — docs-only, status-change, claim PRs included, not just
  "real implementation" PRs — goes through the same approve-then-auto-merge
  sequence. All tiers already open a real PR today, so none of them need a
  different code path.
- **Branch protection**, rolled out per repo:
  `required_approving_review_count: 1`, empty bypass list.
- **`pre-merge-check.sh`**: add a check that no unresolved
  requested-changes review exists from a prior pass (defensive — fails
  fast/loud rather than leaving a PR stuck in "auto-merge armed, never
  fires").

### Rollout (phased, not a big-bang flip)

1. Build `_gh/gh-app-token.sh`; verify standalone (mint a token, use it to
   read/comment on a real PR) — no behavior change yet.
2. Wire the new approve+auto-merge sequence into `address-pr/SKILL.md`.
   Flip required-review branch protection on **`ccxp-skills` first** (this
   tooling's own home repo, already dogfooded by every `/drive` cycle).
3. Watch several real merges go through end-to-end before rolling
   required-reviews out to `synxdb-team`, `synxdb-build-pipeline`, and any
   other repo in scope.
4. Update the guidelines templates (`dev/guidelines.md`,
   `repo-conventions/templates/guidelines.md`, `repo-conventions/scripts/mode.sh`)
   so newly-created repos document the new flow from day one.

### Alternatives considered

- **Bypass-list a merge-only bot** (the originally-sketched approach) —
  rejected: still requires a bypass list, which is a weaker control than
  "no bypass needed because real approvals always exist," and Shine
  specifically wants PR authorship to keep reflecting the human who made
  the change, not a bot.
- **Full identity swap of `_gh/gh.sh`** (bot authenticates for every
  operation, not just approve/merge) — rejected: breaks
  `address-pr/scripts/auto-pick.sh`'s `--author @me` filtering (PRs would
  show as bot-authored, not human-authored), and doesn't match Shine's
  goal of the repo reflecting who actually made the change.
- **workflow_dispatch-based token minting** (mirroring
  `synxdb-build-pipeline`'s `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY`
  pattern, minting inside GitHub Actions) — considered, but the local
  1Password service-account access already used throughout this
  toolchain (e.g. `GITLAB_WRITE_TOKEN` today) makes local JWT minting via
  `_gh/gh-app-token.sh` simpler and synchronous, avoiding
  `workflow_dispatch`'s async "how do I learn the outcome" problem.

## Test plan

- [ ] `_gh/gh-app-token.sh` mints a valid installation token standalone
      (verified against a real PR read/comment call).
- [ ] A real PR on `ccxp-skills` goes through approve → auto-merge and
      lands, with the approval visibly from `synx-merge-bot` and the PR
      still authored by the human/existing account.
- [ ] `required_approving_review_count: 1` verified live on `ccxp-skills`
      branch protection, empty bypass list.
- [ ] At least 3 real `/drive`/`/address-pr` merges on `ccxp-skills`
      succeed end-to-end post-rollout before extending to other repos.
- [ ] `pre-merge-check.sh`'s new unresolved-requested-changes check has a
      bats regression test (repo convention — script changes get TDD
      coverage, see `dev/guidelines.md`).

## Done criteria

- [ ] `synx-merge-bot` approves and auto-merges real PRs on `ccxp-skills`.
- [ ] `ccxp-skills` branch protection has required-approving-reviews on,
      no bypass list.
- [ ] Rolled out to `synxdb-team` and `synxdb-build-pipeline` (or
      explicitly deferred with a reason, if rollout pace needs to slow).
- [ ] Guidelines templates updated for new repos going forward.
- [ ] T20260418-124634 re-verifies DCF-4/DCF-5 against live Drata data
      once this lands.
