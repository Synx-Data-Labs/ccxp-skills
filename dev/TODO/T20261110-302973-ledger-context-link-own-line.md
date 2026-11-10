---
status: Open
estimation: 1
source: owner report, job r1135, 2026-11-10
description: ledger.sh renders per-item context as "context: file://..."; render it as a bare file:// URL on its own line
---

# T20261110-302973: Ledger context link: bare file:// URL on its own line

## Problem

- **Type**: bug
- Owner: the top `Ledger: file://...` line of `ccxp-ledger.md` is cmd-clickable in a VS Code SSH terminal, the per-item context links are not.
- `hud/scripts/ledger.sh` render emits `"- head\n  context: file://..."` (item helper, and the decisions render); `reply` emits a bare `\n  file://...` line.
- The label-glued form differs from the one that works (`reply`); render, reply and check should share one format: a bare `file://` URL on its own line.
- Prior decision T20261106-384684: ONE plain file:// URL per item; the `context:` prefix crept back in later.
