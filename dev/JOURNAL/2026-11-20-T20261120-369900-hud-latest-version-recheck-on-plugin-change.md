---
status: Done
estimation: 1
source: Job 1340 finding (HUD latest-version cache), owner 2026-11-20
description: Re-check the HUD latest-version cache once when plugin.json mtime changes
type: bug
related: T20261120-230152
claimed_by:
claimed_role:
scheduled: 2026-11-16
---

# T20261120-369900: HUD latest-version cache re-check on plugin change (n362 step 3)

## TLDR

- **Type**: bug
- **Problem**: after a plugin update or reinstall the HUD kept the old "latest" release for up to 6 hours (the cache TTL), so a new release looked missing.
- **Solution**: the cache records the running `plugin.json` mtime (`pm`); a different mtime (or an old cache without `pm`) triggers ONE early re-check through the existing detached, locked refresh.

## Problem

- Evidence: job 1340: `~/.claude-work/state/hud-version/latest.json` was `{"latest":"6.3.2","fetched":...}` written 10 minutes before the owner's check; the tag check runs only when `now - fetched >= HVR_TTL` (`hud/scripts/hud-version.sh`, `hud-version-json`), and `/reload-plugins` does not clear it.
- Impact: a release looked absent for up to 6 h.

## Context

- Root cause: the TTL is the only invalidation; nothing ties the cache to the plugin that is running.
- Fix lives in the existing refresh path (cache file, lock dir, 8 s timeout, detached) so cost is unchanged; a changed plugin.json is the signal because every plugin update writes a new cache directory or file.

## Solution

- `hvr-plugin-mtime` reads the mtime (BSD `stat -f`, then GNU `stat -c`); `hud-version-json` treats the cache as due when the TTL expired OR `pm` differs from the current mtime; `hvr-refresh` writes `pm` on success and on failure (a failed re-check keeps the old answer and waits the usual ~15 minutes, no retry storm).
- Review fix: two live plugin roots (an old and a new session during an update) share one cache, so a plain mismatch test would re-check on every render; a change now re-checks at most once a minute (`HVR_MIN_RECHECK`).
- Alternatives rejected:
  - shorter TTL: more `git ls-remote` calls for everyone to fix a once-per-update event;
  - hooking `/reload-plugins`: no such hook, and a plain update in a new session would still miss it.

## Test plan

- [x] `bats tests/hud_version.bats`: changed mtime re-checks once inside the TTL; unchanged does not; old cache without `pm` re-checks once; failed re-check records the mtime; garbage `pm` counts as changed.
- [ ] CI: bats suite green on the PR.

## Done criteria

- [x] Changed plugin.json re-checks once, inside the TTL: `tests/hud_version.bats` "a changed plugin.json re-checks once".
- [x] Unchanged plugin.json and fresh cache make no lookup: "a fresh cache is used without any lookup".
- [x] No retry storm after a failed re-check and old caches handled: "a cache written before the mtime was recorded (no pm) re-checks once".
- [x] Untrusted cache content never reaches the output: "a garbage pm in the cache counts as changed".

## Closed (2026-11-20)

- Shipped in the PR that moves this file to `dev/JOURNAL/` (job 1342).
- Quality regression (max_fn_lines): the refresh condition grew by a helper and a few lines inside the existing function; the new behaviour is the task.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written with the change in one pass
- Verification (`superpowers:verification-before-completion`): yes, local bats runs plus /address-pr gate
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr review
