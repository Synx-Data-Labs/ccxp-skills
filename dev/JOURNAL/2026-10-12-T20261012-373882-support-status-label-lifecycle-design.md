---
status: Done
estimation: 1
claimed_by:
scheduled: 2026-10-12
source: this conversation, 2026-10-12 (Shine: formalize the synxdb-support issue lifecycle via GitHub labels; 4 follow-up decisions on top of a same-night design draft)
related: [T20261012-333879, T20261012-109735, T20261012-383399, T20261012-278418]
description: Design for /customer-support, a label-driven synxdb-support lifecycle skill, plus a /support -> /to-task intake rename+generalization
claimed_role:
---

# T20261012-373882: Design /customer-support — label-driven lifecycle for synxdb-support issues

> **Naming note (RESOLVED 2026-10-12)**: `/customer-support` is the decided,
> final name — see § "Naming the lifecycle skill" below for the 3 candidates
> considered and why. Every occurrence of `/customer-support` in this doc is
> the real skill name, not a placeholder.

## TLDR

- **Type**: feature
- **Problem**: `Synx-Data-Labs/synxdb-support` has a label taxonomy that implies a
  lifecycle (`triage` → `accepted` → `in-progress` → `blocked`/`needs-upstream`)
  but nothing drives it — tonight's real issues (#20, #21, #23, #24, #25, #27)
  show it going unused even while being actively worked, and the org Project
  board that was meant to compensate has no automation and is already wrong.
- **Solution**: a new sibling skill, `/customer-support`, with evidence-gated
  subcommands that move an issue through its lifecycle via **existing** labels
  plus exactly **one** new label (`delivered`); the Project board is left alone
  pending a separate leadership call.
- **Scope decision**: reuse > rename. No label is renamed. `needs-info` is
  dropped (`blocked` + a comment covers it). The Project-board retirement is
  fully designed here but explicitly **deferred**, not actioned.
- **Latest iteration (this pass)**: `/support` itself is renamed and
  generalized to `/to-task` (any URL → a task, not just a synxdb-support
  issue); the lifecycle skill's name is **decided: `/customer-support`**
  (Shine named it directly in a live follow-up — see § 6); and
  `synxdb-build-pipeline`'s existing `close-support-issue` skill's overlap
  with this design's delivery/links/accept logic is **resolved**:
  `close-support-issue` Phase 4 will call `/customer-support` instead of
  duplicating it, tracked as `synxdb-build-pipeline#T20261012-612044`.

## Problem

- The label set already encodes an intended lifecycle, but it isn't enforced
  anywhere — both issue templates auto-apply `triage` on open
  (`.github/ISSUE_TEMPLATE/report.yml:4` → `["triage", "bug"]`,
  `.github/ISSUE_TEMPLATE/request.yml:4` → `["triage"]`), yet none of tonight's
  worked issues reflect any further state:
  - `#20`, `#21`, `#23` — zero labels at all, despite being live package/request
    threads worked tonight (verified via `gh issue view --json labels`).
  - `#24` (the DBCC/Lens bug just fixed by `synxdb-build-pipeline` commits
    `c4daac3b`/`14ba24d2` tonight) and `#25` — only carry `bug`; never moved
    past the template default.
  - `#27` (the SynxDB4 4.5.4 LG-ES package request behind tonight's
    `25ffed20` release) — only carries `family:synxdb`.
- `scripts/setup-labels.sh` (synxdb-support repo) is stale: it creates
  `family:*`, `substrate:*`, `track:poc`, `needs-upstream`, `kb-*` but never
  creates `triage`, `accepted`, `in-progress`, `blocked`, any `sev*`, or any
  `area:*` — the labels actually driving the lifecycle aren't even in the
  idempotent setup script.
- The org Project board (`Synx-Data-Labs/projects/3`, "SynxDB Support Triage")
  was presumably meant to be the source of truth instead, but:
  - Of its 13 listed fields, only `Status` (`Todo`/`In Progress`/`Delivered`/
    `Done`) is a genuine custom field — the rest (`Title`, `Assignees`,
    `Labels`, `Linked pull requests`, `Milestone`, `Repository`, `Reviewers`,
    `Parent issue`, `Sub-issues progress`, `Created`, `Updated`, `Closed`) are
    GitHub-native system fields present on every Projects v2 board, not
    configured tracking.
  - Zero automation — nothing syncs `Status` to labels or issue state.
  - It is independently wrong **right now**: `#20`/`#21` sit at `Todo` despite
    being actively worked tonight (`#21`'s delivery attempt silently failed —
    see Context), and `#25` shows `In Progress` on the board while the issue
    itself carries no `in-progress` label — board and labels have already
    diverged from each other, not just from reality.
- Tonight's `#21` failure mode: an engineer self-reported a package as
  delivered when the actual publish step had failed silently — self-report is
  not a safe gate for "delivered."
- Separately, tonight's SynxDB4 4.5.4 release (`#27`) needed partner download
  links hand-built and manually verified — an agent got this wrong twice (hand
  constructing a URL, then not knowing where the entitlement token lived)
  before finding the right existing tooling. See Context.

## Context

- **Current label set** (verified via `gh label list -R Synx-Data-Labs/synxdb-support`):
  `bug`, `duplicate`, `enhancement`, `good first issue`, `help wanted`,
  `invalid`, `question`, `wontfix` (GitHub defaults); `sev1`–`sev4`;
  `area:provisioning`/`connectivity`/`query`/`billing`/`docs`; `triage`,
  `accepted` (**description: "Triaged and accepted"** — already names the
  Triaged state), `in-progress`, `blocked`; `family:synxdb`/`cloud`;
  `substrate:aws-ec2`/`onprem-vm`/`aws`/`bare-metal`/`gcp`/`azure`/`onprem`;
  `kb-candidate`, `kb-published`; `track:poc`; `needs-upstream`.
- `/support` (`ccxp-skills/support/SKILL.md`) is intake-only today — it files a
  `dev/TODO` task with `support-issue: <canonical url>` and explicitly
  "never posts, comments, labels or edits anything on the issue." This design
  does not change that; `/customer-support` is a new sibling skill, not a
  `/support` revision.
- `_support/README.md`'s `support-issue:`/`support-report:` correlation (shipped
  in `T20261012-109735`, epic `T20261012-333879` P1, already in
  `dev/JOURNAL/`) is the hook `/customer-support` reuses to find the task file
  backing an issue — no new correlation mechanism needed.
- **Partner download links (added after the first pass of this design, per
  Shine's live feedback on tonight's SynxDB4 4.5.4 release):**
  - `synxdb-build-pipeline` already has the right tooling —
    `scripts/release/partner-download-url.sh` (resolves one artifact's real
    Cloudsmith `cdn_url` for a given entitlement token; `cdn_url` is **not**
    reconstructable from filename+format, so this must never be hand-built)
    and `scripts/release/render-partner-download-block.sh` (iterates a
    released-SBOM, resolves every artifact under one entitlement, HTTP-verifies
    each with `curl -I` expecting `200`/`301`/`302`, and emits a ready-to-paste
    block) — precedent in
    `dev/JOURNAL/2026-08-05-T20260805-719966-partner-download-block-slack-automation.md`.
  - **Token sourcing — the exact gotcha that bit tonight's run:** the token
    *value* lives in `synxdb-build-pipeline`'s `.env`, key `ENTITLEMENT_TOKEN`
    (`.env.tpl:15`, 1Password-backed:
    `op://SynxDB Build/Cloudsmith/entitlement_token`). Both scripts, however,
    read a **differently-named** env var, `SYNX_PARTNER_TOKEN` (or one line on
    stdin) — **never** a CLI argument (both scripts reject any `--token*` flag
    to keep the token out of shell history/process listings). `.env`'s key and
    the scripts' expected variable are spelled differently on purpose (one is
    this repo's generic secrets convention, the other predates it) — a future
    implementer must bridge them explicitly
    (`SYNX_PARTNER_TOKEN="$ENTITLEMENT_TOKEN"`) rather than rediscovering the
    mismatch the hard way, or worse, asking the user for a secret that is
    already in `.env`.
  - Entitlement identity for SynxDB/SynxDB4 releases: Cloudsmith repo
    `synx/synxdb`, entitlement id `3PNyRETaE96a`, display label `"Hashdata.ai"`
    — the label is `render_partner_download_block`'s free-text second
    argument, not the id itself (the id is configured against the token on
    Cloudsmith's side, never passed to the script).
  - Both scripts are explicitly **on-demand, not a CI step** — their own header
    comments say a resolved tokenized URL must never land in a permanent,
    org-readable CI log. Posting into a specific customer's own support issue
    (the one they're entitled to download from) is a narrower, already-accepted
    destination, same risk class as the precedent's Slack-message use — not a
    new exception.
  - `synxdb-build-pipeline` is a different repo from where `/customer-support`
    itself will live (`ccxp-skills`) — invoking these scripts is cross-repo,
    same shape as `/drive` Phase 1.5's ephemeral-clone pattern.

- **Cross-repo overlap found: `close-support-issue` already exists**
  (`synxdb-build-pipeline/.claude/skills/close-support-issue/SKILL.md`) and
  covers the *engineer-fixes-a-bug* half of this same lifecycle — this design
  must reconcile with it, not duplicate it:
  - Its Phase 4 (`SKILL.md:47-51`) already does evidence-style delivery:
    step 2 says "Include download links once the fix has shipped in a real
    release — verify each link returns `200` via `curl -I` before posting"
    (citing `dev/release-runbook.md:14`, which itself is only a one-line
    pointer, not wired to `partner-download-url.sh`/
    `render-partner-download-block.sh`) — this is the same job as this
    design's `links`/`deliver` evidence gate, built independently, in a
    different repo, with weaker verification (a manual `curl -I`, not the
    existing scripts).
  - Its Phase 4 step 3 (`SKILL.md:51`) already states the exact rule this
    design calls "Accepted (terminal)": *"Do not close the issue. The support
    team closes it after confirming with the customer."* — strong independent
    validation of this design's `accept`-is-support-team-only rule, but it
    means the rule already lives in two places.
  - **RESOLVED 2026-10-12**: `close-support-issue`'s Phase 4 is rewritten to
    *call* `/customer-support`'s `deliver`/`links`/`accept` instead of its own
    manual steps — kills the duplication. `close-support-issue` keeps Phases
    1-3 (understand the bug, fix it, hard-gate on durable E2E regression
    coverage) and Phase 5 (close the internal task), which are about the fix
    itself, not lifecycle label/comment mechanics, and stay exactly as they
    are. **Not actioned by this task** — it touches a different repo
    (`synxdb-build-pipeline`) and its own task/PR process, and is blocked on
    `/customer-support` existing first (it has to be callable before
    `close-support-issue` can call it). Tracked as
    `synxdb-build-pipeline#T20261012-612044`, filed 2026-10-12, blocked on
    this task's implementation shipping.

## Solution

### 1. Label taxonomy (reuse-first — exactly one new label)

| Label | New? | Meaning in the lifecycle |
|---|---|---|
| `triage` | no | **Opened** — issue filed, not yet triaged. Already auto-applied by both issue templates. |
| `accepted` | no | **Triaged** — support confirmed it's real and in scope, queued, not started. Its own GitHub description is already *"Triaged and accepted"* — this design does **not** rename it or give it a second, later meaning; it stays exactly this one state. |
| `in-progress` | no | **In Progress** — an engineer has started work. |
| `delivered` | **yes — the only new label** | **Delivered** — fix/package/answer delivered to the customer and evidence-verified (never self-reported); awaiting their confirmation. |
| *(no label — issue closed, not `wontfix`/`invalid`/`duplicate`)* | no (mechanism, not a label) | **Accepted (terminal)** — support team confirmed with the customer that the delivery resolved it. Closing the issue itself *is* the signal; no second use of "accepted" is introduced. |
| `wontfix` / `invalid` / `duplicate` | no | **Rejected (terminal)** — determined not actionable, at triage or later. |
| `blocked` | no (unchanged) | Stackable modifier at any pre-close state. A required comment states *what* it's blocked on — a dependency **or** missing customer info. No separate `needs-info` label. |
| `needs-upstream` | no (unchanged) | Stackable modifier — fix depends on upstream R&D tracked in GitLab, not here. |
| `sev1`–`4`, `area:*`, `family:*`, `substrate:*`, `track:poc`, `kb-candidate`, `kb-published` | no | Orthogonal metadata, untouched by this design. |

- **Why `accepted` can just be Triaged, no rename needed**: its current
  description already says "Triaged and accepted" — reusing it for exactly
  that state is not a stretch, it's what the label already says it means.
- **Why the terminal confirmation needs no label**: "closed, and not one of
  the three rejection labels" is already a clean, queryable signal
  (`gh issue list --state closed` minus `wontfix`/`invalid`/`duplicate`) — a
  second `accepted`-shaped label would only create the exact collision this
  task exists to avoid.

### 2. Transition rules

| From | To | Label edit | Trigger | Actor / subcommand |
|---|---|---|---|---|
| *(new issue)* | `triage` | template auto-applies | issue filed | GitHub (unchanged) |
| `triage` | `accepted` | `-triage +accepted` | confirmed real, queued | support, `triage` |
| `triage` | Rejected (closed) | `+wontfix\|invalid\|duplicate`, close | not actionable | support, `reject` |
| `accepted` | `in-progress` | `-accepted +in-progress` | work starts | engineer, `start` |
| `in-progress` | `delivered` | `-in-progress +delivered` + evidence comment | delivery verified, not self-reported | engineer, `deliver` (evidence-gated) |
| `delivered` | **Accepted** (closed, completed) | `-delivered`, close (reason: completed) | customer confirms it resolved the issue | **support team only**, `accept` |
| `delivered` | `in-progress` | `-delivered +in-progress` | customer reports the delivery didn't work | support/engineer, `deliver --revert` or `start` |
| *(any pre-close state)* | Rejected (closed) | `+wontfix\|invalid\|duplicate`, close | determined not actionable | support, `reject` |
| *(any pre-close state)* | `+blocked` | add + required comment | blocked on a dependency or customer info | anyone, `block` |
| `blocked` | *(primary unchanged)* | remove | unblocked | anyone, `unblock` |
| *(any pre-close state)* | `+needs-upstream` | add + GitLab link comment | fix depends on upstream R&D | engineer, `needs-upstream` |
| Accepted (closed) | — | **none** | regression found later | support files a **brand-new issue**, optionally cross-referencing the old one in its body — no same-issue reopen, no time-window rule (Shine: "case by case, support always opens a new issue") |

### 3. `/customer-support` subcommands

Sibling skill to `/support` (which stays intake-only); argument shape
`/customer-support <subcommand> <issue-ref>`:

| Subcommand | Does |
|---|---|
| `triage` | `triage` → `accepted`, or → Rejected |
| `start` | `accepted` → `in-progress` |
| `deliver` | `in-progress` → `delivered`. **Evidence-gated**: a generic delivery needs a real reachability check on whatever was shared (not self-report — directly targets tonight's `#21` failure). For a **release-type** issue, `deliver` invokes `links` (below) and refuses to transition unless every resolved URL verifies `200`/`301`/`302` — a non-zero exit from `render-partner-download-block.sh` blocks the transition instead of letting a silent publish failure get marked delivered again. |
| `links` | Cross-repo worker: clones/uses `synxdb-build-pipeline`, bridges `SYNX_PARTNER_TOKEN="$ENTITLEMENT_TOKEN"` from its `.env`, and calls `scripts/release/render-partner-download-block.sh <released-sbom> "Hashdata.ai"` (never hand-builds a URL). Callable standalone to refresh links later. |
| `request-confirm` | Nudge comment on a stalled `delivered` issue; no label change. For release-type issues, can re-invoke `links` first if the customer reports a dead link. |
| `accept` | `delivered` → closed (completed). **Identity-gated to the support team** — never self-applied by the delivering engineer. |
| `reject` | any pre-close state → closed (`wontfix`/`invalid`/`duplicate`, picks the right one). |
| `block` / `unblock` | toggle `blocked`; `block` requires the explanatory comment. |
| `needs-upstream` | toggle `needs-upstream` + GitLab tracking link. |
| `audit` | Read-only: checks the invariant "exactly one primary-state label, consistent with open/closed state" across open issues, and reports (does not write) drift against the Project board — this is the evidence trail for the deferred board-retirement call below, and the mechanism that would have caught `#20`/`#21`/`#24`/`#25`/`#27` tonight. |

### 4. Migration plan

- Add **one** new label: `delivered` (suggested color matching the existing
  state-label family, e.g. `#5319e7`-adjacent or reuse `in-progress`'s blue
  family — final color is an implementation detail, not a design decision).
- No renames — `triage`/`accepted`/`in-progress`/`blocked`/`needs-upstream`
  keep their exact names and meanings.
- Update `scripts/setup-labels.sh` to also create the labels it's currently
  missing (`triage`, `accepted`, `in-progress`, `blocked`, `sev1`–`4`,
  `area:*`, plus the new `delivered`) so the "idempotent setup" script
  actually creates the full taxonomy it implies.
- Issue templates (`report.yml:4`, `request.yml:4`) are unchanged — they
  already correctly seed `triage`.
- No bulk backfill of `#20`/`#21`/`#23`/`#24`/`#25`/`#27` ahead of the skill —
  running `/customer-support triage`/`start`/etc. on them once the skill exists
  **is** the backfill, and doubles as its first real-world test.

### 5. `/support` → `/to-task`: rename + generalize intake

Shine: *"rename the existing skill `/support` to `/to-task`, and it will take
any URL [and] convert it into our task [tracking system]."* This is a scope
change to `/support` itself, not part of the lifecycle skill above — called
out here because `/support` is the correlation mechanism `/customer-support`
(or whatever it's named) depends on.

- **Generic correlation key**: `support-issue: <url>` is synxdb-support-
  specific by name. `/to-task` needs a source-agnostic key —
  **`source-url: <url>`** — so the same dedup/correlation mechanism works for
  a GitHub issue in any repo, a Slack thread permalink, a doc link, etc.
- **Migration — greenfield, not a data migration**: a repo-wide check
  (`grep -rl "support-issue:" dev/TODO dev/JOURNAL`) finds exactly **zero**
  task files using `support-issue:` as live frontmatter today — the only
  hits are the P1 skill-spec journal entry itself
  (`dev/JOURNAL/2026-10-12-T20261012-109735-...md`, documenting the
  convention) and this design doc's own prose. `/support` has shipped but
  never actually been run on a real issue in this repo's backlog yet. So:
  - No existing task files need editing.
  - Still **keep `support-issue:` as a recognized legacy alias** (dedup/read
    path checks both `source-url:` and `support-issue:`) rather than a hard
    break — the key is already published in four canonical docs
    (`lifecycle.md`, `_support/README.md`, `todo/SKILL.md`,
    `repo-conventions/templates/task.md`), so a consumer repo could have
    copied the convention even though this repo's own backlog has no live
    instance.
  - New tasks always write `source-url:` going forward.
  - `lint_tasks.py`'s `ALLOWED` frontmatter set (`repo-conventions/scripts/
    lint_tasks.py:19-26`) needs `source-url` added alongside the retained
    `support-issue`.
- **Keep the synxdb-support-specific smarts — as a branch, not a loss**:
  `/to-task` detects source type by URL shape and branches:
  - `github.com/Synx-Data-Labs/synxdb-support/issues/N` → today's
    `/support`-specific knowledge (due-date-from-`due:`-label convention,
    template awareness) stays exactly as-is, just as one branch among others.
  - Any other `github.com/<owner>/<repo>/issues/N` → generic GitHub-issue
    intake only (title/body/labels/state, no synxdb-support-specific due-date
    parsing).
  - Other URL shapes (Slack permalink, doc link, etc.) → new branches,
    out of scope for this task to design in full; note the hook exists.
- **Files touched by the rename** (not done in this task — implementation):
  `support/SKILL.md` → `to-task/SKILL.md` (directory rename), plus every doc
  that names `/support`: `lifecycle.md`, `_support/README.md`,
  `todo/SKILL.md`, `repo-conventions/templates/task.md`.
- **Ripple into the still-open epic children** (flagged, not fixed here):
  `T20261012-383399` (P3, live reporting) currently plans `/support report
  T<id>`, `/support status [T<id>]`, `/support stop T<id>` as **subcommands of
  `/support` itself** (`T20261012-383399-support-skill-p3-live-reporting.md:
  17-18`). Once `/support` becomes the generic `/to-task`, those
  support-specific reporting subcommands no longer belong on it — they belong
  on the new lifecycle skill (§ below) instead. `T20261012-278418` (P4) also
  references `/support`-adjacent tooling. **Whoever drives P3/P4 needs to see
  this note before building the reporter** — this task does not edit P3/P4's
  files itself (different owner, different task).

### 6. Naming the lifecycle skill — DECIDED: `/customer-support`

**Resolved 2026-10-12.** In a live follow-up, Shine referred to this task as
"the follow-up on the `/customer-support` skill (where `/support` renamed to
`/to-task`)" — naming it directly, which settles the open question in favor
of his original suggestion over the recommended alternative. The skill ships
as **`/customer-support`**. `/support-status` was only ever this design's
working name; every occurrence of `/customer-support` above is the real,
decided skill name.

For the record, the candidates considered:

| Candidate | Rationale |
|---|---|
| **`/customer-support` (DECIDED — Shine's suggestion, confirmed by him naming it this way)** | Clearest in plain English. Accepted risk: reads as a broad "help a customer" skill rather than specifically "drive this issue's lifecycle labels," and reintroduces "support" right after renaming `/support` away for being overloaded — outweighed by Shine's explicit, repeated use of the name. |
| `/support-lifecycle` (previously recommended, not chosen) | Names the mechanism precisely — the label-driven state machine this task designs. Lowest ambiguity/collision risk. Matches this repo's existing descriptive kebab-case naming (`close-support-issue`, `new-task`, `address-pr`). |
| `/support-ops` (not chosen) | Short; frames it as the action/operations skill (do the next lifecycle step) vs. `/to-task`'s passive intake. Less self-explanatory than `/support-lifecycle` without reading its description line. |

### Projects-board retirement — DEFERRED, pending leadership decision

**Not actioned by this task.** Shine: *"we are pending for tonight's
leadership meeting before we retire it."* This section is a complete,
ready-to-execute recommendation — written now so no re-research is needed
once approved — but nothing in it should be done until that decision lands.

- **Recommendation**: retire `Synx-Data-Labs/projects/3` ("SynxDB Support
  Triage") as a hand-maintained lifecycle tracker. Rationale (Problem section
  above): only one genuinely custom field, zero automation, and it is already
  independently wrong (`#20`/`#21` stuck at `Todo`, `#25`'s board `In Progress`
  with no matching label on the issue) — it is not functioning as a source of
  truth today, labels would just be a second, equally-unmaintained one.
  option after approval: a **read-only board driven from labels** (auto-synced
  `Status` reflecting the primary label, populated by `/customer-support` as a
  side effect) **or** archive it outright. Either way, labels — not the board
  — become the single source of truth; this mirrors the `scheduled:`-not-a-
  board precedent already established for the general task lifecycle
  (`lifecycle.md` § Iteration assignment: "There is no GitHub Project board
  anywhere in this suite").
- **Not blocking the rest of this task**: the label scheme and the
  `/customer-support` skill do not depend on the board's fate either way — they
  work identically whether the board is archived, synced, or left alone.

## Test plan

- [x] Label taxonomy: `delivered` label created via an updated
      `scripts/setup-labels.sh` (`synxdb-support#28`, merged), re-run
      idempotently (`--force` create, no duplicate/error on a second run —
      verified by running it live twice).
- [x] State machine: a BATS/unit suite covering every row of the Transition
      rules table — valid transitions succeed, invalid ones (e.g. `accept` from
      anything but `delivered`, `accept` attempted by a non-support identity)
      are rejected. `tests/customer_support_state_machine.bats` (16 cases),
      `tests/customer_support_accept_gate.bats` (7 cases, identity gate).
- [x] `deliver` evidence gate: mocked reachability check — a non-200/301/302
      response blocks the transition (regression case for tonight's `#21`).
      `tests/customer_support_deliver_gate.bats` (8 cases).
- [x] `links`: BATS against a fixture released-SBOM — verifies the
      `SYNX_PARTNER_TOKEN`/`ENTITLEMENT_TOKEN` bridging, token never accepted
      as a CLI arg (same rejection-test pattern as the two scripts it wraps),
      and that a non-verifying URL blocks `deliver` the same way a failed
      generic reachability check does. `tests/customer_support_links.bats`
      (10 cases).
- [x] `audit`: run against the live repo once implemented — confirm it flags
      `#20`/`#21`/`#23`/`#24`/`#25`/`#27`'s current real-world label gaps as a
      smoke test, and that its board-drift report is read-only (no writes to
      `projects/3`). **Run live** (`bash customer-support/scripts/audit.sh
      Synx-Data-Labs/synxdb-support`) — correctly flagged all six issues'
      missing primary-state label; made zero writes (board-drift reporting
      is intentionally not implemented at all, per the deferred board
      retirement — see Important Notes).
- [ ] End-to-end dry run: walk one real backlog issue through
      `triage → start → deliver → accept` and confirm the label state and
      issue-closed reason match the table above at each step. **Deliberately
      NOT done by this task** — this would relabel/close a real customer-
      facing issue, an irreversible, outward-facing action per `/drive`'s own
      escalation rules; left for a human (or an explicitly-approved follow-up)
      to run as the real backfill the design always intended ("running
      `/customer-support triage`/`start`/etc. on them once the skill exists
      **is** the backfill").

## Done criteria

- [x] `delivered` is the only new label in `Synx-Data-Labs/synxdb-support`
      (verify via `gh label list` diff against this doc's taxonomy table) —
      confirmed via `gh label list --limit 100` after `synxdb-support#28`.
- [x] `/customer-support` skill exists in `ccxp-skills` with all 11 subcommands
      above; `/support` itself is renamed+generalized to `/to-task` (intake
      only, `source-url:` key, `support-issue:` kept as a recognized legacy
      alias — see § 5).
- [x] `scripts/setup-labels.sh` creates the full taxonomy (no more missing
      `triage`/`accepted`/`in-progress`/`blocked`/`sev*`/`area:*`) —
      `synxdb-support#28`.
- [x] `links`/`deliver` correctly bridge `.env`'s `ENTITLEMENT_TOKEN` to
      `SYNX_PARTNER_TOKEN` and never hand-construct a Cloudsmith URL.
- [ ] Projects-board section stays a pure recommendation — **not executed**
      until Shine confirms the leadership-meeting decision; that confirmation
      is a separate follow-up (new task or a comment here), not implied by
      this task closing. **Still open, deliberately** — left unchecked
      because the decision itself hasn't landed, not because of any gap in
      this task's own work.

## Open questions

- ~~Q1: final `delivered` label color~~ — RESOLVED (decided now, applied
  when the label is created at implementation time): `#0052cc` — checked
  against the live label set (`gh label list`) to avoid a collision;
  `#5319e7` (one of the two colors this doc's Migration plan originally
  suggested) turned out to already be `family:synxdb`/`family:cloud`'s
  color, which would read as "another family label," not a state label.
- ~~Q2: `links`/cross-repo invocation shape~~ — RESOLVED: ephemeral ad-hoc
  clone of `synxdb-build-pipeline` per `/drive` Phase 1.5's pattern (never
  reuse an existing local clone — same reasoning as Phase 1.5 itself: a local
  clone may be another live session's working tree mid-operation).
- ~~Naming (was its own section 6 open item)~~ — RESOLVED: `/customer-support`
  (see § 6).
- ~~close-support-issue reconciliation~~ — RESOLVED: see Context §
  "Cross-repo overlap found", tracked as `synxdb-build-pipeline#T20261012-612044`.
- Q3 (blocked on Shine, not on design): whether the Projects-board
  recommendation above is approved, archived-as-is, or rejected — pending
  tonight's leadership meeting. Nothing in this task's Done criteria depends
  on the answer landing first. **Still open** — not actioned by this task.

## Next steps

- Label-scheme + `/customer-support` skill: all design-time open questions
  resolved 2026-10-12 — proceeding to `/drive` implementation.
- `synxdb-build-pipeline#T20261012-612044` (close-support-issue reconciliation):
  filed, blocked on this task's implementation shipping first.
- `T20261012-383399`/`T20261012-278418` (epic children rippled by the
  `/to-task` generalization): updated 2026-10-12 to move their planned
  `report`/`status`/`stop` subcommands from `/support` to `/customer-support`.
- Projects-board retirement: **blocked on the pending leadership decision**
  (Q3) — do not action until Shine confirms the outcome of tonight's meeting.

## Closed (2026-10-12)

Shipped across four PRs, three repos:

- **`ccxp-skills#345`** (merged) — design resolution: naming decided
  (`/customer-support`), close-support-issue reconciliation decided, Q1/Q2
  resolved, epic children (`T20261012-383399`/`T20261012-278418`) updated.
- **`ccxp-skills#346`** (merged) — implementation: `/customer-support` skill
  (11 subcommands, 7 scripts, 69 BATS cases across 7 test files), `/support`
  renamed+generalized to `/to-task`, `lint_tasks.py` allowlist update, doc
  updates (`lifecycle.md`, `_support/README.md`, `todo/SKILL.md`,
  `new-task/SKILL.md`, `repo-conventions/templates/task.md`). Two rounds of
  independent review found and fixed real issues (see below).
- **`synxdb-support#28`** (merged) — `scripts/setup-labels.sh` now creates
  the full lifecycle taxonomy; `delivered` label applied live and verified.
- **`synxdb-build-pipeline#3741`** (merged) — filed `T20261012-612044`
  tracking the `close-support-issue` reconciliation, blocked on this task's
  `/customer-support` shipping (now unblocked — see Next steps there).

**What's met**: every Done criterion above is checked except the
Projects-board recommendation, which is deliberately still open pending
Shine's confirmation of tonight's leadership-meeting outcome — not a gap in
this task's work.

**What's external/unverified**: the live end-to-end backfill walk
(`triage -> start -> deliver -> accept`) on a real `synxdb-support` issue
was deliberately not run by this task (irreversible, outward-facing action
on a real customer issue) — `audit` was run live instead (read-only) and
correctly flagged `#20`/`#21`/`#23`/`#24`/`#25`/`#27`. Running the real
subcommands on those six issues is the backfill the design always intended;
left for a human or an explicitly-approved follow-up to confirm and run.

**Independent review found real issues, both fixed before merge**:

- PR #345: a stale TLDR bullet and a stale Evals-section skill reference
  left behind by the first design-resolve edit; a `status: Open` that
  contradicted its own "blocked" body text (caught on the cross-repo
  `T20261012-612044` task, fixed to a free-text blocked status since the
  blocker lives in a different repo's `dev/` tree).
- PR #346: a real functional bug in `links.sh` (the `.env` token fallback
  was unreachable from the default ephemeral-clone path, since
  `synxdb-build-pipeline`'s `.env` is gitignored — fixed to fail fast with a
  clear message instead); a dangling reference to a `reject.sh` that never
  existed and an unenforced rejection-label rule; gates
  (`deliver_gate`/`accept_gate`) not structurally composed with
  `labels.sh`, meaning a direct call could skip them; a stale `/support`
  reference in `new-task/SKILL.md`. Fixed by adding `customer-support/
  scripts/transition.sh` (the single enforced entrypoint SKILL.md now
  documents) plus 13 new BATS cases; a follow-up focused review confirmed
  the fix is structurally correct (gate failures abort via `set -euo
  pipefail` before any label write; `reject`'s label-then-close ordering is
  guaranteed by control flow, not convention).

**Follow-up tasks filed**: `synxdb-build-pipeline#T20261012-612044`
(close-support-issue reconciliation — now unblocked, ready to pick up).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — the bulk of this task
  is bash-script-backed (state machine, gates, I/O wrappers); tests were
  written alongside each script and run before every commit, but not
  strictly red-green-refactor per function.
- Verification (`superpowers:verification-before-completion`): yes — full
  BATS suite + `lint_tasks.py` + `skill_score.py` + `design-score` run
  before each PR, plus a live (read-only) `audit` run against the real
  `synxdb-support` repo as a smoke test.
- Systematic debugging (`superpowers:systematic-debugging`): no — no stuck
  failing test required it; the one real bug found (links.sh's `.env`
  fallback) was caught by independent review, not by a failing test loop.
- Receiving code review (`superpowers:receiving-code-review`): yes —
  `ccxp-skills#346`'s review found 5 real issues (1 high, 2 medium, 2 low);
  all fixed rather than argued with, since each was independently
  verifiable (confirmed `.gitignore`, confirmed the missing `reject.sh`,
  confirmed the gate-bypass path) — one minor pushback made on
  `synxdb-support#28` (a reviewer note that `delivered` "already existed
  live" was correct but not a defect, since this task's own earlier step
  had just created it).
