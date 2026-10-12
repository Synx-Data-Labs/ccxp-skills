---
status: Open
estimation: 1
source: User request 2026-08-29; scope grown 2026-09-01 (maintainer
  direction, see "## Design update" below — was 2h for a markdown
  checklist, now includes a real skill implementation)
related: T20260827-238870
---

# T20260829-362863: `/repo-conventions setup [solo|team]` — bootstrap or migrate a repo's convention mode

## Problem

- **Type**: chore
- Terminology, settled 2026-08-29: the non-solo mode is **"team mode" /
  "team repo"** everywhere — matching what `T20260827-238870`'s own title
  already coined ("team-repo (peer/CI) process"). Retire "coop mode" as an
  alternate spelling; it appears nowhere in the current docs (`grep -rn
  "coop" *.md` outside `dev/` — zero hits, confirmed 2026-08-29).
- `T20260827-238870` removes solo-repo mode from the *skill definitions*
  (`claim/SKILL.md`, `drive/SKILL.md`) so the suite stops offering it at
  all — but its own Notes explicitly punt on "what does converting an
  actual live repo look like": *"if one does [declare itself solo/no-CI],
  that repo's own Branch and Merge Policy needs updating too, as a
  follow-up task ... not in scope here."* This task is that follow-up,
  generalized: a checklist any repo already on the ccxp process (any repo
  with `dev/TODO/` + this skill suite installed) can run through, not tied
  to one specific repo.
- **Surprising finding while drafting this (verified against synx-skills
  itself, 2026-08-29):** `bash ~/.claude/skills/_gh/gh.sh api
  repos/Synx-Data-Labs/synx-skills/rulesets` shows this repo is protected
  by an **organization-level** ruleset ("protect default", `source_type:
  Organization`, `enforcement: active`) — not a repo-level classic branch
  protection (`.../branches/main/protection` 404s: "Branch not
  protected"). Its rules: `deletion` blocked, `non_fast_forward` blocked,
  `required_linear_history`, and a `pull_request` rule requiring a PR
  (`required_approving_review_count: 0`, `allowed_merge_methods:
  ["rebase"]`, `required_review_thread_resolution: true`) — and critically,
  **`"current_user_can_bypass": "never"`, `"bypass_actors": []`**. If this
  org ruleset applies to a given repo, a direct `git push` to `main`
  (exactly what `claim/SKILL.md`'s "Solo-repo mode" recipe does via
  `git merge --ff-only ... && git push`) is **already rejected by GitHub
  itself**, regardless of what that repo's own `dev/guidelines.md` claims.
  So for any repo already covered by this org ruleset, the GitHub-side
  "protect it" work may be a **no-op to verify, not a change to make** —
  the real remaining work is almost entirely the *documentation* declaring
  itself solo/no-CI, which is now simply false. Confirm this per-repo
  (below) rather than assuming it — an org ruleset can be scoped to a
  subset of repos, and a repo outside the `Synx-Data-Labs` org entirely
  gets none of this for free.
- Note also (from `gotchas.md`): a ruleset can override the repo-settings
  API's `allow_squash_merge`/`allow_merge_commit`/`allow_rebase_merge`
  flags without those flags reflecting it — always check
  `.../rulesets`, never just `.../branches/main` or the repo settings API,
  to know what's actually enforced.

## Relationship to T20260827-238870 (added on migration to ccxp-skills)

Overlaps T20260827-238870 (remove solo-repo mode). Once solo mode is
retired, the `setup solo` half of this task should be cut: rescope to
team-only setup (bootstrap/convert a repo into team mode).

## Design update (2026-09-01, maintainer direction — in-conversation)

**Scope grew from "write a markdown checklist" to "implement it as a real
command."** The maintainer asked for `/repo-conventions` to gain a `setup`
argument:

- `/repo-conventions setup [solo|team]` — new verb, alongside the existing
  `check | sync | show`. **Default: `team`.**
- **`setup team`** (default) — bootstrap a new repo onto the canonical
  team/CI-gated convention, *or*, if the repo is currently declared
  solo/no-CI, **migrate it** — this is exactly the "## What we know today"
  checklist below, made executable instead of a procedure a human runs by
  hand:
  1. Verify GitHub-side branch protection (rulesets API, not classic
     branch-protection — see the org-ruleset finding below).
  2. If missing, create a repository ruleset (the sketch below, verified
     against a real repo before shipping — flagged as unverified in the
     original checklist).
  3. Confirm CI workflows actually exist (`.github/workflows/` non-empty).
  4. Rewrite the repo's `dev/guidelines.md`/`CLAUDE.md` Branch and Merge
     Policy to the canonical team wording
     ([`templates/guidelines.md`](../../repo-conventions/templates/guidelines.md)
     — already team-only, no solo variant exists there today).
  5. Surface the "tell whoever's been pushing direct-to-main" operational
     step as an explicit report line, not a silent no-op.
- **`setup solo`** — bootstrap a *new* repo with a lighter no-CI/
  direct-to-main flavored `guidelines.md`. **No such template exists yet**
  — every repo that declares itself solo today hand-writes its own prose,
  which `claim`/`drive`'s detection heuristic (`grep -qi "no ci"` +
  `"direct.to.main"` on that repo's own doc) then greps for. This work
  needs a new `templates/guidelines-solo.md` (or an equivalent
  solo-flavored section swap in the existing template) so `setup solo`
  produces a doc that heuristic actually recognizes.
- **Migration detection** reuses that same heuristic — a repo whose
  `dev/guidelines.md`/`CLAUDE.md` already reads solo/no-CI is "needs
  migrating"; a repo with neither the doc file nor that declaration is
  "brand new, just scaffold."

**Relationship to `T20260827-238870`** (still Open, unclaimed) — does NOT
block this work, but is worth noting:

- That task removes solo-mode *runtime behavior* from `claim`/`drive` (the
  skip-PR-ceremony branch when claiming/driving a task). This task operates
  one layer down — the repo-scaffolding/doc/GitHub-config layer.
- They're compatible: once `T20260827-238870` lands, a `setup solo`-declared
  repo simply won't get special `claim`/`drive` treatment anymore (that
  specific behavior becomes vestigial for solo repos).
- `/repo-conventions setup solo` can still be useful as a "no CI configured
  yet" starting point for a brand-new repo before it's wired up — a separate
  concern from whether `claim`/`drive` special-case it at runtime.
- Not resolving that overlap now; flagging it so a future reader isn't
  confused about why "solo mode" seems to exist in two places with
  different fates.

**Not yet decided / open when this is actually driven:**

- Exact CLI surface for confirmation before the GitHub ruleset POST (a
  moderately consequential, if reversible, live-repo mutation) — likely an
  explicit "confirm before creating" step, consistent with this session's
  general caution around GitHub-side mutations, but not spec'd out here.
- Whether `setup team`'s migration should also be runnable non-interactively
  (for a future `/ccxp`-driven repo-onboarding flow) or stays
  interactive-only for now.

## What we know today: the conversion touchpoints

1. **Verify the GitHub-side protection state first** (don't assume):

   ```bash
   bash ~/.claude/skills/_gh/gh.sh api repos/<owner>/<repo>/rulesets
   bash ~/.claude/skills/_gh/gh.sh api repos/<owner>/<repo>/branches/main/protection   # expect 404 if ruleset-based
   ```

   - An active ruleset (org- or repo-sourced) with a `pull_request` rule
     and `bypass_actors: []` → direct pushes are already blocked; skip to
     step 3.
   - No ruleset, or one with bypass actors, or classic branch protection
     without `required_pull_request_reviews` → still needs real
     GitHub-side setup (step 2).
   - Repo isn't in an org with a standing ruleset at all → definitely
     needs step 2.
2. **If GitHub-side protection is genuinely missing**, add a repository
   ruleset (rulesets are the current mechanism — org already uses them,
   per the finding above; don't reach for the older classic
   branch-protection API):

   ```bash
   bash ~/.claude/skills/_gh/gh.sh api repos/<owner>/<repo>/rulesets \
     --method POST -f name="protect main" -f target=branch \
     -f 'conditions[ref_name][include][]=~DEFAULT_BRANCH' \
     -f enforcement=active \
     -f 'rules[][type]=deletion' \
     -f 'rules[][type]=non_fast_forward' \
     -f 'rules[][type]=required_linear_history' \
     -f 'rules[][type]=pull_request' \
     -F 'rules[][parameters][required_approving_review_count]=0' \
     -f 'rules[][parameters][allowed_merge_methods][]=rebase'
   ```

   (Sketch, not yet run against a live repo — `gh api`'s `-f` flattening
   for nested arrays-of-objects is finicky; verify against a real repo
   before trusting this verbatim, or build the JSON body with `--input -`
   instead. Caught in review: `-f` sends a raw string, so an integer field
   like `required_approving_review_count` needs `-F` instead, or GitHub's
   schema likely rejects the stringified `"0"` — fixed above, but this is
   exactly the class of bug `--input -` with a real JSON body avoids
   entirely. Mirror whatever the org's actual "protect default" ruleset
   already enforces — dump it with `gh api
   repos/Synx-Data-Labs/synx-skills/rulesets/15124316` as the reference
   shape, shown in the Problem section above — rather than inventing a new
   policy per repo.)
3. **Confirm CI actually exists and is required in practice.** The org
   ruleset above does *not* include a `required_status_checks` rule —
   "CI must pass" is enforced by `address-pr`'s own `pre-merge-check.sh` /
   manual-gate discipline (software-level), not a hard GitHub requirement
   in this org's current ruleset. A repo converting from solo mode needs
   at minimum the equivalent of this repo's `markdown-lint.yml`/
   `tests.yml` workflows to exist at all — verify
   `.github/workflows/` isn't empty before claiming "CI-gated."
4. **Update that repo's own `dev/guidelines.md` (or `CLAUDE.md`) Branch and
   Merge Policy** — replace any "solo repo, no CI, direct-to-`main`"
   language with the canonical policy verbatim from
   [`repo-conventions/templates/guidelines.md`](../../repo-conventions/templates/guidelines.md)
   (feature branch → PR → CI green → rebase merge → delete branch). This
   is also what flips `claim`/`drive`'s own detection — both skills detect
   solo mode by grepping *that repo's own doc* for `"no ci"` +
   `"direct.to.main"`; removing the declaration makes them treat the repo
   as team mode immediately, independent of whether `T20260827-238870`'s
   suite-wide removal has landed yet.
5. **Operational, not technical**: tell whoever/whatever has been pushing
   directly to `main` (a human, a cron session) that the workflow changed
   — a currently-checked-out local branch mid-work under the old solo
   recipe should finish via a PR instead of the old `--ff-only` merge, not
   get force-pushed past the new protection.
6. **Nothing to do for the statusline rationale** — `claim/SKILL.md`'s
   solo-mode section built the branch+claim-commit habit specifically so
   `statusline-setup`'s `branch:`/`TASK:` signals show something useful;
   the standard peer/CI claim-PR path already does this identically (see
   `T20260827-238870`'s Notes) — no separate fix needed here.

## Done criteria

- [ ] `/repo-conventions setup [solo|team]` (default `team`) exists as a new
  argument in `repo-conventions/SKILL.md`, alongside `check|sync|show`.
- [ ] `setup team` against a repo with no existing `dev/guidelines.md`/
  `CLAUDE.md` bootstraps the canonical team-mode docs (reusing `sync`'s
  template-copy mechanism where it overlaps).
- [ ] `setup team` against a repo already declared solo/no-CI (via the
  `claim/SKILL.md`-shared detection heuristic) performs the actual
  migration: verifies/creates GitHub branch protection, confirms CI
  workflows exist, rewrites the Branch and Merge Policy section, and
  reports the "notify whoever's pushing direct-to-main" operational step.
- [ ] `setup solo` bootstraps a new repo with a new solo-flavored
  `guidelines.md` template (`templates/guidelines-solo.md` or equivalent)
  that `claim`/`drive`'s existing detection heuristic actually recognizes.
- [ ] Step 2's sketch `gh api` ruleset-creation command is either verified
  against a real test repo (confirm the nested `-f` flattening actually
  produces the intended ruleset shape) or replaced with a `--input -`
  JSON-body version — mark whichever was done.
- [ ] A confirmation step gates the actual GitHub ruleset creation/mutation
  (moderately consequential, live-repo, reversible-but-not-trivially
  action) — not silently auto-applied.
