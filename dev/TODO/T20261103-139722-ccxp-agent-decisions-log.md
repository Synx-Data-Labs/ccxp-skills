---
estimation: 3
status: Open
source: Owner chat 2026-11-03
description: ccxp-agent decisions log (ledger.sh decision ...) - keep the owner's standing decisions next to the ledger, in ccxp-decisions.json and ccxp-decisions.md
---

# T20261103-139722: ccxp-agent decisions log (`ledger.sh decision ...`)

## Problem

- **Type**: feature
- Owner request, verbatim: "as part the ccxp-agent description, can we have instruction to also keep user decisions as part of the context somewhere? for example, enrich the ccxp-ledger.md with another file of dev decisions?" then "yes, file the task and implement it".
- The ledger holds jobs, Next items and parked items, but not the owner's standing rules, constraints and choices; they live only in the conversation and are lost on compaction or restart.

## Design (owner-approved)

- Files next to the ledger, same path rules (`CCXP_DECISIONS_FILE`, else the ledger's directory): `ccxp-decisions.json` (source of truth, mode 600, atomic writes) and `ccxp-decisions.md` (rendered).
- `ledger.sh decision add "<text>" [--quote "<owner words>"] [--scope global|repo:<name>] [--context <abs path>] [--source <job/ref>]` prints a stable `d<n>` ref (own counter, never reused).
- `decision supersede <ref> "<new text>" [opts]`, `decision retire <ref> ["<reason>"]`, `decision list [--all] [--scope S] [--json]`, `decision show <ref>`.
- `reply`/`render` print a `Decisions: N active (latest: ...)` line plus the `.md` path before the final `Ledger:` line (only when there are active decisions; `reply --no-decisions` opts out); `show` includes a summary; `check` flags malformed entries only.
- Archive rule: above 200 entries, retired/superseded entries older than 90 days move to `ccxp-decisions-archive.json`.
- Persona (`agent-pairing/assets/ccxp-agent.md`) gets a terse "Decisions log" section and `decision` joins the Bash carve-out.
- Docs: `agent-pairing/decisions.md`, `hud/scripts/ledger.md`, `hud/README.md`. Tests: `tests/ledger.bats`, `tests/agent_pairing.bats`.

## Done when

- [ ] `ledger.sh decision add|supersede|retire|list|show` implemented with secret rejection, length caps, mode 600, atomic writes, never-reused counter, archive rule.
- [ ] `reply`/`render`/`show`/`check` integration without breaking existing output consumers.
- [ ] Persona section, carve-out lists, docs written; the persona asset comparison tests pass.
- [ ] bats tests for every new subcommand; full relevant suites, lint and skill score checks pass.
- [ ] Maintainer step (separate PR, not part of this task's code change): bump the plugin version (MINOR: new subcommand), `claude plugin validate .` with zero warnings, tag, then `/plugin update` (the persona refreshes automatically) so installed sessions get the persona section.
