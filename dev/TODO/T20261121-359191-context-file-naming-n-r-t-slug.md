---
status: In Progress
scheduled: 2026-11-23
estimation: 2
source: owner request 2026-11-21 (decision d142), job 1353
description: Context files are named n<k>-r<job>-t<taskid>-<slug>.md; update every place the format is captured
---

# T20261121-359191: Context file naming convention n<k>-r<job>-t<taskid>-slug

## Problem

- Owner (2026-11-21): "again, my naming convension would be n###-r###-t###-slug. where do we capture the context file name format today? we need to update that location."
- Earlier: "why the context file named with the 'r#' or 'j#', not with the 'n#'? I am totally confused on what's our current naming convensions?"
- Today's docs say `n<k>-j<job>-<slug>[-t<taskid>].md` (T20261109-107704, superseded by this task); the job part uses `j`, the task part trails, and `r<n>` is the ledger's running-job ref.
- Done when: every place that states the format (persona, `hud/scripts/ledger.md`, `hud/README.md`, `ledger.sh` header and warning, `tests/ledger.bats`) states the new grammar and no stale form remains.
- Out of scope: renaming existing files, version bumps, tags, releases.

## Design / Decisions

- **d142** (owner, 2026-11-21, consolidates and replaces d106, d120 and the earlier d141 wording; "my naming convension would be n###-r###-t###-slug"): context files are `n<k>-r<job>-t<taskid>-<slug>.md`, in fixed order n, r, t, slug.
- Grammar: `name := [n<k>-][r<job>-][t<yyyymmdd>-<nnnnnn>-]<slug>.md`, or `k<n>-<slug>.md` for a parked item. Tokens are read left to right, each at most once and only in that order; the first thing that is not a token starts the slug. A token is `n|r|k` plus digits plus `-`, or `t` plus 8 digits, `-`, 6 digits, `-`. The slug must not start with a word that is one letter of `n r t k j` followed only by digits (write `r2-d2` as `robot-r2-d2`).
- Absent parts: job-only `r<job>-[t<taskid>-]<slug>.md`; Next item without a job `n<k>-[t<taskid>-]<slug>.md`.
- Legacy accepted silently, never renamed: `n<k>-j<job>-<slug>[-t<taskid>].md`, `n<k>-<slug>[-T<taskid>].md`, `j<n>-...`, `r<n>-...`, `k<n>-...`.
- `ledger.sh ctxname <file>` parses a name into its parts (tested); the `next add` warning stays a prefix test on `<ref>-`.
- A Next item's context file starts with cmd-clickable pointers (`file://` URL lines) to its source task file.
