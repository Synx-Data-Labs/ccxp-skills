---
status: Design
estimation: 2h
source: session 2026-09-19 — internal names reappeared on the now-public repo within 2 days of the visibility flip
related: T20260914-234656
description: Add a pre-merge check for company-internal identifiers so genericization stops being a recurring manual scrub
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260919-231319: Catch internal identifiers before they reach the public repo

## TLDR

- **Type**: chore (prevents recurrence of a real, twice-happened incident)
- **Problem**: internal identifiers keep leaking into this now-public repo —
  normal task/journal authoring and `/migrate-task` both cite real
  repos/PRs/paths as evidence by design, and nothing gates that pre-merge.
- **Solution**: a new generic, config-driven CI lint
  (`repo-conventions/scripts/lint_identifiers.py`, same shape as the
  existing `lint_refs.py`/`lint_tasks.py`) with two signal classes —
  structural checks that need zero config (private IPv4s, credential
  tokens, personal home paths) and an optional denylist supplied only via
  env var/file, never committed — wired into `lint.sh` + `tests.yml`, plus
  a `/migrate-task` step that auto-genericizes or refuses.
- **Key design call**: the identifier list itself is **never** committed to
  any repo's git history (env-var/file config only) — this is what keeps
  the check itself company-agnostic, matching this repo's own
  "no company-specific dependency" charter.

## Problem

- The repo went public 2026-09-14 after a full PII scrub. **Within two days
  it was leaking again**: 9 files carried hub/build-pipeline repo names, a
  private skills repo, a company domain, two account handles, a private
  consumer repo slug, and a cron box's OS username — plus 11 links to private
  GitHub issues that 404 publicly while confirming those repos exist.
- Three of the four introducing commits landed **after** the flip
  (`6ef5731` 09-15, `5a1e443` and `64d693e` 09-16), so the content was
  publicly visible until `3d2518b`.
- This is not carelessness — it is the normal task flow working as designed:
  - `dd991b5` migrated three task files in wholesale from the hub repo
  - new task/journal entries cite real repos and PRs as **evidence**, which
    is exactly what a good bug report does
  - `/migrate-task` was added to make cross-repo migration routine, which
    increases the rate
- A one-off scrub therefore cannot hold. The scrub has now happened twice
  (2026-09-14, 2026-09-19) and will happen again.

## Context

- Friction point: task/journal authoring and `/migrate-task` cross-repo
  moves are the two channels that reintroduced leaks (see Problem above) —
  both cite real repos/PRs as evidence *by design* (a good bug report names
  what it's about), so a one-off scrub can never hold against normal usage.
- Existing generic building blocks to reuse rather than reinvent:
  - `repo-conventions/scripts/lint_refs.py`'s `KNOWN_SIBLING_REPOS`/
    `LINT_REFS_GH` — config supplied only via env var, never committed data
    (`repo-conventions/scripts/lint_refs.py:95-100`) — the exact pattern
    this task needs for its own denylist.
  - `lint_refs.py`/`lint_tasks.py`'s `--all` (repo-wide, wired into
    `lint.sh`) / `--changed <files>` (wired into CI + `/gcpr`'s doc-lint
    guard) dual-mode convention.
  - The placeholder vocabulary already used 200+ times: `your-org/hub-repo`,
    `build-pipeline-repo`, `private-skills-repo`, `example-website.com`,
    `/home/ci`, `<owner-account>` — generic wording, safe to commit, usable
    as the check's suggested-replacement table.
- Prior art in a **sibling but different** repo, NOT this one:
  `synx-skills/sensitivity-audit`'s `audit_sensitive.py`
  (`/home/rocky/synx-skills/sensitivity-audit/scripts/audit_sensitive.py`,
  verified read 2026-09-22) — a manual, ad-hoc scanner built for this
  repo's 2026-08-27 split. Its `COMPANY_TERMS`/`PERSONAL_NAMES` lists are
  hardcoded real company/personal identifiers directly in source
  (`audit_sensitive.py:31-56`) — exactly the dependency `ccxp-skills`'
  own `CLAUDE.md` forbids, so it cannot be vendored as-is. Its *structural*
  heuristics (private IPv4 ranges, credential-token patterns, personal
  home-dir paths) are portable and worth mirroring; its denylists are not,
  and it isn't CI-wired or config-driven either way.

## Solution

New script `repo-conventions/scripts/lint_identifiers.py`, same shape as
`lint_refs.py`/`lint_tasks.py`:

1. **Generic structural checks — zero config, on by default, ships with no
   identifiers hardcoded**: private IPv4 ranges (`10.*`, `192.168.*`,
   `172.16-31.*`), GitHub/AWS-style credential-token patterns, and personal
   absolute home-dir paths (`/home/<name>` where `<name>` isn't a small
   allowlisted generic set: `ci`, `runner`, `ubuntu`).
2. **Configured denylist — optional, empty by default**: exact
   company/product terms + real personal names, read from
   `INTERNAL_IDENTIFIERS_FILE` (path to a newline-delimited file) or
   `INTERNAL_IDENTIFIERS` (inline comma/newline-separated env var) — the
   same env-var-config-not-committed-data pattern `lint_refs.py`'s
   `KNOWN_SIBLING_REPOS` already established in this file family. Unset →
   empty list → this class is a no-op (graceful degrade, same posture as
   every other optional knob in this suite).
3. **Private-repo link form** (`github.com/<org>/<repo>`) — the "highest-
   signal leak, easiest to grep" case the task's own Notes call out —
   checked against `INTERNAL_PRIVATE_REPOS`, a third env-var-configured
   denylist of private repo slugs. Kept separate from class 2 so a
   consumer can enable just this class without a full company-term list.
4. **Suggestion mapping**: the placeholder vocabulary table above ships
   *committed in the script* (generic wording, not a real identifier —
   safe to publish). A denylist hit reports its suggested placeholder when
   one maps; otherwise reported bare, for a human to disposition.
5. **Wiring**: fold into the existing `lint-tasks` job in
   `.github/workflows/tests.yml` (one job, not a new one — satisfies Done
   criterion #5 directly) running `lint_identifiers.py --all` against all
   tracked text files (broader than `dev/**` — the leak vector was task/
   journal files specifically, but the check itself should cover any
   tracked file the same way `sensitivity-audit` does, since nothing about
   the leak mechanism is dev/-specific).
6. **`/migrate-task` integration**: `scripts/migrate.sh` step 6 (already
   runs `lint_tasks.py --changed` on the copied file) gains one more call —
   `lint_identifiers.py --changed <file> --fix`: substitute a denylist hit
   for its mapped placeholder when one exists; **hard-refuse** (non-zero,
   no commit) when a hit has no mapped placeholder, printing the check's
   own guidance. This satisfies Done criterion #4 exactly.

### Alternatives considered and rejected

- **Ship the real identifier list committed in `ccxp-skills`.** Rejected —
  this task's own open question already flags that this defeats the
  purpose (naming the private repos inside a public lint list), and it
  conflicts with this repo's `CLAUDE.md` charter of no company-specific
  dependency. Env-var config (precedented by `lint_refs.py`) avoids this
  entirely.
- **Vendor `synx-skills/sensitivity-audit`'s `audit_sensitive.py`
  wholesale.** Rejected — its denylists are hardcoded in source (the exact
  dependency this repo can't carry), and it's a manual/ad-hoc scan, not
  CI-wired or config-driven, so it wouldn't satisfy Done criteria #1/#2/#5
  regardless. Its portable structural heuristics are mirrored; its data is
  not.
- **Network-probe every `github.com/<org>/<repo>` link at CI time
  (`gh api`, mirroring `lint_refs.py`'s typed-ref resolution) to
  auto-detect private repos by 404.** Rejected for this check — rate-limit
  and flakiness risk on every push, and both real incidents already
  involved a small, known, enumerable set of private repo slugs, so a
  configured denylist is simpler and sufficient.
- **One monolithic env var for everything.** Rejected in favor of three
  separate knobs so a consumer can enable just the pieces it needs, and so
  the structural checks (class 1) never depend on any config existing at
  all.

## Root cause

- Why leaks recur: `/migrate-task` (added T20260827-201400) and normal
  task-file authoring both cite real repos/PRs as evidence *by design* — a
  good bug report names what it's about. The go-public flip
  (`dev/JOURNAL/2026-09-14-T20260914-234656-finish-public-release-prep.md`)
  was a one-time manual scrub with no pre-merge gate behind it, so the very
  next `/migrate-task` run (`dd991b5`) and two follow-up commits
  (`6ef5731` 09-15, `5a1e443`/`64d693e` 09-16) reintroduced real
  identifiers before this task's check existed to catch them. This is
  process-shape (the normal task flow re-triggers it), not a one-off
  mistake — hence a CI gate, not another manual sweep.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/lint_identifiers.py` | new | the check itself (3 signal classes + suggestion mapping) |
| `repo-conventions/scripts/test_lint_identifiers.py` | new | unit tests |
| `repo-conventions/scripts/lint.sh` | ~`96-104` | wire in `--all` mode, read-only report |
| `.github/workflows/tests.yml` | `51-63` (`lint-tasks` job) | add `lint_identifiers.py --all` step |
| `migrate-task/scripts/migrate.sh` | step 6 (land destination) | add `--fix`-or-refuse call |
| `migrate-task/tests/migrate_task.bats` | new case | assert the refuse/fix path fires |

## Test plan

- [ ] Unit: structural checks (private IPv4, credential-token pattern,
      personal home path) each fail on a synthetic positive and pass on
      this repo's own legitimate content (its own org slug, `/home/ci`,
      established placeholders) — `test_lint_identifiers.py`
- [ ] Unit: denylist-from-env-var hit + placeholder-suggestion mapping;
      `INTERNAL_IDENTIFIERS`/`INTERNAL_IDENTIFIERS_FILE` unset → no-op
      (empty list, exit 0) — `test_lint_identifiers.py`
- [ ] Unit: private-repo-link form caught via `INTERNAL_PRIVATE_REPOS` even
      when the bare org/repo name alone wouldn't trip the denylist —
      `test_lint_identifiers.py`
- [ ] Local: `bash repo-conventions/scripts/lint.sh` reports the new check
- [ ] CI: `tests.yml`'s `lint-tasks` job runs `lint_identifiers.py --all`
      and is green on `main` as-is (zero false positives on current
      content)
- [ ] `migrate-task/tests/migrate_task.bats` gains a case asserting the
      `--fix`-or-refuse call fires in step 6

## Done criteria

- [ ] A check fails CI when a configurable set of internal identifiers appears in tracked files — `test_lint_identifiers.py::test_ci_fails_on_denylist_hit`, wired via `.github/workflows/tests.yml:60`
- [ ] The identifier list lives in config, not hardcoded — `test_lint_identifiers.py::test_env_var_config_no_code_change`
- [ ] `Synx-Data-Labs/ccxp-skills` and the established placeholders never trip it — `test_lint_identifiers.py::test_own_repo_and_placeholders_pass`
- [ ] `/migrate-task` genericizes on the way in, or refuses and points at the check — `migrate-task/tests/migrate_task.bats::migrate genericizes or refuses on internal identifiers`
- [ ] Runs in the same workflow as the existing doc/task lints — folded into `lint-tasks` job, `.github/workflows/tests.yml:60`

## Notes

- **Open design question — resolved**: the identifier list is injected via
  env var/file only (`INTERNAL_IDENTIFIERS`/`INTERNAL_IDENTIFIERS_FILE`/
  `INTERNAL_PRIVATE_REPOS`), never committed to any repo's git history —
  see `## Solution` and its alternatives-rejected above. `ccxp-skills`
  itself ships and runs the check with these unset (generic structural
  checks only); a private company repo adopting this script supplies its
  own list via CI secret/config, out of band.
- `repo-conventions/scripts/lint_refs.py` remains the closest existing
  model (link-aware, `--all`/`--changed`/`--fix` modes, already wired into
  CI) — see `## Context` for the specific mechanisms reused.
