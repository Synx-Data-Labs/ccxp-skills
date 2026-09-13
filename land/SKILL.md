---
name: land
description: Use when the user explicitly asks to land, commit and push, or open a PR for the current uncommitted changes — alias for /gcpr
disable-model-invocation: false
argument-hint: [commit-message-or-description]
---

`/land` is an alias for [`/gcpr`](../gcpr/SKILL.md) — same workflow (group commits, branch, push, open PR, hand off to `/address-pr`), just a more natural name (`gcpr` is an abbreviation `skill-conventions` §2 would otherwise steer away from).

## Argument

Same as `/gcpr`'s — forward `$ARGUMENTS` unchanged.

## Workflow

Invoke the `gcpr` skill directly and follow it exactly. Do not duplicate its steps here — this file exists only so `/land` resolves to something; `gcpr/SKILL.md` is the single source of truth.
