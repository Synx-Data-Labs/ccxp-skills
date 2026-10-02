---
name: _test-nested-invoker
description: Throwaway regression harness for T20260922-409644 — never invoke directly; invoke only when a dispatched test agent is explicitly told to run this skill to probe nested-invocation of a disable-model-invocation:true target
disable-model-invocation: false
argument-hint: (none)
---

Regression coverage for T20260922-409644's empirical question (see
`_test-nested-target/SKILL.md` for the full rationale). This skill's only
job is to invoke `_test-nested-target` right now, as the next step in this
workflow — exactly the pattern `/todo sweep` uses to invoke `/top`, or
`/spinup` uses to invoke `/1password-env-setup`.

## Workflow

1. Invoke the `_test-nested-target` skill now, with no arguments.
2. Report back verbatim whatever that invocation produced — including if
   it failed, was unavailable, or silently did nothing. The exact outcome
   (fired vs. blocked) is the test result; do not interpret or soften it.
