---
status: Coding
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
    (`known_sibling_repos()` at `lint_refs.py:86-92`, its
    `os.environ.get("KNOWN_SIBLING_REPOS", "")` read at line 91; the
    `LINT_REFS_GH` override read is in `gh_argv()` at line 287) — the exact
    pattern this task needs for its own denylist.
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
   allowlisted generic set of CI-runner/cloud-image default account names:
   `ci`, `runner`, `ubuntu`, `root`, `rocky` — none a real person or
   company-specific, the same tier as `ubuntu` being Ubuntu's cloud-image
   default).
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
4. **Suggestion mapping — corrected during implementation to be config-
   driven too, not a fixed dict shipped in the script**: each
   `INTERNAL_IDENTIFIERS`/`INTERNAL_IDENTIFIERS_FILE` entry is `term` or
   `term=placeholder` (e.g. `acme corp=your-org/hub-repo`). This makes the
   mapping itself grow via config, same as the denylist — a stronger fit
   for Done criterion #2 ("lives in config, not hardcoded") than a
   committed dict would have been, since a committed dict would need a
   code change every time a consumer added a new mapped term. A denylist
   hit reports its suggested placeholder when its entry carries one;
   otherwise reported bare, for a human to disposition.
5. **Wiring**: add a `lint_identifiers.py --all` step to the existing
   `lint-tasks` job in `.github/workflows/tests.yml` (one job, not a new
   one — satisfies Done criterion #5). Note this job today only runs unit
   suites (`test_lint_tasks.py -v`, `test_lint_paragraphs.py -v`) — there
   is no existing `--all`-repo-scan step to mirror in *this* repo's own CI
   (that mode is otherwise only exercised via local `lint.sh`, or the
   separate `actions/lint-tasks/action.yml` reusable action for consumer
   repos); adding one is simple, just not literally copying an existing
   step's shape. **Scope — narrowed during implementation from this
   design's original "all tracked files" plan**: `--all`'s default is
   `dev/TODO/*.md` + `dev/JOURNAL/*.md` (`SCAN_DIRS`, same convention as
   `lint_refs.py`'s `REF_DIRS`), not the whole repo. Empirically, a
   whole-repo `--all` run against this repo's actual content produced 32
   findings that are all false positives: illustrative RFC1918 example IPs
   in unrelated skill reference docs (`cloudflare/references/**`) and
   synthetic test-fixture home paths in `*.bats` files. Both real
   incidents this check exists for happened in `dev/TODO`/`dev/JOURNAL`
   task/journal authoring, never in reference documentation, so narrowing
   the CI-wired default there is a straight false-positive fix, not a
   coverage regression against the actual leak vector. `--changed` (used
   by CI's per-PR path and by `/migrate-task`) is unaffected — it scans
   whatever files it's given, not restricted to `dev/**`.
6. **`/migrate-task` integration — scoped to the code that actually
   exists**: `migrate-task/scripts/migrate.sh`'s live (non-`--dry-run`)
   "land destination" flow is an **unimplemented stub today**
   (`migrate.sh:292-293`, `return 8`, "not exercised in unit tests") — it
   is *not* a real step 6 to hook a call into. The part that IS real,
   unit-tested code is the `--dry-run` path's staged-copy: `cp
   "$source_file" "$staged"` followed by two `mt-fm-delete` calls
   (originally `migrate.sh:241-243`, now the hook lands at
   `migrate.sh:256-265` after implementation), previewed via
   `diff -u /dev/null "$staged"`.
   Hook `lint_identifiers.py --changed "$staged" --fix` in right after
   those `mt-fm-delete` calls: substitute a denylist hit for its mapped
   placeholder when one exists; **hard-refuse** (non-zero, no diff shown)
   when a hit has no mapped placeholder, printing the check's own
   guidance. This satisfies Done criterion #4 within the code that
   actually exists and is exercised by `tests/migrate_task.bats`'s
   existing `--dry-run` test; wiring the same call into the live path is
   automatically covered once that path is implemented (tracked
   separately — it's a pre-existing gap, not new scope this task should
   absorb).

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

- Why leaks recur: task/journal authoring — whether a manual cross-repo
  migration or the `/migrate-task` skill that formalized it — cites real
  repos/PRs/paths as evidence *by design*: a good bug report names what
  it's about. The go-public flip
  (`dev/JOURNAL/2026-09-14-T20260914-234656-finish-public-release-prep.md`)
  was a one-time manual scrub with no pre-merge gate behind it.
  **Corrected timeline** (verified via `git log`/`git show`, 2026-09-22 —
  an earlier draft of this section misattributed one commit): `dd991b5`
  (2026-09-14 22:13, "migrate 3 tasks in from synxdb-team") is itself a
  **manual** migration — its own message says "landing here directly" —
  and it *predates* `6ef5731` (2026-09-15 07:42, "add /migrate-task
  skill") by hours, so it cannot have gone through that tool. The actual
  recurrence is simpler and, if anything, a stronger case for a CI gate
  rather than a weaker one: identifiers leaked back in via ordinary manual
  task authoring/migration (`dd991b5`) and again via unrelated follow-up
  commits (`6ef5731`, `5a1e443`, `64d693e`) within 48 hours of the scrub —
  no special tool was even required for the leak to recur, which is
  exactly why a manual-scrub-only defense can never hold and a pre-merge
  gate covering *all* commits is the right fix.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `repo-conventions/scripts/lint_identifiers.py` | new | the check itself (3 signal classes + suggestion mapping) |
| `repo-conventions/scripts/test_lint_identifiers.py` | new | unit tests |
| `repo-conventions/scripts/lint.sh` | ~`96-104` | wire in `--all` mode, read-only report |
| `.github/workflows/tests.yml` | `51-63` (`lint-tasks` job) | add `lint_identifiers.py --all` step |
| `migrate-task/scripts/migrate.sh` | `256-265` (`--dry-run` staged-copy) | `--fix`-or-refuse call after the `mt-fm-delete` calls |
| `tests/migrate_task.bats` | new case (after line 247's `--dry-run` test) | assert the refuse/fix path fires |

## Test plan

- [x] Unit: structural checks (private IPv4, credential-token pattern,
      personal home path) each fail on a synthetic positive and pass on
      generic allowlisted paths (`/home/ci`) — `test_lint_identifiers.py`
      `StructuralChecksTest` (7 tests, all pass)
- [x] Unit: denylist-from-env-var hit + config-driven placeholder-
      suggestion mapping (`term=placeholder`); unset → no-op (empty list) —
      `test_lint_identifiers.py` `DenylistTest` (7 tests, all pass)
- [x] Unit: private-repo-link form caught via `INTERNAL_PRIVATE_REPOS`, own-
      repo-slug exclusion verified even when misconfigured —
      `test_lint_identifiers.py` `PrivateRepoLinkTest` (3 tests, all pass)
- [x] Unit: `--fix` substitutes mapped hits and refuses (non-zero) on any
      unmapped/structural hit — `test_lint_identifiers.py` `ApplyFixTest` +
      `MainCliTest` (6 tests, all pass; 23/23 total in the module)
- [x] Local: `bash repo-conventions/scripts/lint.sh` reports the new check
      ("dev/ internal identifiers... ✅ no internal identifiers found")
- [x] CI: `tests.yml`'s `lint-tasks` job runs `lint_identifiers.py --all`
      — verified locally with the exact CI invocation
      (`python3 repo-conventions/scripts/lint_identifiers.py --all .`),
      zero findings on `main`'s current `dev/TODO` + `dev/JOURNAL` content
- [x] `tests/migrate_task.bats` gains two cases (genericize + refuse) in
      the `--dry-run` staged-copy path (`migrate.sh:256-265`) — both pass;
      full suite re-verified at 736/736 (one unrelated pre-existing flake
      on `task_claim.bats` reproduced clean on rerun, confirmed unrelated
      to this change)

## Done criteria

- [x] A check fails CI when a configurable set of internal identifiers appears in tracked files — `test_lint_identifiers.py` (23 tests, all pass) + the CI step at `.github/workflows/tests.yml:67`
- [x] The identifier list lives in config, not hardcoded — `denylist_from_env()`/`private_repos_from_env()` (`lint_identifiers.py`), verified by `DenylistTest::test_inline_env_var_parsed_with_suggestion` + `test_file_env_var_read_when_set` + `test_env_var_unset_means_no_denylist`
- [x] `Synx-Data-Labs/ccxp-skills` and the established placeholders never trip it — `DenylistTest::test_own_repo_slug_excluded_from_denylist_hits` + `test_placeholder_vocabulary_never_trips_denylist`; also confirmed live via `--all .` against this repo's actual content (0 findings)
- [x] `/migrate-task` genericizes on the way in, or refuses and points at the check (scoped to the `--dry-run` staged-copy path — the only "land destination" code that exists today; the live path is an unimplemented stub, `migrate.sh:292-293`) — `tests/migrate_task.bats`'s "--dry-run genericizes a mapped internal identifier in the staged copy" + "--dry-run refuses when the staged copy has an unmapped internal identifier" (both pass)
- [x] Runs in the same workflow as the existing doc/task lints — folded into `lint-tasks` job, `.github/workflows/tests.yml:67`

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
