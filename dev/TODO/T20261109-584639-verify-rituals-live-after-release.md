---
status: Open
scheduled: 2026-11-23
estimation: 1
source: T20261107-228304 close (external verification)
related: T20261107-228304, T20261107-406028
description: Verify the persona-driven rituals live once per ritual after the plugin release
---

# T20261109-584639: Verify the persona-driven daily rituals live after the release

## Problem

- T20261107-228304 shipped `agent-pairing/scripts/ritual-due.sh` and the persona section "Rituals due", but the persona change only reaches installs with a plugin release (no bump was made in that task; the owner decides).
- The hub deprecation task T20261107-406028 must stay blocked until a live persona session has run each ritual once and a repeat check did nothing.
- Done looks like: after the release, one live ccxp-agent session dispatches one standup, one Monday IPM and one Friday retro (or a faked clock on a spare profile), a repeat check dispatches nothing, and the result is recorded in this task's close. Limits to keep in mind: only while a session is open and awake; worst-case lag about 1 hour under autopilot.

## Done criteria

- [ ] Standup, IPM and retro each dispatched once by the persona; repeat check empty.
- [ ] Result recorded; T20261107-406028 told it may proceed.
