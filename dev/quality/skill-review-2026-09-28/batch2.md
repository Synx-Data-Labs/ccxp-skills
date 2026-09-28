# Skill review — batch 2 (retro, address-pr, gcpr, land, cleanup-branch, rca, labrun-rca)

Refs verified against the repo at review time. "OK" paths checked with `[ -e ]`: `_gh/{gh,git,ci-triage}.sh`, `_taskid/{new,url,in-this-repo}.sh`, `_ipm/{stamp-scheduled,current}.sh`, `_docs/{lint-docs,doc-impact}.sh`, `_session/{pr_task_id,status,set-pr-ref,task_claim}.sh`, `slack/scripts/slack-send.sh`, `repo-conventions/scripts/{lint_paragraphs,lint_refs}.py`, `retro/scripts/*`, `quality-probe/SKILL.md`, `stage/SKILL.md`. The phase anchors cited in `drive` (1.5, 3.0, 3.8, 4, 7) and `ccxp` (1.2.1, 1.2.2a, 1.4, 2a.5, 2a.6) all exist.

## retro

- Grades: concision D | trigger A | clarity C | determinism C | correctness C
- Est. cuttable: ~40% (566 lines → ~330)
- Top recommendations:
  1. **Remove the changelog narrative.** Examples: retro/SKILL.md:37 (the "confirmed 30 vs 83 on 2026-07-10" aside), :40 ("recurred 3 retros running … T20260702-279977"), :53, :55, :75 (the "confirmed 2026-08-24 … 85 files since March" story), :98 (the `feedback_ephemeral_clone` precedent), :215, :379, :529. Phase 2b explains itself twice (:261-269 and :305-310), so delete the second copy. Keep each rule and move the reason to JOURNAL.
  2. **Script the mechanical phases.** Five phases need no judgment: the cron-log loop (:57-67), the Phase 1c Rule A/B resolver (it currently has a `jq '...'` placeholder at :140, so it can't be run as written), the bump-counter (the 3-IPM set intersection at :51-53), the Phase 2b sweep loop (:274-286), and the Phase 4b `priority: High` stamp (:365). Move them into `retro/scripts/` with BATS tests, the way `chore-review.sh` and `estimation-revisions.sh` already are.
  3. **Fix the task-file schema in Phase 4.** retro/SKILL.md:350-355 says to use "metadata bullets in this exact order" (Estimation/Status/Blocks/Source/Description). But dev/guidelines.md:112 and todo/SKILL.md:62 say YAML frontmatter with lowercase keys. Replace the list with "frontmatter per todo/SKILL.md" and put `Category:` in the body.
  4. **Fix the ordering and branch gaps.**
     - Phase 3's table (:333) reports "Escalated to High", but Phase 4b (a later phase) computes it. Phase 4d also adds a "Quality trend" row (:431) that the :316 table doesn't define. Either compute metrics last or say "fill after 4b/4d".
     - Phase 2b does `git checkout -b` mid-retro (:274), and nothing says which branch the Phase 5 report, the Phase 4 tasks or the Phase 1d edits land on. Phase 1d (:185) says "same PR as … Phase 5", but Phase 5 has no commit/PR step. Add an explicit final "commit + PR + /address-pr" step.
     - "In flight … Tier 1 carry-over" (:216) contradicts the template's "Tier 2 carry-over" (:457).
- Verified stale refs:
  - `dev/chore.md` "seed row" / "auto-merge trial's 06-12 evaluation" (:171-172): there is no `dev/chore.md` in this repo, so the worked example is unreachable.
  - Phase 4c "if a rubric exists in superpowers:writing-skills … Until it exists" (:380): an open-ended conditional on an external skill.
  - `feedback_invoke_address_pr_not_bypass_merge` memory (:387): points at a user-local memory, not a repo artifact.
  - The Phase 4 bullet schema (see rec 3).
- Eval cases:
  - Repo with no `dev/chore.md` and no `*-ipm-weekly.md` for this Monday → report says "No IPM commit this week", has no "Chore review" section, and never runs `chore-review.sh evaluate`.
  - Fixture `drive-threads.json` with key `T20260101-123456-pr42` (PR 42 MERGED) plus a 20-day-old unmatched key → first entry `resolved:true` with `resolved_at` = mergedAt; second listed under "Stale escalations" and still `resolved:false`.
  - Unattended run with `RETRO_SLACK_CHANNEL` unset → no `slack_send_message` call, and the report contains "no RETRO_SLACK_CHANNEL configured".

## address-pr

- Grades: concision D | trigger A | clarity C | determinism B | correctness D
- Est. cuttable: ~45% (364 → ~200)
- Top recommendations:
  1. **The hard gate script is stale and located ambiguously.**
     - address-pr/SKILL.md:176 runs `bash scripts/pre-merge-check.sh`, a path relative to the consumer's cwd. :173 then says "Repos without the script — e.g. ccxp-skills — fall back to manual". But the script ships in this repo at `address-pr/scripts/pre-merge-check.sh`, and it still gates on Copilot (pre-merge-check.sh:15, :77-171 look for `copilot-*` bot reviews). That mechanism is retired per gotchas.md:41 and SKILL :207.
     - The check passes only because the deprecated `pushedDate` returns empty (:132 → the `-n "$LAST_PUSH"` guard at :155).
     - Fix: call `../address-pr/scripts/pre-merge-check.sh`, and replace check 2 with a check for a "**Claude Code review:** (sha: HEAD)" comment on the current head SHA. That also closes the backstop gap :173 admits to.
  2. **Remove the rationale and history.** §1.6 :93 (old-marker history with PR numbers), :123 (a parenthetical about a tooling bug), :142-149 (the whole `_tc_is_own_cross_repo_clone` internals explanation; that belongs in `_session/README.md`), §1.5 :83 and :85, §2.d :207, :254 and :257 (Copilot-era comparisons), and the :259 design essay. Keep the decision table and the procedures.
  3. **Fix the contradictions.**
     - Important Notes :357 says a fresh review is dispatched "when the newest review comment predates the latest push". §2.d (:209, :226) says it is keyed by head SHA. Make :357 match §2.d.
     - :312 (PR-title rule) is buried in "Verify test plan". Move it to gcpr §6 or delete it.
     - :340 and :3 say "tiered merge" per `dev/guidelines.md`, but this repo's guidelines (:91-100) have no tiers. Define the tiers here or name the consumer-side section.
  4. **Fix the portability leaks.**
     - :259 hardcodes a `synx-merge-bot` App and `pr-approve.yml`. That is company-specific (CLAUDE.md says "no company-specific dependency"), and there is no `pr-approve.yml` in `.github/workflows/`.
     - :241 `subagent_type: code-improvement-scanner` is defined nowhere in the repo. Say "general-purpose" or a documented agent.
     - :361 `bats tests/` is repo-specific.
     - §1.3 authorship (:43-52) duplicates auto-pick.sh's `--author @me`. Fold the explicit-PR authorship check into a script (e.g. `auto-pick.sh --check <n>`) so both paths share one tested verdict.
- Verified stale refs: all Copilot references in `pre-merge-check.sh` (:15, :77-171); "Repos without the script — e.g. ccxp-skills" (:173) is false; `code-improvement-scanner` is not defined in the repo; `pr-approve.yml` / `synx-merge-bot` don't exist here; :357 describes timestamp-keyed review (superseded by SHA-keyed).
- Eval cases:
  - `/address-pr <N>` where the PR author ≠ `gh api user` → no `gh pr merge`, `pr comment` or `pr edit` calls; output contains "not us".
  - Stubbed `task_claim.sh pr-owner` → `owned:cc1-x:y` → no `pre-merge-check.sh` or merge invoked; output contains "deferring".
  - Head SHA equals the SHA in the last "**Claude Code review:** (sha: …)" comment → no Agent dispatch that iteration. Every `gh pr merge` call includes `--rebase`.

## gcpr

- Grades: concision C | trigger B | clarity C | determinism C | correctness C
- Est. cuttable: ~35% (255 → ~165)
- Top recommendations:
  1. **Remove the hardcoded attribution and the Copilot references.** gcpr/SKILL.md:163 and :172 hardcode `Co-Authored-By: Claude Opus 4.6 (1M context)`. That is stale, and it conflicts with the harness-injected attribution. Replace it with "use the attribution lines the harness/system prompt provides". Copilot is still named at :8, :213, :253 and :255 even though address-pr no longer uses Copilot. Say "Claude Code review".
  2. **Put the three changed-file extractors in one script.** They are :61-64, :85 and :100. The last two use `awk '{print $2}'`, which breaks on renames and deletes (open task T20260922-155006). Move all three plus the lint calls into `gcpr/scripts/pre-commit-lint.sh` with BATS tests covering renamed, deleted and untracked files. Also script the step-1 state decision (:44-51: nothing / push-only / PR-exists / normal), which is a pure lookup.
  3. **Fix the contradictory git rules.**
     - :24 bans destructive ops, then :147 recommends `git rebase -i`. That command is interactive (unsupported in agent envs) and rewrites history. Replace it with "ask the user".
     - §3.5 is numbered before §4 but says "after committing in step 4". Move it after §4.
     - Step 1 hardcodes `main` (:39-40, :132). Resolve the default branch instead.
  4. **§6.5 (:228-232) leaves a dirty tree.** It edits `dev/TODO/T<id>` Status after the PR is created but never commits or pushes. The file isn't present in cross-repo mode (§6 :224), it uses the `Status` bullet wording instead of frontmatter `status:`, and it overlaps address-pr §1.5's Review transition. Either commit it before push or delete it and let address-pr own Review. Also cut the provenance prose at :72-78 and :91-94.
- Verified stale refs: `templates/guidelines.md` (:92) doesn't exist at that path; the file is `repo-conventions/templates/guidelines.md`. Copilot references (:8, :213, :253, :255). The Opus 4.6 trailer (:163, :172).
- Eval cases:
  - Clean tree on branch `feat/x`, 2 commits ahead of main, no PR → no `git commit`; `git.sh push` then `gh pr create`; `/address-pr` invoked.
  - Mixed docs and code changes → ≥2 commits, each with a conventional prefix. The PR body has both `### Pre-merge` and `### Post-merge`. No `git reset`, `git stash` or `--force` appears in the transcript.
  - Staged `.env` → it is not committed and a warning is shown.

## land

- Grades: concision A | trigger B | clarity A | determinism n/a | correctness B
- Est. cuttable: ~0% of the file, but the whole skill is a candidate for removal
- Top recommendations:
  1. **The two descriptions compete as triggers.** land/SKILL.md:3 ("land, commit and push, or open a PR") is broader than gcpr's (gcpr/SKILL.md:3). Both are model-invocable for the same intent, so the model has to pick between two near-identical descriptions. Keep one model-invocable: set `disable-model-invocation: true` on `land` so it is a slash alias only, or make gcpr's description the broader one.
  2. **The alias has a known staleness hazard.** land/SKILL.md:16 says "Invoke the `gcpr` skill directly", which is a nested Skill call and costs an extra round-trip. Consider renaming gcpr to `land` and retiring the abbreviation, per skill-conventions §2 (:33). Only the rationale at :8 would need rewording.
- Verified stale refs: none found
- Eval cases:
  - `/land fix typo` → the gcpr skill is loaded and its workflow runs (`git.sh push`, `gh pr create`). land has no divergent steps.
  - Prompt "commit and open a PR" → exactly one of gcpr/land fires, not both.

## cleanup-branch

- Grades: concision A | trigger A | clarity B | determinism A | correctness C
- Est. cuttable: ~15%
- Top recommendations:
  1. **Data-loss risk.** cleanup-branch.sh:89-92 force-deletes (`-D`) whenever *a* merged PR exists for the head name. That deletes local commits made after the merge, or a reused branch name with new work. Compare the local tip to the PR's `headRefOid` and force-delete only when they match (or the tip is an ancestor). Report the rest as "skipped: local commits after merge".
  2. **Inconsistent default branch.** §1 hardcodes `main` (:61, :71, :99), while §2 detects the default (:25). Use the detected default in both.
  3. **Script standards.** The script isn't sourceable and has no function guard (`main "$@"` runs unconditionally at :112, against dev/guidelines.md:129-146). It uses a fixed `/tmp/cleanup-branch-checkout-err` path (:61). A `git pull` failure (:65) exits through `set -e` with no classified message. There are no BATS tests (no `tests/cleanup_branch*.bats`).
  4. **SKILL wording.** SKILL.md:16-19 and :32 refer to "§1/§2" sections that exist only in the script comments. Name them "PR-verified mode" and "prune mode". SKILL.md:24 passes `$ARGUMENTS` unquoted, which is fine but should be noted as intentional.
- Verified stale refs: none found. The skill has no tests even though its logic is fully scripted.
- Eval cases:
  - Fixture repo, branch `b` whose PR is merged, plus one extra local commit after the merge → with the current script `b` is deleted (regression target). After the fix it is kept with a "skipped" status.
  - `/cleanup-branch prune --dry-run` → no `git branch -D` executed; output contains "Would delete" or "No stale branches".
  - Dirty working tree → non-zero exit, stderr names the checkout failure, and no `git stash` appears in the transcript.

## rca

- Grades: concision B | trigger A | clarity C | determinism B | correctness C
- Est. cuttable: ~20%
- Top recommendations:
  1. **§5.5 (rca/SKILL.md:108-112) auto-posts to a channel root, which conflicts with callers.** It posts unconditionally to `#claude-notification` / `SLACK_STANDUP_CHANNEL`. But labrun-rca (:67) and ccxp 1.2.2 (ccxp/SKILL.md:228) delegate to `/rca` and then post their own thread reply, so every delegated RCA double-posts, and one of those posts goes to a channel root. That contradicts labrun-rca:127 ("Never post to the channel root"). Add "skip §5.5 when invoked by a caller that owns the reply (labrun-rca, ccxp)". Also replace the hardcoded `#claude-notification` with a config var (for example `RCA_SLACK_CHANNEL`) whose unset behaviour is defined.
  2. **Advertised inputs aren't implemented.** The no-arg `/rca` (:16, "auto-pick the most recent failed run on main") has no step. The `[workflow-name]` in argument-hint (:5) is never used, and :74's `<workflow>` has no stated source. Either add step 0 (`gh run list --branch main --status failure --limit 1`) and take the workflow name from step 1's `.name`, or drop them.
  3. **The task-creation branching (§6 :114-160) is hard to follow.** It is three category paths plus an "Unconfirmed is additive" rule. Replace it with one decision table (category × confirmed × recurrence → retry? / task? / Tier 3?). The Tier-3 table insert (:133-140) is a mechanical markdown edit; add it to `_ipm/` as a script (for example `append-tier3.sh`) with BATS tests. Also cut the :49 anecdote ("discovered only on the 7th reproduction") and the task-ID asides at :37, :127, :143.
  4. **The transient-recurrence threshold is unspecified.** "3+ times in last week" (:153) has no command. Step 4's `--limit 5` (:74) can't count a week's recurrences. Give it a concrete `--created` query.
- Verified stale refs: open task T20260924-390953 (dev/TODO) says "rca/SKILL.md has zero Slack integration", but §5.5 already implements it. Either the task is stale or the skill change never went through the task.
- Eval cases:
  - `/rca <id>` on a fixture with no confirming log line or command → report contains "Unconfirmed", a `dev/TODO` task is filed whose action is instrumentation, and `dev/known-failures.md` is not written.
  - Infrastructure classification → `gh run rerun <id> --failed` is invoked before any task is created.
  - Invoked from labrun-rca → exactly one Slack post, and it has `thread_ts` set (catches the §5.5 double-post).

## labrun-rca

- Grades: concision C | trigger A | clarity B | determinism C | correctness C
- Est. cuttable: ~30%
- Top recommendations:
  1. **Stale and inconsistent with /rca.**
     - :71 claims `/rca` uses `gh run view --log-failed`. It actually uses `_gh/ci-triage.sh` (rca/SKILL.md:38).
     - :76 asks for a "confidence" field that /rca's template calls "Classification — Confirmed|Unconfirmed" (rca:96).
     - :102 says the task "lands … on the feature branch where /rca was invoked", but neither skill creates a branch.
     - Replace the :67-74 list with "delegate to /rca (skip its §5.5 Slack post)". That also fixes the double-post described under rca.
  2. **Script the permalink parse and validation (:31-40).** It is pure string work. Add `labrun-rca/scripts/parse-permalink.sh` (it outputs `channel_id message_ts` or exits non-zero) with BATS tests, including permalinks that carry `?thread_ts=` query strings, which the current `${url##*/p}` keeps.
  3. **Dedup is defined three ways.** :44 says "someone has already posted an RCA", edge-case :112 says "reply from labrun-rca", and ccxp 1.2.2a (ccxp/SKILL.md:245) uses the `*RCA —` prefix. Use the `*RCA —` marker in all three places. There's also an ordering gap: the ack is posted (§3) before the "run succeeded on retry" check, which currently lives only in the edge table (:114). Move the conclusion check before the ack.
  4. **Cut the "Reuse from existing skills" section (:117-123)** down to 1-2 lines. :120-122 describe other skills rather than instruct. Replace `#acme-automation-alerts` (:127) with generic wording.
- Verified stale refs: `gh run view --log-failed` as /rca's mechanism (:71, :129); the "Confidence" field name mismatch (:76/:88 vs rca:96); "feature branch" (:102).
- Eval cases:
  - Permalink `https://x.slack.com/archives/C123/p1600000000123456` → `slack_read_thread` called with channel `C123` and ts `1600000000.123456`.
  - The thread already has a reply starting `*RCA —` → no `slack_send_message` and no `/rca` invocation.
  - Every `slack_send_message` in a run has `thread_ts` equal to the parent ts, so there are zero root posts, including anything from /rca.

## Cross-cutting patterns

- **History inside skills.** Dozens of `T2026…` IDs, dated anecdotes and "previously/used to" asides explain why a line exists (retro, address-pr and gcpr are the worst). That is roughly 15-25% of each large file. Proposed rule: a skill may cite a task ID only as a pointer, never as narrative.
- **Copilot-era leftovers remain after the switch to Claude Code review.** They are in address-pr (plus its bundled `pre-merge-check.sh`) and gcpr. The hard gate script still gates on Copilot and passes only because `pushedDate` is deprecated.
- **Skills don't say who posts to Slack.** rca auto-posts, while labrun-rca and ccxp also post, so nothing says which skill owns the Slack output. Composed skills need a "when invoked by X, skip Y" contract.
- **Mechanical logic is still prose.** Several things that are pure parsing or lookup still live in prose instead of `<skill>/scripts/` with BATS tests, against skill-conventions §9: gcpr's changed-file extraction, retro's cron/bump/escalation/sweep steps, labrun-rca's URL parse, rca's Tier-3 row insert, and address-pr's authorship check.
- **Consumer-repo assumptions.** "Tiered merge per dev/guidelines.md" (address-pr:340, retro:300), `main` hardcoded (gcpr, cleanup-branch) and company names (`synx-merge-bot`, `#acme-*`, `#claude-notification`) conflict with the repo's "no company-specific dependency" goal.
