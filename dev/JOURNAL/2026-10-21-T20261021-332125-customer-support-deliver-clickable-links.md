---
status: Done
estimation: 1
source: this conversation, 2026-10-21
related: T20261012-373882, T20261012-333879, T20261020-131330
claimed_by:
claimed_role:
scheduled: 2026-10-19
---

# T20261021-332125: customer-support deliver: post clickable download links, not a fenced code block

## TLDR

- **Type**: bug
- **Problem**: `deliver --release` posts the render script's fenced block verbatim, so GitHub does not linkify the 14 download URLs (synxdb-support#32).
- **Solution**: a skill-side formatter `customer-support/scripts/format_links.sh` rewrites the render output to Markdown headings + bullets, asserts URL multiset equality and no fence, and `links.sh` emits that by default (`--raw` keeps the original).

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

## Context

- Render output shape (verified, `render-partner-download-block.sh` lines 78-140 in synxdb-build-pipeline):
  - intro line(s), then a fence, title, `====` rule, per type a `TYPE` + `----` line, then `component (artifact):` followed by an indented URL line, then closing fence.
  - Failure lines look like a warning line (warning sign, component, artifact, HTTP code); the script's exit code is the verification gate.
- `links.sh` stdout is what gets posted (`customer-support/scripts/links.sh:cs-links-render`); `transition.sh deliver --release` only gates, it posts nothing itself.

## Solution

- New `customer-support/scripts/format_links.sh` (sourceable, functions): `cs-fmt-urls`, `cs-fmt-markdown`, `cs-fmt-assert-no-fence`, `cs-fmt-main` (stdin to stdout).
  - Drops fence lines, the in-fence title, `====` and `----` rules; `TYPE` becomes `### TYPE`; each item becomes `- **component** (`artifact`): <bare URL>`; warning lines become `- ⚠ ...`.
  - Refuses (non-zero, stdout empty) when raw and formatted URL multisets differ, when a fence survives, or when input has no URL; error text prints counts only, never URLs.
- `links.sh` pipes the render output through the formatter, preserving the render exit code; `--raw` opt-out for logs.
- Alternatives rejected:
  - Edit the build-pipeline render script: its output is also used for logs, and is cross-repo.
  - Markdown table like #30: long URLs make wide tables; bullets match the hand-fixed #32 comment.

## Test plan

- [x] `tests/customer_support_format_links.bats` with FAKE tokens/URLs: fence removed, headings, URLs identical incl. `+`, no trailing punctuation, empty/partial input, warning lines, token not in test output, mismatch refusal.
- [x] `tests/customer_support_links.bats`: links.sh main emits Markdown by default, `--raw` unchanged, render failure rc propagated.

## Done criteria

- [x] Fence and rule lines removed: `tests/customer_support_format_links.bats` "fence removed".
- [x] Headings + one bullet per package: same file "headings and bullets".
- [x] URLs byte-identical, incl. `+`: same file "URL multiset identical".
- [x] Refuse to post on mismatch/empty: same file "refuses ...".
- [x] No fence in posted body: `cs-fmt-assert-no-fence` in `customer-support/scripts/format_links.sh`, tested in same file.
- [x] Token never in args/stdout/logs: formatter takes stdin only; same file "no token in output".
- [x] SKILL.md describes the comment format: `customer-support/SKILL.md` section 4.
- [x] Build-pipeline render script untouched (no PR to that repo).

## Root cause

- `links.sh` passes `render-partner-download-block.sh` stdout through unchanged (`customer-support/scripts/links.sh`, `cs-links-render`), and that script wraps the list in a fence (introduced by its author for log readability; deliberate for logs, oversight for GitHub comments).

## Closed (2026-10-21)

- Shipped in the T20261021-332125 implementation PR (design PR #392, claim PR #391); the PR number is on the merge commit.
- Met: all Done criteria above via `tests/customer_support_format_links.bats` (13 tests) and `tests/customer_support_links.bats`; SKILL.md section 4 documents the format.
- External, unverified: a real `deliver --release` run against a live release (no real token or issue touched here); the build-pipeline render script is unchanged.
- Quality probe: shellcheck clean; max_fn_lines +20 (`cs-fmt-markdown`), design score 75, warned only.
- Follow-ups filed: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes in practice - tests written first, then the formatter; skill not formally loaded
- Verification (`superpowers:verification-before-completion`): partial - bats runs and pre-merge-check.sh per PR; skill not formally loaded
- Systematic debugging (`superpowers:systematic-debugging`): no - did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): see PR comments
