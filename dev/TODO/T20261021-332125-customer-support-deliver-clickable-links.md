---
status: Open
estimation: 1
source: this conversation, 2026-10-21
related: T20261012-373882, T20261012-333879, T20261020-131330
---

# T20261021-332125: customer-support deliver: post clickable download links, not a fenced code block

## Problem

- **Type**: bug
- `/customer-support deliver --release <sbom> "Hashdata.ai"` posted the delivery comment on Synx-Data-Labs/synxdb-support#32 (comment 6309829335) with all 14 partner download URLs inside ONE fenced code block, so GitHub did not linkify them.
- The fence comes from `scripts/release/render-partner-download-block.sh` in Synx-Data-Labs/synxdb-build-pipeline (`echo '```'` at lines 99 and 140, plus decorative `====` / `----` rules); `customer-support/scripts/links.sh` passes that output through as-is into the comment.
- The #32 comment was hand-edited afterwards (job #60): fence removed, `### RPM`/`### DEB`/`### RAW` headings, one bullet per package `- **name** (`file`): <bare URL>`, 14 URLs byte-identical.
- Counter-example: the delivery comment on synxdb-support#30 (comment 6304792303) used a Markdown table with 14 URLs and no fences, so its links render.
- Fix (skill-side only; the render script's output is also used for logs, do NOT change it): in `customer-support/` strip the fence and `====`/`----` rule lines and reformat into Markdown headings + one bullet per package (or a table like #30).
  - Preserve every URL byte-for-byte; assert URL multiset equality before posting and refuse to post if it differs.
  - Keep the entitlement token out of logs/stdout/argv; it appears only inside the posted comment.
  - BATS tests with FAKE tokens/URLs (`https://dl.cloudsmith.io/FAKETOKEN/synx/synxdb/rpm/...`): fence removed, headings present, URLs identical incl. `+`, no trailing punctuation glued to URLs, empty/partial render output handled, test output never prints a real token.
  - Guard/test that the posted body has no ``` fence around URLs.
  - Update SKILL.md/docs that describe the comment format.
- Do not touch synxdb-support#32 or #30 (read-only mentions only).
