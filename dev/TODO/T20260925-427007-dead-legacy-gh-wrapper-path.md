---
status: Open
scheduled: 2026-10-05
estimation: 2h
source: lsc-pa PR #159 follow-up, 2026-09-25
related: T20260925-219021
---

# T20260925-427007: Four scripts look for `gh.sh` at the dead `~/.claude/skills/_gh/` path

## Problem

- **Type**: bug
- Under a plugin install, `_gh/gh.sh` lives at
  `$CLAUDE_CONFIG_DIR/plugins/cache/ccxp-skills/ccxp-skills/<version>/_gh/gh.sh`.
  The legacy symlink path `~/.claude/skills/_gh/gh.sh` doesn't exist, so
  these callers silently fall back to bare `gh`. That can authenticate as
  the wrong account on multi-account machines, or skip work outright:

  | Call site | Effect |
  |---|---|
  | `repo-conventions/scripts/lint_refs.py:290` (`gh_argv()`) | `PR #N`/`issue #N` linking runs as the wrong account; vendored copies inherit this |
  | `_taskid/url.sh:43` (`taskid-gh`) | T-id issue links resolve under the wrong account |
  | `_gh/ci-triage.sh:35` (`ci_triage_gh`) | CI triage `gh` calls run as the wrong account |
  | `quality-probe/scripts/probe.sh:45` (`QP_GH`) | code-scanning probe always skipped |

- Evidence:
  - lsc-pa's quality-probe run on 2026-09-25 printed
    `skip: code-scanning unavailable`.
  - lsc-pa fixed its vendored `lint_refs.py` in 75033us/lsc-pa#159
    (`find_gh_wrapper()`: newest plugin-cache version, then the legacy
    path).
- T20260925-219021 lists `_taskid/url.sh` as one caller in its much larger
  "retire `auto-switch.sh`" scope. This task is just the dead-path lookup at
  all four sites, so it can ship on its own. Tick that bullet there when
  this one lands.

## Done when

- The three plugin-internal scripts resolve their sibling wrapper relative
  to themselves (`$(dirname "${BASH_SOURCE[0]}")/../_gh/gh.sh`, or
  `$CLAUDE_PLUGIN_ROOT/_gh/gh.sh`), falling back to bare `gh` only when
  that's missing. The existing DI seams (`TASKID_GH`, `CI_TRIAGE_GH`,
  `QP_GH`) still win.
- `lint_refs.py` tries its own plugin location first. For vendored copies
  run outside the plugin, it then searches the plugin cache (port lsc-pa
  #159's `find_gh_wrapper()`).
- bats/pytest cases cover wrapper resolution with a fake plugin layout and
  with no wrapper at all.
- None of the four call sites above references the legacy path any more,
  in either spelling: the literal `~/.claude/skills/_gh` (shell) or the
  `".claude" / "skills" / "_gh"` pieces (`lint_refs.py`). Check with
  `git grep -nE '\.claude/skills/_gh|"skills" / "_gh"' -- '*.sh' '*.py' ':!tests/'`,
  which should come back empty (task/journal prose and test comments that
  describe the old path are expected hits outside that scope).
