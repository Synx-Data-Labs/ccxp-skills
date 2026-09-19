---
status: Open
estimation: 2h
source: session 2026-09-19 — internal names reappeared on the now-public repo within 2 days of the visibility flip
related: T20260914-234656
description: Add a pre-merge check for company-internal identifiers so genericization stops being a recurring manual scrub
---

# T20260919-231319: Catch internal identifiers before they reach the public repo

## Problem

- The repo went public 2026-09-14 after a full PII scrub. **Within two days
  it was leaking again**: 9 files carried hub/build-pipeline repo names, a
  private skills repo, a company domain, two account handles, a private
  consumer repo slug, and a cron box's OS username — plus 11 links to private
  GitHub issues that 404 publicly while confirming those repos exist.
- Three of the four introducing commits landed **after** the flip
  (`6ef5731` 09-15, `5a1e443` and `64d693e` 09-16), so the content was
  publicly visible until `3d2518b`.
- This is not carelessness — it is the normal task flow working as designed:
  - `dd991b5` migrated three task files in wholesale from the hub repo
  - new task/journal entries cite real repos and PRs as **evidence**, which
    is exactly what a good bug report does
  - `/migrate-task` was added to make cross-repo migration routine, which
    increases the rate
- A one-off scrub therefore cannot hold. The scrub has now happened twice
  (2026-09-14, 2026-09-19) and will happen again.

## Done criteria

- [ ] A check fails CI when a configurable set of internal identifiers
      appears in tracked files
- [ ] The identifier list lives in config, not hardcoded, so it can grow
      without a code change
- [ ] `Synx-Data-Labs/ccxp-skills` (this repo's own public slug) and the
      established placeholders never trip it
- [ ] `/migrate-task` genericizes on the way in, or refuses and points at
      the check
- [ ] Runs in the same workflow as the existing doc/task lints

## Notes

- The placeholder vocabulary already exists and is used 200+ times:
  `your-org/hub-repo`, `build-pipeline-repo`, `private-skills-repo`,
  `example-website.com`, `/home/ci`, `<owner-account>`. The check should
  suggest the mapping, not just reject.
- Prefer failing on the **link** form too
  (`github.com/<org>/<private-repo>`) — that is the highest-signal leak
  and the easiest to grep.
- `repo-conventions/scripts/lint_refs.py` is the closest existing model: a
  link-aware markdown linter with a `--fix`, already wired into CI.
- Open question for design: whether the list ships in this repo (visible to
  everyone, which itself names the private repos) or is injected via CI
  config/secret. Naming the private repos inside a public lint list would
  defeat part of the purpose.

## Test plan

- [ ] A file containing a known internal identifier fails the check
- [ ] The repo's own slug and every established placeholder pass
- [ ] A private-repo link form is caught even when the bare name is not
