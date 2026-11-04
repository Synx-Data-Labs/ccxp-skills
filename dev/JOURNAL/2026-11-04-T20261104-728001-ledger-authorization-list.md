---
status: Done
source: Owner chat 2026-11-04 (job 728)
description: Authorization list in the ccxp ledger (ledger.sh authz), consulted by the ccxp-agent before dispatch
---

# T20261104-728001: Authorization list in ccxp-ledger

- **Owner request**: "for ccxp-ledger.md, let's record a permission/authorization list there, with explicit yes/no, and you follow that authorization setting."
- **Built**: `ledger.sh authz list|show|set` over `ccxp-authz.json` (mode 600, atomic, locked); default is no for every key; `reply`/`render`/`ccxp-ledger.md` show an Authorization section after Parked once the file exists.
- **Persona**: "Consent comes before dispatch" consults `authz list`; yes needs no extra consent but is quoted into the job prompt; no or unlisted means ask; only the owner's typed words change it.
- **Tests**: `tests/ledger.bats`, `tests/agent_pairing.bats`. Docs: `hud/README.md`, `hud/scripts/ledger.md`.
- **Not shipped as default**: no key is seeded; each owner runs `authz set` with their own words.
