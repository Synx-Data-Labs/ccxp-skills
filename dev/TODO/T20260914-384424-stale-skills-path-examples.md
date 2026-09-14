---
status: Open
estimation: 2h
source: this conversation, 2026-09-14
related: T20260914-871616
---

# T20260914-384424: Update stale `~/.claude/skills/...` example paths across skill docs

## Problem

- **Type**: chore
- Spotted while closing [[T20260914-871616]] (fixing the two *functionally*
  broken `~/.claude/skills/...` paths — the `_gh/auto-switch.sh` hook and
  `statusLine.command`): 44 other files still show example invocations
  like `bash ~/.claude/skills/_taskid/new.sh --check ./dev`, assuming the
  old symlink-install layout that T20260914-871616 retired.

  ```
  address-pr/scripts/pre-merge-check.sh   claim/SKILL.md
  address-pr/SKILL.md                     cleanup-branch/SKILL.md
  bottom/SKILL.md                         design-score/SKILL.md
  ccxp/scripts/reclaim-sweep-pr.sh        dev/guidelines.md
  ccxp/scripts/update-roadmap.sh          _docs/lint-docs.sh
  ccxp/SKILL.md                           drive/SKILL.md
  gcpr/SKILL.md                           repo-conventions/SKILL.md
  _gh/ci-triage.sh                        repo-conventions/templates/guidelines.md
  _gh/gh.sh                               repo-conventions/templates/task.md
  grill-me/SKILL.md                       retro/SKILL.md
  help-net/SKILL.md                       _session/task-state.sh
  _ipm/current.sh                         slack/scripts/slack-notify.sh
  _ipm/ipm-iteration-drain-check.sh       slack/scripts/slack-send.sh
  journal-compact/SKILL.md                slack/SKILL.md
  lifecycle.md                            stage/SKILL.md
  new-task/SKILL.md                       _taskid/check-orphaned-refs.sh
  proof-read/SKILL.md                     _taskid/in-this-repo.sh
  quality-probe/SKILL.md                  _taskid/new.sh
  rca/SKILL.md                            _taskid/README.md
  README.md                               _taskid/url.sh
  repo-conventions/scripts/lint.sh        todo/SKILL.md
                                           top/SKILL.md
                                           turnstile-spin/README.md
                                           verify-site/scripts/verify.sh
                                           verify-site/SKILL.md
  ```

  (full, current list: `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`)
- **Cosmetic only, not a functional bug**: confirmed by inspecting
  `_gh/gh.sh`, `_taskid/new.sh`, `_taskid/in-this-repo.sh`,
  `_session/task-state.sh` — the actual sibling-script resolution inside
  these scripts already uses `../_gh/foo.sh`-style relative references
  (per README's "keeps each skill a sibling of the shared libs" design),
  so nothing here breaks execution. It's the human/Claude-facing example
  commands in doc prose and script header comments that are stale — wrong
  to copy-paste verbatim under a plugin install.
- Done = every hit above shows a path (or invocation form) that resolves
  correctly for a plugin-only install, and a re-run of the grep above
  turns up nothing left to fix (or only intentional exceptions, noted
  inline).

## Done criteria

- [ ] Decide the replacement convention (see Notes) and apply it
      consistently across all 44 files.
- [ ] `grep -rl '~/.claude/skills/' --include="*.md" --include="*.sh" .`
      returns nothing unexpected.
- [ ] `bash _docs/lint-docs.sh --fix` and the `repo-conventions` doc lints
      stay clean on every touched file.

## Notes

- Two candidate replacement conventions, pick one (or mix per context):
  - For a doc example meant to be read by **Claude while the skill is
    loaded**: use a path relative to "Base directory for this skill"
    (the harness prints this on skill load) — e.g.
    `bash ../_taskid/new.sh --check ./dev` instead of
    `bash ~/.claude/skills/_taskid/new.sh --check ./dev` — matching how
    the actual code already resolves siblings.
  - For a comment/example meant for a **human typing at a shell prompt**
    outside a Claude Code session (e.g. some `_taskid/*.sh` header
    comments): there's no single correct path under a plugin install —
    it's version-pinned cache path or a dev checkout path depending on
    how that human installed it. May be better rewritten to say "run
    from this script's own directory" or similar, rather than a copyable
    absolute example.
- Don't touch `dev/TODO/T20260914-871616-*.md` or
  `dev/JOURNAL/*` — those are historical/closed-task records, not living
  docs.
