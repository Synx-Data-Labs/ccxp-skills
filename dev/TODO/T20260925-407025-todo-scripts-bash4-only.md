---
status: Open
estimation: 1h
source: /ccxp interactive run, 2026-09-25 — Phase 1.2b top-5 computation on synxdb-build-pipeline
related: T20260914-359646 (introduced todo-list.sh/todo-next.sh as local scripts)
---

# T20260925-407025: `todo/scripts/todo-list.sh` (and friends) require bash 4+, but macOS's default `/bin/bash` is 3.2

## Problem

- Running `bash todo/scripts/todo-list.sh` under macOS's stock `/bin/bash` (3.2.57, the last GPLv2 release Apple ships) fails immediately:

  ```
  todo/scripts/todo-list.sh: line 27: local: -A: invalid option
  local: usage: local name[=value] ...
  ```

  `local -A` (associative arrays) is a bash-4+ feature. The script has no shebang-driven interpreter pin and no version guard, so on any macOS box where `bash` resolves to the system binary (the common case — Homebrew's newer bash at `/opt/homebrew/bin/bash` is opt-in, not default on `$PATH` ahead of `/bin/bash` unless a user has configured it), the script silently fails with a bash-internals error rather than a clear "needs bash 4+" message.
- Same issue reproduced in `_session/task_claim.sh` (e.g. `pr-owner` subcommand) — `set -u` combined with a `while read` inside command substitution throws `unbound variable` under bash 3.2 where it wouldn't under 4+. Likely affects other scripts in `_session/` and `todo/scripts/` that use bash-4+ constructs (`local -A`, `mapfile`, `${var,,}`, etc.) — not yet fully inventoried.
- Workaround used this session: explicitly invoke `/opt/homebrew/bin/bash <script>` instead of the shebang'd/plain `bash <script>`. Works, but every consumer (this skill's own docs, `/ccxp`, `/todo`, `/drive`) invokes these as `bash <skills-root>/todo/scripts/todo-list.sh` — i.e. via whatever `bash` resolves to on `$PATH`, not a pinned interpreter — so the failure recurs on every fresh macOS interactive clone until this is fixed at the source.

## Done when

- Either: add a version guard at the top of each affected script (`if ((BASH_VERSINFO[0] < 4)); then echo "needs bash 4+" >&2; exit 1; fi`) so the failure is legible instead of a raw bash-internals error, AND document the `/opt/homebrew/bin/bash` (or equivalent) workaround in the relevant SKILL.md Prerequisites section — OR (preferred, more portable): rewrite the bash-4+-only constructs (`local -A`, the `task_claim.sh` `set -u`-under-command-substitution pattern) to be bash-3.2-compatible, since these are meant to be zero-dependency "just bash" scripts per T20260914-359646's own design goal.
- Full inventory: grep `todo/scripts/*.sh` and `_session/*.sh` for `local -A`, `mapfile`, `readarray`, and other bash-4+-only syntax; fix or guard each.
