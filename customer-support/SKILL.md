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
bash <skills-root>/customer-support/scripts/transition.sh reject <owner>/<repo> <number> --reason <wontfix|invalid|duplicate>
bash <skills-root>/customer-support/scripts/transition.sh block <owner>/<repo> <number>      # post the explanatory comment yourself, via gh issue comment — never skip it
bash <skills-root>/customer-support/scripts/transition.sh unblock <owner>/<repo> <number>
bash <skills-root>/customer-support/scripts/transition.sh needs-upstream <owner>/<repo> <number> <on|off>
```

- `reject` applies the specific `wontfix`/`invalid`/`duplicate` label itself
  (before closing) — never left to the caller to remember separately.
- `accept`/`reject` also clear any stale `blocked`/`needs-upstream` modifier
  on close.
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

**Token source, exactly**: `synxdb-build-pipeline`'s `.env` is gitignored,
so the *default* ephemeral clone never has one populated. Without
`--clone-dir`, **the caller must already have `ENTITLEMENT_TOKEN`
exported** before calling `links.sh` (the normal case for a session already
working in this suite) — `links.sh` fails fast, before cloning, if it
isn't. The `.env`-file fallback only applies when `--clone-dir` points at
an existing, already-populated checkout.

### 5. `accept` — support-team-only (identity gate)

`transition.sh accept` runs `accept_gate.sh` against `SUPPORT_TEAM_LOGINS`
(a comma-separated allowlist, env var, never hardcoded) before writing any
label. **Fails closed**: an unconfigured allowlist refuses `accept` entirely
rather than defaulting to "anyone may accept."

### 6. `audit`

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
