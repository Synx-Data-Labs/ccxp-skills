---
name: customer-support
description: Use when the user explicitly asks to move a synxdb-support GitHub issue through its lifecycle — triage, start work, mark delivered with evidence, request confirmation, accept/reject/close, auto-close timed-out deliveries (sweep), block/unblock, flag needs-upstream, or audit the label invariant across open issues
argument-hint: "<triage|start|deliver|request-confirm|accept|reject|block|unblock|needs-upstream|audit|links|sweep|autoclose> <issue-ref>"
---

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Drive a `Synx-Data-Labs/synxdb-support` issue through its label-driven
lifecycle: `status:new -> triaged -> in-progress -> delivered -> (closed)`.

- Every state is a `status:*` label; an issue carries **exactly one**, open or
  closed: `new`, `triaged`, `in-progress`, `blocked`, `needs-upstream`,
  `delivered`, `wontfix`, `duplicate`.
- Other families: `type:bug|enhancement|question`, `severity:1..4`,
  `kb:candidate|published` (`area:*`, `family:*`, `substrate:*`, `track:poc` unchanged).
- Scheme v2 (2026-10-21) renamed the bare names and dropped `invalid`; old
  names stay read-side aliases, so the skill works before and after the GitHub rename.
- **All label names live in `scripts/label_names.sh`**; never write a literal
  elsewhere. Sibling of `/to-task` (intake only); design: `T20261012-373882`.

**Never self-reported.** `deliver` is evidence-gated (a real reachability
check, never "I sent it so it must be fine" — the regression case this
exists for is `synxdb-support#21`), and `accept` is identity-gated to the
support team — the delivering engineer can never close their own delivery.

## Argument

`<subcommand> <issue-ref>` — `issue-ref` is an issue URL or `owner/repo#N`
(default repo: `Synx-Data-Labs/synxdb-support`), parsed the same way as
`/to-task` (`bash <skills-root>/_support/parse-issue-url.sh`).

| Subcommand | Transition | Notes |
|---|---|---|
| `triage` | `status:new` -> `status:triaged` | The verb keeps its name. An issue with **no status label** (legacy #20, #21, #23, #24, #25, #27) is treated as `new` (state `none`). To reject at triage time, use `reject` instead. If tracked, `--task <repo>#T<id>` (or `<owner>/<repo>#T<id>`) posts `Tracked internally as [<ref>](<url>) — <title>` plus the bare URL. |
| `start` | `triaged` -> `in-progress`, or `delivered` -> `in-progress` | The second form is the revert path (customer reports the delivery didn't work); `deliver --revert` is an alias for this. |
| `deliver` | `in-progress` -> `delivered` | **Evidence-gated** — see below. |
| `links` | (no transition) | Standalone cross-repo worker: resolves + HTTP-verifies every partner download link for a released SBOM. Callable any time. |
| `request-confirm` | `delivered` -> `delivered` | Nudge comment only, no label change. Re-runs `links` first for a release issue with a dead link. |
| `accept` | `status:delivered` -> closed (`completed`), label kept | **Support-team-only** (identity-gated — see below). |
| `sweep` / `autoclose` | `status:delivered` -> closed (`completed`, timeout), label kept | **Not an acceptance.** `sweep <repo> [--days 14] [--apply]` is dry-run by default; see § 7. `autoclose` is the per-issue `transition.sh` step it calls. |
| `reject` | any working state -> closed (`status:wontfix` / `status:duplicate`) | `--reason wontfix\|duplicate` only (`invalid` dropped; not-a-bug = `wontfix`). Closes "not planned" / "duplicate". |
| `block` / `unblock` | status -> `status:blocked`; unblock restores the previous status | `block` requires an explanatory comment (what it's blocked on). Previous status comes from the label timeline (fallback `status:triaged`). |
| `needs-upstream` | `on`: status -> `status:needs-upstream`; `off`: restores the previous status | Requires a GitLab tracking-link comment when turning it on. |
| `audit` | read-only | Checks "exactly one `status:*` label per issue, open or closed" (`--state all`). Never writes. Project-board drift reporting is not implemented (board retirement is deferred). |

### Tracking comment (`triage --task`)

- `scripts/task_url.sh` resolves the task file via the GitHub API and the comment carries a full https permalink pinned to a commit SHA (survives the TODO -> JOURNAL move); a task only on an open filing PR links the PR and says so.
- Missing task, malformed ref or unreadable repo: fails loudly, posts nothing, moves no label.

## Workflow

### 1. Resolve the issue

```bash
bash <skills-root>/_support/parse-issue-url.sh <issue-ref>        # -> owner repo number
```

### 2. Run the subcommand through `transition.sh` — the single enforced entrypoint

**Always go through `transition.sh`, never call `labels.sh apply`/`toggle`
directly for a state-changing subcommand.** `transition.sh` is what makes
the evidence gate and identity gate structurally unbypassable: it resolves
the current primary label, asks `state_machine.sh` for the next one, runs
the relevant gate, and ONLY THEN writes the label — a direct `labels.sh`
call skips every gate.

```bash
bash <skills-root>/customer-support/scripts/transition.sh triage <owner>/<repo> <number>
bash <skills-root>/customer-support/scripts/transition.sh start <owner>/<repo> <number>
bash <skills-root>/customer-support/scripts/transition.sh deliver <owner>/<repo> <number> --urls <url>...
bash <skills-root>/customer-support/scripts/transition.sh deliver <owner>/<repo> <number> --release <sbom> "Hashdata.ai"
bash <skills-root>/customer-support/scripts/transition.sh request-confirm <owner>/<repo> <number>
bash <skills-root>/customer-support/scripts/transition.sh accept <owner>/<repo> <number> --actor "$(gh api user --jq .login)" --allowed "$SUPPORT_TEAM_LOGINS"
bash <skills-root>/customer-support/scripts/transition.sh reject <owner>/<repo> <number> --reason <wontfix|duplicate>
bash <skills-root>/customer-support/scripts/transition.sh autoclose <owner>/<repo> <number> [--days N]   # normally via sweep.sh --apply; re-verifies eligibility itself
bash <skills-root>/customer-support/scripts/transition.sh block <owner>/<repo> <number>      # post the explanatory comment yourself, via gh issue comment — never skip it
bash <skills-root>/customer-support/scripts/transition.sh unblock <owner>/<repo> <number>
bash <skills-root>/customer-support/scripts/transition.sh needs-upstream <owner>/<repo> <number> <on|off>
```

- `reject` swaps the current status for `status:wontfix`/`status:duplicate`
  itself (before closing) — never left to the caller to remember separately.
- `accept` and the timeout close keep `status:delivered`.
- Restoring `delivered` (unblock) re-labels it, restarting the 14-day sweep clock.
- `deliver --urls`/`--release` run the evidence gate (§ 3 below) BEFORE any
  label write; a failed gate means `labels.sh` is never even called.
- `accept` runs the identity gate (§ 5 below) BEFORE any label write.

The building blocks below (`state_machine.sh`, `labels.sh`, `deliver_gate.sh`,
`accept_gate.sh`) are what `transition.sh` composes — read them to
understand the mechanics, but drive the skill through `transition.sh`.

### 3. `deliver`'s evidence gate (hard gate — never self-report)

- **Generic delivery** (`transition.sh deliver ... --urls <url>...`): every shared URL must verify `200`/`301`/`302`. Any non-verifying URL blocks the transition.
- **Release-type issue** (`transition.sh deliver ... --release <sbom> <entitlement-label>`, a package/download delivery): delegates to `links` (§ 4) — a non-zero exit (any resolved artifact failed to verify) blocks the `in-progress -> delivered` transition. This is the direct regression test for `synxdb-support#21` (a package self-reported delivered when the publish step had actually failed silently).

### 4. `links` — cross-repo worker (token bridging)

`links.sh` clones `synxdb-build-pipeline` (ephemeral, as in `/drive` Phase 1.5; never reuses a local clone) and calls its `scripts/release/render-partner-download-block.sh <sbom> <entitlement-label>`.

- The wrapped script reads `SYNX_PARTNER_TOKEN`, while the `.env` key is `ENTITLEMENT_TOKEN`; `links.sh` bridges them.
- **Never** pass the token as a CLI argument (any `--token*` flag is rejected).
- SynxDB/SynxDB4 entitlement: Cloudsmith repo `synx/synxdb`, id `3PNyRETaE96a`, free-text display label `"Hashdata.ai"`.

**Token source**: an ephemeral clone has no `.env` (gitignored), so without `--clone-dir` export `ENTITLEMENT_TOKEN` first (`links.sh` fails fast otherwise); the `.env` fallback applies only to a populated `--clone-dir`.

**Comment format**: `links.sh` prints Markdown (GitHub does not linkify URLs in a fence).

- `format_links.sh` (stdin to stdout) emits `### RPM`/`DEB`/`RAW` headings and `- **name** (`file`): <bare URL>` bullets.
- It refuses unless the URLs are unchanged, present, and fence-free; `--raw` gives unmodified output (logs only).

### 5. `accept` — support-team-only (identity gate)

`transition.sh accept` runs `accept_gate.sh` against `SUPPORT_TEAM_LOGINS`
(a comma-separated allowlist, env var, never hardcoded) before writing any
label. **Fails closed**: an unconfigured allowlist refuses `accept` entirely
rather than defaulting to "anyone may accept."

### 6. `audit`

```bash
bash <skills-root>/customer-support/scripts/audit.sh <owner>/<repo>
```

Prints one line per invariant violation (missing or duplicate `status:*`
label) across open and closed issues; exit 0 if clean. Read-only.

### 7. `sweep` — delivered timeout (auto-close after 14 days)

```bash
bash <skills-root>/customer-support/scripts/sweep.sh <owner>/<repo>                 # dry-run: lists WOULD CLOSE / SKIP / FLAG
bash <skills-root>/customer-support/scripts/sweep.sh <owner>/<repo> --days 14 --apply
```

- Clock: the **last** `delivered` label event (timeline API). `--days` default 14, minimum 1.
- Eligible: open, `status:delivered`, not reopened since, no comment after delivery from anyone but the label's actor (else `FLAG needs human`, never closed).
- `--apply` closes via `transition.sh autoclose`, which re-runs the gate, comments `**Auto-closed (not accepted):**` plus marker `<!-- cs-autoclose -->`, then closes as `completed`, keeping the label.
- **Not an `accept`**: no identity gate; the marker distinguishes it. Reopen then `start` (`delivered -> in-progress`); a reopened issue is flagged, not re-closed.

## Important Notes

- **Terminal confirmation needs no label.** "Closed, and carrying
  `status:delivered`" already means accepted-and-resolved (except
  a timeout close, recognisable by its `cs-autoclose` marker comment); a
  second acceptance-shaped label would recreate the exact ambiguity this
  design exists to remove.
- **Regression found after accept**: file a brand-new issue (no same-issue reopen).
- **Overlap with `close-support-issue`** (synxdb-build-pipeline): its Phase 4
  is being reconciled to call this skill's `deliver`/`links`/`accept`
  (`synxdb-build-pipeline#T20261012-612044`); it keeps Phases 1-3/5.
