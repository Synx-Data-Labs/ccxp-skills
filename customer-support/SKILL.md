---
name: customer-support
description: Use when the user explicitly asks to move a synxdb-support GitHub issue through its lifecycle — triage, start work, mark delivered with evidence, request confirmation, accept/reject/close, block/unblock, flag needs-upstream, or audit the label invariant across open issues
disable-model-invocation: false
argument-hint: "<triage|start|deliver|request-confirm|accept|reject|block|unblock|needs-upstream|audit|links> <issue-ref>"
---

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Drive a `Synx-Data-Labs/synxdb-support` issue through its label-driven
lifecycle: `triage -> accepted -> in-progress -> delivered -> (closed)`, plus
the `blocked`/`needs-upstream` stackable modifiers. Reuses the existing
label set (`triage`, `accepted`, `in-progress`, `blocked`, `needs-upstream`)
plus exactly one new label, `delivered`. Sibling skill to `/to-task` (which
stays intake-only); design: `T20261012-373882`.

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
| `triage` | `triage` -> `accepted` | Confirmed real, in scope, queued. To reject at triage time, use `reject` instead. |
| `start` | `accepted` -> `in-progress`, or `delivered` -> `in-progress` | The second form is the revert path (customer reports the delivery didn't work); `deliver --revert` is an alias for this. |
| `deliver` | `in-progress` -> `delivered` | **Evidence-gated** — see below. |
| `links` | (no transition) | Standalone cross-repo worker: resolves + HTTP-verifies every partner download link for a released SBOM. Callable any time to refresh links, not just from `deliver`. |
| `request-confirm` | `delivered` -> `delivered` | Nudge comment only, no label change. Re-invokes `links` first for a release-type issue if the customer reports a dead link. |
| `accept` | `delivered` -> closed (`completed`) | **Support-team-only** (identity-gated — see below). |
| `reject` | any pre-close state -> closed (`wontfix`/`invalid`/`duplicate`) | Picks the label that matches why. |
| `block` / `unblock` | toggle `blocked` | `block` requires an explanatory comment (what it's blocked on). |
| `needs-upstream` | toggle `needs-upstream` | Requires a GitLab tracking-link comment when turning it on. |
| `audit` | read-only | Checks "exactly one primary label, consistent with open/closed state" across open issues. Never writes. Project-board drift reporting is **not implemented** — board retirement is deferred pending a separate leadership decision (`T20261012-373882`). |

## Workflow

### 1. Resolve the issue and current state

```bash
bash <skills-root>/_support/parse-issue-url.sh <issue-ref>        # -> owner repo number
bash <skills-root>/customer-support/scripts/labels.sh primary <owner>/<repo> <number>
```

`labels.sh primary` fails loudly if more than one primary label is present
(an invariant violation `audit` exists to catch) — do not proceed past that
error by guessing which one is "real."

### 2. Decide the transition (pure, no I/O)

```bash
bash <skills-root>/customer-support/scripts/state_machine.sh <current-state> <subcommand>
```

Prints the next state (or `CLOSED:<reason>`), or a clear error if the
subcommand isn't valid from the current state. **Never skip this** — it is
what stops e.g. `accept` from firing on an issue that isn't `delivered`.

### 3. `deliver`'s evidence gate (hard gate — never self-report)

- **Generic delivery**: `bash <skills-root>/customer-support/scripts/deliver_gate.sh check-urls <url>...` — every shared URL must verify `200`/`301`/`302`. Any non-verifying URL blocks the transition.
- **Release-type issue** (a package/download delivery): invoke `links` first:

  ```bash
  bash <skills-root>/customer-support/scripts/links.sh <released-sbom-path> "Hashdata.ai"
  ```

  A non-zero exit (any resolved artifact failed to verify) blocks the
  `in-progress -> delivered` transition — this is the direct regression
  test for `synxdb-support#21` (a package self-reported delivered when the
  publish step had actually failed silently).

### 4. `links` — cross-repo worker (token bridging)

`links.sh` clones `synxdb-build-pipeline` (ephemeral, same pattern as
`/drive` Phase 1.5 — never reuses an existing local clone) and calls its
`scripts/release/render-partner-download-block.sh <sbom> <entitlement-label>`.
It bridges the token itself: `synxdb-build-pipeline`'s `.env` key is
`ENTITLEMENT_TOKEN`, but the script it wraps reads `SYNX_PARTNER_TOKEN` —
**never** pass the token as a CLI argument (both the wrapped scripts and
this one reject any `--token*` flag). Entitlement identity for SynxDB/
SynxDB4 releases: Cloudsmith repo `synx/synxdb`, entitlement id
`3PNyRETaE96a`, display label `"Hashdata.ai"` (the label is a free-text
argument, not the id).

### 5. `accept` — support-team-only (identity gate)

```bash
bash <skills-root>/customer-support/scripts/accept_gate.sh "$(gh api user --jq .login)" "$SUPPORT_TEAM_LOGINS"
```

`SUPPORT_TEAM_LOGINS` is a comma-separated allowlist (env var, never
hardcoded). **Fails closed**: an unconfigured allowlist refuses `accept`
entirely rather than defaulting to "anyone may accept."

### 6. Apply the transition

```bash
bash <skills-root>/customer-support/scripts/labels.sh apply <owner>/<repo> <number> <old-state> <new-state-or-CLOSED:reason>
```

For `block`/`unblock`/`needs-upstream` (modifiers, not primary-state
transitions): `bash <skills-root>/customer-support/scripts/labels.sh toggle <owner>/<repo> <number> <blocked|needs-upstream> <on|off>`, then post the required explanatory comment via `gh issue comment` — never toggle `block` on without one.

### 7. `audit`

```bash
bash <skills-root>/customer-support/scripts/audit.sh <owner>/<repo>
```

Prints one line per invariant violation (missing or duplicate primary
label) across open issues; exit 0 if clean. Read-only — never call
`labels.sh apply`/`toggle` from here.

## Important Notes

- **Reuse-first labels.** Only `delivered` is new; everything else
  (`triage`/`accepted`/`in-progress`/`blocked`/`needs-upstream`) already
  exists in `Synx-Data-Labs/synxdb-support` and keeps its exact current
  meaning — see `T20261012-373882`'s label taxonomy table.
- **Terminal confirmation needs no label.** "Closed, and not one of
  `wontfix`/`invalid`/`duplicate`" already means accepted-and-resolved; a
  second `accepted`-shaped label would recreate the exact ambiguity this
  design exists to remove.
- **Regression found after accept**: support files a brand-new issue — no
  same-issue reopen, no time-window rule (case-by-case, maintainer call).
- **Overlap with `synxdb-build-pipeline`'s `close-support-issue`**: that
  skill's Phase 4 (link-verified delivery, support-team-only close) is
  being reconciled to call this skill's `deliver`/`links`/`accept` instead
  of duplicating them — tracked as `synxdb-build-pipeline#T20261012-612044`,
  blocked on this skill shipping. `close-support-issue` keeps its Phases
  1-3/5 (the bug fix itself).
