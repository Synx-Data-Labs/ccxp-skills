## Epics

Regression fixture for the `printf '%b'` truncation bug (T20260911-347027
PR #24 review): a title containing a literal `\c` — printf's `%b`
conversion treats `\c` as "stop producing output here", so feeding this
title through `%b` instead of `%s` would silently truncate the rendered
line right after the title.

### E1 — Ship \cool feature

Goal: exercise a title with a printf-%b-special backslash sequence
Done when: epic_render --slack does not truncate at the backslash

- T20260101-000001
