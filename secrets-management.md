# Secrets Management — general policy

This is the generic half of a canonical secrets-management policy, split
out of a private company repo. It intentionally omits the org-specific
half (1Password account structure, the actual vault map, and repo-specific
inventories) — that content mixed real internal products, account
domains, and personal data with genuinely reusable policy, and hasn't been
divided out cleanly yet. What's here is the part that generalizes as-is:
the rotation-automation taxonomy and the "how to add a new secret"
checklist. Adopt these, then author your own account-structure and
vault-map sections to match your own org.

## Automation tiers

Every secret falls into exactly one tier. Use these definitions to decide how a *new*
secret's rotation should work, not only to describe existing ones.

| Tier          | Definition                                                                                                                                                                                                                                                    | Human involvement |
|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------|
| **Auto**      | A workflow/script rotates end-to-end: calls the issuer's API to mint a new value, writes it to the runtime secret store, verifies, and notifies. Writing the value back to your secrets vault too is the target, but a live Auto-tier implementation may still write only to the runtime store (e.g. a GitHub Actions secret) until that gap is closed. | None in the happy path — a human only reacts if the automation alerts on failure. |
| **Semi-auto** | A health check probes on a schedule and alerts on failure or approaching expiry. A human mints the new value in the issuer's UI (no programmatic mint path, or it's deliberately gated). Tooling can prep and verify but not generate.                      | Human mints the value; automation does the rest (detect, prep, verify, notify). |
| **Manual**    | Outside our control, or no programmatic rotate path exists at all (e.g. IT-managed VPN, on-compromise-only webhooks).                                                                                                                                        | Fully manual end-to-end; automation covers existence/health monitoring only, not rotation. |

### General cadence guidance

A starting point, not a hard rule — a repo's own inventory doc can be more specific per
secret:

| Secret type                                                    | Typical cadence |
|-------------------------------------------------------------------|------------------|
| PATs / fine-grained tokens                                        | ~90 days (match issuer default expiry where possible); reminder ahead of expiry |
| API keys / service tokens                                          | Annually, or immediately on suspected exposure |
| Webhooks (e.g. Slack)                                              | On suspected compromise only — no scheduled rotation |
| SSH keys                                                           | On suspected machine compromise, or annually as hygiene |
| Long-lived app/signing keys (e.g. a GitHub App private key)        | Multi-year hygiene rotation, not tied to any expiry |
| VPN / IT-managed credentials                                       | Per IT/company policy |
| Auto-tier secrets                                                  | Whatever the automation's own schedule is — the point of Auto tier is not having to think about cadence |

## Adding a new secret

1. **Decide where it lives** — pick the vault/scope by product or team ownership if it's
   product/repo-scoped, a shared/org-wide vault if it's cross-product, a personal vault
   if it's an individual's own login. (Author your own vault-map section describing your
   org's actual structure — this doc deliberately doesn't prescribe one.)
2. **Mint at the issuer** — create the credential in the issuer's UI/API.
3. **Mirror to your secrets vault first** — 1Password (or whatever you use) as source of
   truth, written *before* anything else.
4. **Propagate to the runtime store** — GitHub Actions secret, Cloudflare Pages secret,
   local `.env` via `op inject` or equivalent, etc.
5. **Document locally, if the repo has its own inventory doc** — add a row: tier, purpose,
   rotation procedure. This canonical doc is not the place for that row.
6. **Wire monitoring** — if the repo has a health-check workflow, add a probe; if the
   secret is Auto-tier, extend the rotation workflow's matrix.
