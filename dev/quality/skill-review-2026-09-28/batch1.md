# Skill review — batch 1 (ccxp, drive, autopilot)

Sizes: ccxp/SKILL.md 1011 lines / 90.6 KB (~35k tokens); drive/SKILL.md 654 lines / 65.9 KB; autopilot/SKILL.md 129 lines but 22.2 KB (14 lines are >400 chars — single-paragraph walls). Task-ID asides: ccxp 40 lines, drive 29 lines, autopilot 2.

## ccxp

- Grades: concision D | trigger B | clarity C | determinism C | correctness C
- Est. cuttable: 55–60% (about 1011 → about 420 lines) with no loss of behavior
- Top recommendations
  1. **Move the history and rationale narrative to JOURNAL.** It is the largest cost and adds no behavior. Examples:
     - ccxp/SKILL.md:47-49 (mirrors CCXP_PEER_MODE)
     - :119 (the whole parenthetical about the retired `_claims`/`prune.sh`)
     - :127 (a paragraph on why Design isn't a gap, "verified live: 3 of 4…")
     - :180 ("Why Slack-thread, not a doc append")
     - :184-195 (the addendum incident story)
     - :197 (the rejected weekday-throttle decision)
     - :201 (explains a reused slot number)
     - :203, :220, :224 (why `--limit 100`)
     - :239 ("Until now, whoever's watching…")
     - :274-276 (a *retired* step 1.2.5 kept as prose)
     - :386, :445-452 (the 7-day MCP streak and why there are 2 retries)
     - :484-490 (the scope note on which sends lack the fallback)
     - :576, :593 (T20260526-277041 in-place-edit history)
     - :626, :711, :818 (named incident task IDs)
     - :1007

     Keep only the rule and put a single `(see JOURNAL T…)` pointer where one is really needed. The "Cron mode vs interactive" block (:16-49), the Day-of-week table (:968-980), Cron integration (:982-1003) and Notes (:1005-1011) all restate one fact 4+ times: "cron = rituals only; no 2a.3, no Phase 3". State it once.
  2. **Fix the stale cross-skill contracts with /todo:**
     - :299 (1.2b) and :644 (2a.2) say `/todo next` yields a "top 5" and "skips blocked / peer-claimed / lint-frozen", and that its ranking "factors deadlines, urgency ratio, unblocks-others". In fact `todo/SKILL.md:114-148` and `todo/scripts/todo-next.sh:6` return the **top 3 in `queue.md` order** and explicitly do *not* skip Blocked or lint-frozen tasks. Make 1.2b/2a.2 call `bash <skills-root>/todo/scripts/todo-next.sh`, or add an N argument to that script, and delete the prose restatement.
     - :601-614 (2a.0.1) cites "/todo sweep Phase 1: Fix stale blockers", but that is Phase 2 (todo/SKILL.md:166). It then ships a **non-functional placeholder loop** (`:  # placeholder`, :610). Replace it with a single line: "run `/todo sweep` Phases 1–2 + Phase 3 Step A".
     - :616 says Park moves happen "only after the maintainer approves". That leaves no stop condition in cron mode, because no one is there to approve. Say explicitly: "cron: list Park candidates in Housekeeping, do not move".
  3. **Remove the contradictions about /drive and the phase numbers:**
     - :895 and :920 say "`/drive` runs in continuous mode (complete task → pick next → repeat)". drive/SKILL.md:10, :538 and :646 say it exits after one goal-task, with "No next-task auto-pick". Rewrite the Phase 3 supervisor table (:933-943) around single-goal exits.
     - :154 says "Phase 0 (`/address-pr`) already exited". ccxp Phase 0 is sync and never calls `/address-pr`; that is `/drive` Phase 0.
     - :148/:197/:1003 say "Phase 1.0 short-circuit", but the section is 1.1a (:146).
     - :918 says "Phase 1/1.5/0.5", but 1.5 no longer exists (:203).
     - Phase 0.5 items are numbered 1, 3, 4 (:103, :111, :121); there is no item 2.
     - :209 "Normal day" is a one-bullet list left dangling after the other case was removed.
     - :383 Housekeeping template says "No claim housekeeping needed (one session per clone)", which contradicts peer-mode-default (:301-309).
     - The frontmatter has `argument-hint: "[task-id]"` (:5), but the Argument section (:12-14) defines no task-id behavior.
  4. **Port the mechanical steps into tested scripts (§9):**
     - 1.1 data gather (:137-144)
     - 1.1a hold-gate evaluation (:150-156)
     - day-of-week trigger (:574, :893)
     - 2a.0 SCHEDULED/NEXT_MON date math (:587, :716)
     - bump-2x detection: a join over the Tier-1 tables of the last 2 IPM files (:628)
     - 2a.1.5 parse of the "Considered but cut" table (:638)
     - 2a.5 `scheduled:` rewrites. `_ipm/stamp-scheduled.sh` already exists (it is used by /drive), but ccxp hand-edits frontmatter. Note that the stamper is update-forward-only, while :709 says "Always overwrite", so reconcile the two.
     - the standup markdown/Slack renderers (:315-384, :516-548)

     Also:
     - `ccxp/scripts/prune-drive-threads.sh` and `sync-and-prune-branches.sh` have **no BATS tests** (no file in tests/ references either).
     - Phase 0 (:92) should pass `--skills-dir "<skills-root>"`. The script defaults to `~/.claude/skills`, the footgun already filed as dev/TODO/T20260925-159860, even though the preamble at :68-85 already derives `<skills-root>`.
     - :97 says "report and continue" on a dirty tree or diverged pull, but the script exits non-zero (sync-and-prune-branches.sh:14-16 plus `set -e`). Define what the skill does on a non-zero exit.
- Verified stale refs:
  - `/cleanup-branches` (:95): the directory is `cleanup-branch/`
  - "/todo sweep Phase 1: Fix stale blockers" (:607, :614): it is Phase 2
  - "/todo next top 5 / skips blocked+lint-frozen / urgency-ratio ranking" (:299, :644)
  - "Phase 0 (`/address-pr`)" (:154)
  - "Phase 1.0" (:148, :197, :1003)
  - "Phase 1.5" as a current phase (:918)
  - `/drive` "continuous mode" (:895, :920)
  - "one session per clone" housekeeping (:383)
  - `dev/daily-ccxp.sh` (:18, :197 `:497`, :984): not in this repo. It is a consumer-repo file with no template or README pointer, and :197 cites a line number in a file the skill can't see.
  - `dev/guidelines.md carve-out` (:873): there is no auto-merge carve-out in this repo's dev/guidelines.md
  - `build-pipeline` (7 places, e.g. :862-875) and `#acme-*` channels (14 places): company-specific names hardcoded, against the repo's "no company-specific dependency" goal. /drive already uses `DRIVE_ESCALATION_CHANNEL_ID`.
  - `your-org/projects/1` (:593) and `America/Chicago` (:574) are hardcoded
  - `/simplify` (:58) is a harness skill, not in the repo. That is fine, but it is uncited.
- Eval cases:
  - `CCXP_CRON_MODE=1 /ccxp` on a Wednesday fixture repo → the transcript contains **no** `/drive`, `/incept` or Agent-dispatch invocation, and ends with "Rituals done for today — no focused-work loop in cron mode."
  - Monday IPM fixture with a pre-IPM stub `dev/JOURNAL/<Mon>-ipm-weekly.md` containing `**Status**: Pre-IPM staging` → after the run, that same file (not a new one) has no `Pre-IPM staging` line, and every Tier-1/2 task file has `scheduled: <Mon>`. Also, `_ipm/ipm-iteration-drain-check.sh` was run, and when it exits 1 no IPM commit/PR is created.
  - Standup on a quiet day (0 merges, 0 failures, 0 flagged PRs) → the Slack message contains all four headers `✅ Resolved`, `🌙 Nightly`, `🔀 Needs your attention` and `🚧 Blockers`, with their "None"/"Nothing"/"all green" fallbacks. It has no bare `T\d{8}-\d{6}` outside a `<url|T…>` link, and is ≤5000 chars.

## drive

- Grades: concision C | trigger B | clarity C | determinism B | correctness D
- Est. cuttable: 40% (about 654 → about 390 lines)
- Top recommendations
  1. **Fix the cross-repo mechanics. They are broken as written:**
     - drive/SKILL.md:147-151 runs `trap 'rm -rf "$TARGET"' EXIT` inside a Bash tool call. Each call is a fresh shell, so the trap fires when *that* call ends and deletes the clone immediately. `$TARGET`/`$HUB` also don't persist between calls. Replace this with a script, e.g. `drive/scripts/xrepo-clone.sh`, that prints the path, with explicit `rm -rf` at Phase 7 (:562) and an orphan sweep.
     - The clone path conflicts: `/tmp/T<id>-<slug>-target` (:147) vs "always clone fresh under `/tmp/cc-<repo>-<purpose>-$(date +%s)`" (:324).
     - :178 says a "weekly sweep (ccxp Phase 0 addition)" prunes `/tmp/T*-target/`, but ccxp has no such step.
  2. **Fix the frontmatter-key and lint claims that are false:**
     - :123/:126/:168 tell the model to read `Target repo` / `Target path`, but the lint-enforced keys are `target-repo`/`target-path` (lifecycle.md:51, lint_tasks.py:22). skill-conventions §7 already has to warn readers off this prose.
     - :131 claims the key "is **not** on the `lint_tasks.py` allowlist". It is (lint_tasks.py:22), so the whole "Undeclared cross-repo" rationale is stale.
     - :107 says "`/todo next` already excludes frozen candidates (step 4)". todo/SKILL.md:134 says it explicitly does not.
     - :54 says auto-pick "build[s a] dependency graph, score[s] by readiness + priority + unblocks". `/todo next` is plain queue order, top 3.
     - :170 says the "convention is one session per clone (see T20260513-422869)", which contradicts peer-mode-default (:103).
     - `dev/branch-merge-policy.md` (:97, :333) does not exist.
  3. **Collapse the status-mutation sprawl into one ordered sequence.** Today the status is flipped in Phase 1 auto-pick step 4 (:56, Open→Design in place), the explicit-id step 3 (:63), the status mirror (:85), the claim PR (:97, Open→In Progress *or* Design), `task_claim.sh acquire` (:108, which forces In Progress), Phase 2 step 3 (:188, Open→Design again) and Phase 2 step 6 (:191). A reader can't tell which value `main` should hold when. Write one table: event → command → resulting status. The claim flow also appears three times (:90-112 generic, :103-112 peer, :114 solo), and the close flow twice (Phase 4 :401 and Phase 7 :525-562, including a duplicate `claimed_by` verification at :529). Keep the peer path as *the* path and move the history out (:180, :401 T20260914-422854 narrative repeated at :511, :528, :544; :456-457 the named blocker chain).
  4. **Unattended safety and stop conditions:**
     - Phase 1 step 1 (:53) runs `/todo sweep` on *every* auto-pick. Sweep Phase 3 Step B always waits for user approval (todo/SKILL.md, sweep Step B.3). Under `/autopilot`'s dispatched sub-agent or cron, that is an unbounded hang. Specify: "unattended → skip Step B / report candidates only".
     - Phase 5 (:426) and the Important Notes (:636) say "idle until signal", but give no exit when address-pr lands in the wait-for-approval tier. /autopilot has to invent a `WAITING` outcome to cover this.
     - The embedded 40-line Workflow JS template (:265-307) is reusable boilerplate. Move it to `drive/references/impl-workflow.js`.
     - Mixed path convention: /drive uses cwd-relative `../_session/…` (about 25 places), while /ccxp mandates the absolute `<skills-root>` and says "never run these cwd-relative" (ccxp:68-81). From a consumer repo's cwd, `../_session/task_claim.sh` does not resolve.
- Verified stale refs:
  - `dev/branch-merge-policy.md` (:97, :333): missing
  - `Target repo`/`Target path` casing (:123-168)
  - "not on lint_tasks.py allowlist" (:131): false
  - "`/todo next` excludes frozen (step 4)" (:107): false
  - "dependency graph / score" (:54)
  - "one session per clone" (:170)
  - "ccxp Phase 0 … prunes /tmp/T*-target/" (:178): nonexistent
  - `dev/guidelines.md` auto-merge carve-out (:559): not present in this repo's guidelines
  - All other scripts verified present: `_taskid/in-this-repo.sh`, `_session/lint_frozen.sh`, `design-score/scripts/score.sh`, `quality-probe/scripts/probe.sh`, `_docs/doc-impact.sh`, `_ipm/stamp-scheduled.sh`, `repo-conventions/templates/{design-doc,task}.md`, `claim/SKILL.md` "Solo-repo mode"
- Eval cases:
  - `/drive T<id>` where the fixture task has `claimed_by: cc1-other:xyz` and `task_claim.sh reclaimable` → `not` → no `t<id>-claim` branch is created, `task_claim.sh acquire` is never called, and the output reports the peer claim.
  - Cross-repo task (`target-repo: org/x`) where `gh pr list --repo org/x --search <id>` stub returns an OPEN PR → no `git clone` of a new branch and no `gh pr create` in the target; `/address-pr <that PR>` is invoked instead.
  - Close path → the resulting commit has `git show --stat HEAD` ≠ `100% rename`/0 insertions. The JOURNAL file contains `## Closed (` and `## Skills invoked`, frontmatter `claimed_by` is empty, and the close used `task_claim.sh release <id> Done` (no hand-edit of `status:`).

## autopilot

- Grades: concision C | trigger A | clarity B | determinism C | correctness B
- Est. cuttable: 45% (22 KB → about 12 KB; the line count barely changes, but the paragraphs shrink a lot)
- Top recommendations
  1. **Trim the justification prose.**
     - autopilot/SKILL.md:55 is a ~2,400-char single paragraph. The rule is "Agent tool, general-purpose, no `isolation` — a worktree changes the claimant id (`_session/claimant-id.sh` hashes the toplevel)". The rest (the `--dispatch-blockers` comparison, "unchanged by this PR either way", the /compact discussion) is rationale for the JOURNAL. Note that "this PR" is changelog language inside a skill.
     - :116 restates :8 and :55 on context bounding.
     - :117 restates :81's notification facts.
     - The Stuck definition is written three times (:57, :64, :81), and the WAITING definition twice (:69-70 and :79). Define each once, then reference it.
  2. **Fix the WAITING → 60 s hot loop.** `WAITING` (wait-for-approval) counts as Progress and reschedules in 60 s (:79). But the next cycle's `/drive` Phase 0 `/address-pr` auto-pick selects the oldest `mine` PR (address-pr/scripts/auto-pick.sh). That is the same unapproved PR, so the loop can spawn a full sub-agent every minute for hours without advancing. Either treat a repeated identical WAITING as Stuck (backoff), or pass `/drive T…`/skip-PR hints. Also: `QUEUE-EMPTY` and `WAITING` are outputs /drive never defines (drive's only exit report is at drive/SKILL.md:646-652). The sub-agent has to infer them, so write the contract into /drive's exit condition.
  3. **Script the mechanical bookkeeping (§9).** Add something like `autopilot/scripts/state.sh` with verbs:
     - `init <duration>`: parse `6h`/`90m`/"for the next 6 hours" → an ISO end_time. At :12 this is "free text, read directly rather than parsed by a script", so it is LLM date math.
     - `parse-resume "<prompt>"`: the strict `until <ISO> stuck=<n>` regex (:46).
     - `backoff <stuck_count>`: `min(300·2^(n−1),1800)` plus the `now+delay>=end_time` check (:81).
     - `classify <report>`: the MERGED/STUCK/QUEUE-EMPTY/WAITING parse (:60-73).
     - `update`: the JSON field writes repeated in :47/:79/:80/:81/:102.
     - `status`: the Phase 0 elapsed/header rules (:40).

     Add these with BATS tests. The skill has no scripts/ and no tests today.
  4. **Hard-coded line-number cross-refs and the wrong tool attribution.**
     - `drive/SKILL.md:426,636` (:70, :79) are currently correct but will rot on any /drive edit. Cite the "Phase 5" / "Wait, don't switch" anchors instead (skill-conventions §6 says phase numbers are the stable anchors).
     - :128 attributes `ScheduleWakeup` to "`superpowers`". It is a harness tool.
     - `#acme-dev-notifications` is hardcoded (:103, :127).
- Verified stale refs: none broken. `dev/.autopilot-state.json` is in `.gitignore:3`, and address-pr §2.b/§2.e/§2.f/§3 anchors all exist. The line-number refs (drive:426, :636) are brittle, and the "superpowers ScheduleWakeup" attribution (:128) is wrong.
- Eval cases:
  - `/autopilot status` with no `dev/.autopilot-state.json` → output is exactly "autopilot has never run in this repo". No ScheduleWakeup, Agent or Slack call.
  - Resume prompt `/autopilot until <T> stuck=2`, where the stub sub-agent returns `STUCK: ci red — last task T1 (x)` and `now+1200s < T` → exactly one `ScheduleWakeup` with `delaySeconds: 1200`, `noop: true`, `prompt: "/autopilot until <T> stuck=3"` (end_time unchanged), and the state file has `stuck_count: 3`, `last_outcome: "stuck"`.
  - `/autopilot until 5pm` → treated as a first invocation (a fresh state file with `status: running`, `stuck_count: 0`), not as a resume. With end_time already past on a resume, no Agent dispatch happens and the Phase 5 report starts with `Autopilot run:` and `stopped: elapsed`.

## Cross-cutting patterns

- **Changelog in the skill body.** 71 task-ID asides across the three skills, plus "Previously…/Retired…/Moved here…/Until now…" paragraphs (ccxp:201, :274-276, :386; drive:180, :564). The JOURNAL is the index. These sections alone account for about half the ccxp cut.
- **Prose re-derivations of other skills drift.** Both ccxp and drive restate `/todo next` semantics and both are wrong (top-5/scoring vs the actual top-3 queue order). Both also restate `/todo sweep` without its interactive Park gate, which risks an unattended hang. Rule: call the script or cite the anchor, never paraphrase.
- **Inconsistent skills-root path convention.** ccxp uses the absolute `<skills-root>`; drive (and address-pr) use cwd-relative `../_x/`, which ccxp itself forbids.
- **Company residue.** Hardcoded `#acme-*`, `build-pipeline`, `America/Chicago` and `your-org/projects/1` remain in ccxp/autopilot, while drive already moved to an env var (`DRIVE_ESCALATION_CHANNEL_ID`).
