---
status: Open
scheduled: 2026-10-12
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: Cloudflare family - router description, 'not for' lines, drop duplicated references
---

# T20261010-762961: Cloudflare family: router description, 'not for' lines, drop duplicated references

## Problem

- **Type**: chore
- `cloudflare`'s trigger competes with its 10 siblings and ships duplicate `references/*` (~6k lines); `sandbox-sdk` never says Cloudflare; `turnstile-spin` fires on any CAPTCHA (README §2).
- Done looks like: `cloudflare` is a fallback router, each sibling has a "not for X -> use Y" line, duplicates removed, vendored skills normalized or marked `upstream:` with a scorer exemption.

## Solution

- Router + "not for" lines first; dedupe references second; vendored-skill decision last.

## Test plan

- [ ] `skill_score.py --check` passes; no dangling reference links.

## Done criteria

- [ ] Router in place, duplicates gone, vendored-skill policy recorded.
