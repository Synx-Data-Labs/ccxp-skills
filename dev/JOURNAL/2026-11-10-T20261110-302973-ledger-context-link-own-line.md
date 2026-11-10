---
status: Done
estimation: 1
source: owner report, job r1135, 2026-11-10
description: ledger.sh renders per-item context as "context: file://..."; render it as a bare file:// URL on its own line
claimed_by:
claimed_role:
scheduled: 2026-11-09
---

# T20261110-302973: Ledger context link: bare file:// URL on its own line

## Problem

- **Type**: bug
- Owner: the top `Ledger: file://...` line of `ccxp-ledger.md` is cmd-clickable in a VS Code SSH terminal, the per-item context links are not.
- `hud/scripts/ledger.sh` render emits `"- head\n  context: file://..."` (item helper, and the decisions render); `reply` emits a bare `\n  file://...` line.
- The label-glued form differs from the one that works (`reply`); render, reply and check should share one format: a bare `file://` URL on its own line.
- Prior decision T20261106-384684: ONE plain file:// URL per item; the `context:` prefix crept back in later.

## Closed (2026-11-10)

- Shipped in PR #652. `ccxp-ledger.md` and `ccxp-decisions.md` now put a bare `file://` URL on the indented line under each row, like `reply` and the top `Ledger:` line; the `context:` label is gone (`(none)` when empty).
- Root cause (inferred): the `context:` label glued before the URL was added to the rendered files after T20261106-384684 had made the URL plain; the label is the only difference from the form that works. Not verified against VS Code's link detector source.
- Verification: `bats tests/ledger.bats` (regression assertion forbids `context:` in the rendered file); CI green.
- Reaches the installed ledger.sh only with the next plugin release (none cut here).
- Quality regression: none (docs and shell change, probe not run).

## Skills invoked

- TDD: no (small fix, tests updated alongside)
- Verification (`superpowers:verification-before-completion`): yes, local bats and /address-pr checks
- Systematic debugging: no
- Receiving code review: yes, one minor note answered in the PR
