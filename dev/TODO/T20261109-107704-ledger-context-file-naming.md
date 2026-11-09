---
status: Open
estimation: 1
source: owner request 2026-11-09 (decision d12)
description: Next-item context files are named n<k>-<slug>-T<taskid>.md; ledger.sh warns softly, persona states the rule
---

# T20261109-107704: Ledger context file naming for Next items

## Problem

- Owner (2026-11-09): "the context file name should be n###-slug-T########-######.md ... the n### in the context file name will help us reference to the next item easily."
- Rule: a Next item's context file is `n<k>-<slug>-T<taskid>.md` (T part omitted without a task); reserve the ref with `ledger.sh ref next n`, write the file, then `next add --ref n<k> --context <file>`.
- Done when: `ledger.sh next add` warns (stderr, exit unchanged) on a non-matching name with BATS coverage, `hud/scripts/ledger.md` and `hud/README.md` document it, and the ccxp-agent persona states it (second PR, under ~600 bytes).
- Out of scope: renaming existing context files (owner's local state), a version bump or release.
