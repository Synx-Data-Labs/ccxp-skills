---
status: Open
scheduled: 2026-11-02
estimation: 2
source: follow-up of T20261021-266225 (design decision: no cron in the skill PR)
related: T20261021-266225
---

# T20261021-291375: Schedule the customer-support delivered-autoclose sweep (cron) for synxdb-support

## Problem

- **Type**: feature
- `customer-support/scripts/sweep.sh` (T20261021-266225) closes `delivered` issues idle for 14 days, but nothing runs it; it is dry-run by default.
- Decide and implement scheduling: a daily workflow `delivered-autoclose.yml` in `Synx-Data-Labs/synxdb-support` that checks out ccxp-skills and runs `sweep.sh Synx-Data-Labs/synxdb-support`.
- First eligible issues (all delivered 2026-10-21): #30, #31, #32 become closable on 2026-11-04.

## Design: credential is an org-owned GitHub App (decided)

- Decision: the workflow authenticates as a GitHub App owned by `Synx-Data-Labs`.
- App: permission `Issues: read & write` only (no other repository or org permissions), installed on **only** `Synx-Data-Labs/synxdb-support`.
- Workflow mints a short-lived installation token each run with `actions/create-github-app-token`:
  - pinned by SHA: `64ab729a6294000f5aa4a4bc0b73d1f32bc45510` (v3.3.0)
  - inputs: `app-id: ${{ vars.SUPPORT_SWEEP_APP_ID }}`, `private-key: ${{ secrets.SUPPORT_SWEEP_APP_PRIVATE_KEY }}`, `repositories: synxdb-support`, `permission-issues: write`
  - the step output token is passed to `sweep.sh` as `GH_TOKEN`; never echoed or stored
- Names in `synxdb-support` (Actions settings):
  - `SUPPORT_SWEEP_APP_ID` - repository variable (not sensitive)
  - `SUPPORT_SWEEP_APP_PRIVATE_KEY` - repository secret
- Dry-run by default: the scheduled run omits `--apply`; the apply mode is enabled only by a maintainer edit after the dry-run review (see acceptance).

## One-time human setup (maintainer)

- [ ] Create the App in org settings (Settings > Developer settings > GitHub Apps > New): name e.g. `synx-support-sweep`, no webhook, repository permission `Issues: Read and write`, "Only on this account".
- [ ] Generate a private key (downloads a `.pem`) and note the App ID.
- [ ] Install the App on `Synx-Data-Labs`, selecting **Only select repositories** and choosing `synxdb-support` only.
- [ ] Store the ID: `gh variable set SUPPORT_SWEEP_APP_ID --repo Synx-Data-Labs/synxdb-support` (type the value at the prompt or use the UI).
- [ ] Store the key from the file via stdin, never pasted in chat or logs: `gh secret set SUPPORT_SWEEP_APP_PRIVATE_KEY --repo Synx-Data-Labs/synxdb-support < path/to/key.pem`
- [ ] Delete the local `.pem` afterwards (or move it into the team password manager).

## Acceptance

- [ ] `delivered-autoclose.yml` merged in `synxdb-support`: daily cron, mints the App token as above, runs `sweep.sh Synx-Data-Labs/synxdb-support` in dry-run mode.
- [ ] The only credential is the App (ID variable + private key secret); the old `SUPPORT_SWEEP_TOKEN` name is gone from workflow, docs, and this task.
- [ ] One observed scheduled dry-run; its candidate list reviewed with the support team.
- [ ] After the support team's go-ahead, the maintainer enables `--apply`.
