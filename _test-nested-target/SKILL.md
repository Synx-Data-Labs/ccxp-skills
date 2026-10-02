---
name: _test-nested-target
description: Throwaway regression harness for T20260922-409644 — never invoke directly; exists only so _test-nested-invoker's nested-call test has a disable-model-invocation:true target to probe
disable-model-invocation: true
argument-hint: (none)
---

Regression coverage for one narrow empirical question: does
`disable-model-invocation: true` on a skill's own frontmatter block a
**same-session, prose-instructed nested invocation** from another skill
(as opposed to the model's own autonomous discovery, which is the
documented, uncontested case)? T20260922-409644 needed this answered
before flipping Bucket B skills that are invoked exactly that way (e.g.
`/todo sweep` invoking `/top`).

If you have reached this skill via a direct, unprompted invocation (no
other skill's prose told you to), something is wrong — this skill is not
meant to be useful on its own. Do nothing except print:

```
_test-nested-target: reached directly (no nested-invoker prose) — this is not the expected test path
```

If another skill's workflow (specifically `_test-nested-invoker`)
instructed you to invoke this skill as a step in its own prose, print
exactly this marker (this is the expected, successful test path):

```
_TEST_NESTED_TARGET_FIRED
```

Do not take any other action — no file edits, no commits, no further
tool calls beyond printing the marker.
