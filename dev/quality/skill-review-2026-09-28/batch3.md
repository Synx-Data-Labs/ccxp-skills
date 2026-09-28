# Batch 3 review — queue/task-lifecycle skills

Cross-cutting findings (apply to several skills below):

- **X1. Queue mutation logic is prose, re-derived 4 times.** Insert/move/append of `- [T{id}](T{id}-{slug}.md): {title}` lines is described in prose in `stage/SKILL.md:44-56`, `top/SKILL.md:78-129`, `bottom/SKILL.md:32-54`, `todo/SKILL.md:158-164`, and is already implemented a 5th time in `migrate-task/scripts/migrate.sh` (`mt-queue-insert`, `mt-target-blocked-by`, `mt-task-title`). `todo/scripts/_lib.sh` already has `todo-parse-queue-line` + `todo-fm-get`. Per skill-conventions §4/§9, add a shared `_queue/queue.sh` with verbs `stage`, `top [--before]`, `bottom`, `sync` (plus the blocker-chain expansion), with BATS tests. None of stage/top/bottom has a `tests/*.bats` today (checked `ls tests/`).
- **X2. Commit/PR boilerplate copied 3 times.** `stage:62-87`, `top:133-146`, `bottom:58-71` each have the same branch→add→commit→push→`gh.sh pr create`→`/address-pr`→"auto-merges under the carve-out in `dev/branch-merge-policy.md`"→post-merge cleanup. That file does not exist in this repo (it is a consumer-repo file, never named as such). Fold into the shared script or a one-line "land as docs PR via X" reference.
- **X3. Changelog asides in skill prose.** Task IDs explaining why a line exists: `todo:59,85,128,139`, `stage:29`, `new-task:89`, `migrate-task:10-12,25-26,59,94-95`, `claim` (none, but see line refs to `drive`), `eta:52-58,65`. These belong in JOURNAL.
- **X4. Estimation-bucket enum disagrees across files.** `todo:58` = `15m..1w`; `new-task:45` and `incept:90` = `15m..1w`; `lifecycle.md:37` = `30m..2w` (no 15m); `eta:50` maps `2w`; `lint_tasks.py:124` accepts any `^\d+(m|h|d|w)`. Define once in lifecycle.md and reference it.
- **X5. Script-invocation paths inconsistent.** README.md:217 convention is `bash ../<name>/scripts/<script>.sh` (relative to skill base dir). `todo/SKILL.md:83,126` say `bash todo/scripts/todo-list.sh` (only works with cwd = ccxp-skills root; scripts default `TODO_QUEUE_DIR=.` so cwd must be the consumer repo — contradictory). `eta/SKILL.md:18` says `scripts/eta.sh` while `:36` says `bash ../eta/scripts/eta.sh`.
- **X6. Company-specific residue** in a repo whose CLAUDE.md promises "no company-specific dependency": `todo:152` `#acme-dev-notifications`; `migrate-task:23,95` `Synx-Data-Labs/<repo>` + a real PR link; `migrate-task:95` `your-org/hub-repo` placeholder mixed with a real org.

---

## todo

- Grades: concision C | trigger B | clarity B | determinism B | correctness C
- Est. cuttable: 40%
- Top recommendations
  1. `todo/SKILL.md:83-113` and `:126-148`: `list`/`next` are fully scripted, yet the SKILL keeps the full algorithm "for a human reading this skill" (`:86-88`, `:132-133`). That is ~55 lines loaded every invocation for zero behavior. Replace each with "Run `bash ../todo/scripts/todo-X.sh`; print verbatim" plus, for `next`, the one judgment step (`:147` "next concrete action"). Move the algorithm into the scripts' header comments (already partially there, `todo-list.sh:1-6`).
  2. `:37-69` "Task metadata" is a schema that belongs in `lifecycle.md` (which already has status flow, blocking, `scheduled` rules at `lifecycle.md:37-129`). guidelines.md:33 even points *to* todo for the schema — invert that. `:60`'s `scheduled` paragraph (GH mirror internals, `.github/scripts/sync-tasks-to-issues.py`, not in this repo) and `:65` retired-`priority` history are pure context cost.
  3. `sweep` Phase 1 + Phase 2 (`:158-179`) are self-described as "mechanical" / "fully automatic" (`:156`, `:168`) — exactly §9's criteria — yet remain prose. Port queue sync, stale-blocker detection, and blocker-order violation detection into `todo/scripts/todo-sweep.sh` (drift/stale detection already exists in `todo-list.sh:45-110`); keep only Phase 3 Step B (Park judgment) and the "Superseded" signal (`:190`, which is judgment, mislabelled as "no judgment call" at `:187`).
  4. `:176-178` is one 150-word paragraph explaining `--before` grouping; replace with the invocation rule ("group violations by blocked task; one `/top <blockers in queue order> --before <blocked>` per group"). `:215-222` Parking Lot section repeats `lifecycle.md:78,87` — cut to the revive recipe.
- Verified stale refs: `.github/scripts/sync-tasks-to-issues.py` (`:60`) and `dev/daily-ccxp.sh` (`:59`) not in repo (consumer-repo files, not labelled as such); `bash todo/scripts/...` path (`:83,:126`) contradicts README.md:217 convention; `#acme-dev-notifications` (`:152`) placeholder channel.
- Eval cases
  - `/todo next` in a fixture repo → transcript contains exactly one Bash call `bash .../todo/scripts/todo-next.sh`, output lists ≤3 IDs in queue order, no Done/Parked/peer-claimed IDs.
  - `/todo sweep` on fixture with one untracked TODO file, one queue line with no file, one `Blocked by` pointing at a JOURNAL task → queue.md gains/loses exactly those lines, blocked task's `status:` no longer contains `Blocked by`, and no `git mv` to `dev/PARKING/` happened without a user-approval turn.
  - `/todo sweep` where blocker B sits after blocked A → final queue.md has B immediately before A, all other lines' relative order unchanged.

## claim

- Grades: concision C | trigger A | clarity B | determinism C | correctness B
- Est. cuttable: 35%
- Top recommendations
  1. `claim/SKILL.md:25-87` Solo-repo mode (63 lines) sits *before* the Workflow and is duplicated nearly verbatim in `drive/SKILL.md:114` ("kept in sync with this one" — a manual-sync liability). `:35-46` is rationale about the statusline. Keep one canonical recipe (here), move rationale to JOURNAL, have drive link to it; move the section after §1 as §1-solo.
  2. Solo-mode detection (`:27-33`) is a fuzzy grep heuristic with "when it's ambiguous, ask" — nondeterministic across runs. Replace with an explicit marker (e.g. a `merge-policy: solo` key or a `_session/mode.sh` check — `tests/mode.bats` suggests one exists) and a script call.
  3. §3 status (`:157-171`) embeds a 9-line bash loop with a warning about grep false positives; the loop is deterministic — add a `task_claim.sh held` (or `list-mine`) verb and call it. Same verb would serve `eta` (which reimplements the lookup, `eta.sh:76-90`).
  4. `:176-193` Important Notes restate the intro (`:8-13`) and Argument (`:17-19`); cut the first and third bullets to one line each. §2 (`:145-153`) says "same shape as §1.3–§1.6" but §1.3 hardcodes branch `t<id>-claim` and commit message "claim T<id>" — specify release's branch/commit/title explicitly.
- Verified stale refs: none found (all `_session/*`, `_taskid/in-this-repo.sh`, `statusline-command.sh` exist; `/drive` Phase 1/7 exist).
- Eval cases
  - `/claim status` in fixture where one TODO body (not frontmatter) mentions `claimed_by: <me>` → reports only the frontmatter-claimed task; `git status` clean, no branch created.
  - `/claim T<b>` while this clone holds T<a> (peer mode) → single commit on branch `t<b>-claim` whose diff clears `claimed_by` on T<a> and sets it on T<b>; PR title `docs(claim): claim T<b>`.
  - `/claim T<x>` where T<x> is claimed by another live id → stops, reports holder, no commit.

## stage

- Grades: concision C | trigger C | clarity B | determinism C | correctness C
- Est. cuttable: 45%
- Top recommendations
  1. Frontmatter `description` (`stage/SKILL.md:3`) is a *what*, not `Use when…` — violates skill-conventions §1 and, as an action skill that opens PRs, risks surprise-firing. Change to "Use when the user explicitly asks to add/stage a task into dev/TODO/queue.md (or /new-task hands off)".
  2. Port placement logic (`:44-56`) to the shared queue script (X1); `migrate.sh` already has `mt-queue-insert` + `mt-target-blocked-by` doing exactly this — reuse it rather than reimplementing (see `migrate-task/SKILL.md:100-102` admitting the duplication).
  3. `:66-72` six-line comment narrating history ("the commit historically only added queue.md") inside the code block; `:89-93` and `:109` restate the scope rule a third time. Keep one bullet.
  4. `:8-16` intro repeats step 2 and "What this skill does NOT do" (`:106-107`). Collapse to 2 lines.
- Verified stale refs: `dev/branch-merge-policy.md` (`:86`) does not exist in this repo.
- Eval cases
  - `/stage T<a>` already at position 3 → prints `already at position 3 of N — no change`, no branch/commit created.
  - `/stage T<new>` where queued T<q> has `status: Blocked by T<new>` → queue.md line for T<new> lands immediately above T<q>; diff touches only queue.md (+ the task file iff it was untracked).
  - `/stage T<parked>` (file in dev/PARKING) → hard-stop, queue.md unchanged.

## top

- Grades: concision D | trigger A | clarity B | determinism D | correctness C
- Est. cuttable: 50%
- Top recommendations
  0. **Algorithm bug in `--before` mode** (`top/SKILL.md:108-129`). Reverse-order processing + "insert immediately above target" reverses argument order; the SKILL rationalizes this as "first-listed wins the position closest to the target" (`:120-129`, yielding `[W,X,B,A,Y,Z]`), opposite to default mode's reading order. Consequences: (a) step 2's blocker expansion `[blocker, original]` ends up `[original, blocker, Y]` — the blocker lands *behind* the task it blocks, contradicting `:74-76` ("blocker first"); (b) `/todo sweep` Phase 2 (`todo/SKILL.md:178`) passes multiple blockers "front-most first, so relative order among them is preserved" — they get inverted. Fix: in `--before` mode process in forward order (or insert each above the previously inserted line). Lock with a BATS fixture.
  1. The reorder algorithm is specified by pseudocode + three worked examples (`top/SKILL.md:70-76`, `:92-106`, `:120-129`) — a textbook §9 candidate; LLM-executed list surgery with a reverse-iteration trick is the kind of thing that silently goes wrong. Implement `queue.sh top [--before T]` (incl. the 10-hop `Blocked by` expansion, `:43-68`) with BATS using those worked examples as fixtures; SKILL shrinks to args + invocation + echo format.
  2. `:43-68` and `:178` both explain "only follow `Blocked by`, never `related:`"; the same rule is in `lifecycle.md:105`. Keep one sentence.
  3. "What this skill does NOT do" / "When NOT to use" (`:175-187`) is ~13 lines mostly repeating `:21-28` and cross-skill P0 policy; cut to 3 bullets. Commit/PR block `:131-146` duplicated with stage/bottom (X2).
- Verified stale refs: `dev/branch-merge-policy.md` (`:144`) missing.
- Eval cases
  - Queue `[X,Y,Z]`, `/top A B` → queue.md order exactly `[A,B,X,Y,Z]`.
  - Queue `[W,X,Y,Z]`, `/top A B --before Y` → pin the intended order (`[W,X,A,B,Y,Z]` if argument order is meant to be preserved) — the current prose algorithm yields `[W,X,B,A,Y,Z]` (see rec 0).
  - `/top T<c>` where T<c> is `Blocked by T<b>`, T<b> `Blocked by T<a>` → queue head is `[T<a>, T<b>, T<c>]`; 11-hop chain → hard-stop, queue.md unchanged.

## bottom

- Grades: concision C | trigger A | clarity B | determinism D | correctness C
- Est. cuttable: 55%
- Top recommendations
  1. ~60% duplicates `/top` (`bottom/SKILL.md:24-30` resolution, `:56-71` commit/PR, `:34-44` reverse-order loop). Once `queue.sh bottom` exists (X1), SKILL = args + one call + echo format (~25 lines). Alternatively merge into `/top` as `/top --bottom` — but separate verb names follow §2, so keep the skill, share the script.
  2. **Missing guard**: `/bottom` has no blocker check — bottoming a task that other queued tasks are `Blocked by` produces exactly the topological violation `/stage` (`stage:12-15`) and `/todo sweep` Phase 2 exist to prevent; the next sweep would silently undo it via `/top --before`. Either refuse/warn when the task appears in any queued task's `Blocked by`, or document that sweep will re-hoist it.
  3. `:86-95` "does NOT"/"When NOT" sections are 3 bullets saying the same thing (not park/close); keep one.
- Verified stale refs: `dev/branch-merge-policy.md` (`:69`) missing.
- Eval cases
  - Queue `[X,Y,Z]`, `/bottom A B` → `[X,Y,Z,B,A]`.
  - `/bottom T<b>` where queued T<c> is `Blocked by T<b>` → skill warns/refuses (per chosen fix); assert queue.md unchanged or warning text present.
  - `/bottom T<missing>` → hard-stop before touching queue.md (`git diff --quiet dev/TODO/queue.md`).

## eta

- Grades: concision C | trigger A | clarity B | determinism A | correctness B
- Est. cuttable: 50%
- Top recommendations
  1. Workflow `eta/SKILL.md:39-75` re-describes what `eta/scripts/eta.sh` does (37 lines, incl. a `date` exit-code implementation detail at `:25-28`). The script is the behavior; SKILL should be: run `bash ../eta/scripts/eta.sh $ARGUMENTS`, print verbatim, meaning of exit 1/2. Move `:52-58` (calendar-vs-workday rationale) and `:62-65` (verification notes) to the script header / JOURNAL.
  2. `:36` invokes the script with **no args** — the `T<id>` / `--tz` from `$ARGUMENTS` are never passed. Change to `bash ../eta/scripts/eta.sh $ARGUMENTS`; drop `--repo-root` from the user-facing arg list (`:29-31`, test-only).
  3. `:65` hard-codes `_session/task_claim.sh:525-546` (actual `_tc_acquire` is at `:530`, and `eta.sh:6` cites `525-539` — already drifted). Remove line-number citations.
  4. `eta.sh` is not function-wrapped/sourceable (top-level arg parsing at `eta.sh:26-33`), violating `dev/guidelines.md` Script Standards; minor but relevant to testability.
- Verified stale refs: line-number ref `task_claim.sh:525-546` (drifted); `scripts/eta.sh` vs `../eta/scripts/eta.sh` path inconsistency (`:18` vs `:36`).
- Eval cases
  - `/eta T<id> --tz Asia/Tokyo` → the Bash call includes both `T<id>` and `--tz Asia/Tokyo`; output timestamp ends in `JST`.
  - `/eta --tz Not/AZone` → exit 2, error message printed, no projected finish line.
  - `/eta` with no claimed task → prints `no current task`, exit 1 (existing `tests/eta.bats` covers script; the eval checks the skill forwards args and doesn't embellish).

## new-task

- Grades: concision B | trigger A | clarity B | determinism B | correctness B
- Est. cuttable: 25%
- Top recommendations
  1. Step 4 lint bundle (`new-task/SKILL.md:88-104`) is a copy of `gcpr` Step 1.5 (`gcpr/SKILL.md:53`) and a subset appears again in `incept:113-116`. Extract to `_docs/lint-task-file.sh <file>` (hard-gate lint_tasks, fix-and-continue the rest) and call it from all three.
  2. `:80-84` five-line forward-compat explanation of the `Type` bullet for `/drive` Phase 2 — move to `design-doc.md` template/JOURNAL; keep "add `- **Type**: <type>` as the first Problem bullet".
  3. `:49-52` optional fields list `blocked-by`, `related`, `owner` — template (`repo-conventions/templates/task.md:7-10`) has them, but the lint-enforced block relationship is `status: Blocked by` (`lifecycle.md:107`); say to set `status: Blocked by T<id>` rather than only a free-text `blocked-by:` or the block will not affect `/stage`/sweep ordering.
  4. `:8-13` intro's "see its own skill for why they're split" aside — cut.
- Verified stale refs: none found (`_taskid/new.sh`, template, all four lint scripts exist; `gcpr` Step 1.5 exists).
- Eval cases
  - `/new-task fix flaky X` with enough context → exactly one new `dev/TODO/T*-*.md`; frontmatter has `status: Open` and an `estimation` in the bucket set; `lint_tasks.py --changed <file>` exits 0; `/stage` invoked (queue.md gains that ID).
  - `/new-task` with no estimation derivable → assistant asks for estimation before writing any file (no file exists after first turn).
  - Assert no separate commit for the task file outside `/stage`'s single commit.

## migrate-task

- Grades: concision C | trigger A | clarity C | determinism B | correctness D
- Est. cuttable: 35%
- Top recommendations
  1. **Skill describes a workflow the script does not implement.** `migrate.sh:210-216` returns 4 for any non-directory target (so the `Synx-Data-Labs/<repo>` slug path, `SKILL.md:22-24`, and "clone both fresh under /tmp" step 2, `:39-41`, are unimplemented); `migrate.sh:300-301` returns 8 for any non-dry-run. The SKILL never gives the actual invocation command, and its implementation note (`:70-76`) is buried mid-step-6. Put a top-level status line: "Only `--dry-run` against a local target dir is scripted; for live runs, perform steps 6–7 by hand" — or finish the live path. Today an agent following steps 1–9 will either call the script and hit exit 4/8, or improvise.
  2. `:10` links `../../dev/TODO/T20260827-201400-migrate-task-skill.md#solution` — file not in `dev/TODO/` (nor found in PARKING/JOURNAL under that ID) → dead link; wrong depth too (`../../` from `migrate-task/`). Remove; the skill must be self-contained.
  3. Add an explicit invocation block: `bash ../migrate-task/scripts/migrate.sh <id> <target-dir> [--dry-run]` and the exit-code table (3 not found, 4 slug unsupported, 5 collision, 6 blocking, 7 claimed, 8 live stub, 9 identifier refusal) — makes behavior predictable and checkable.
  4. Strip history/company residue: `:11-12`, `:25-26`, `:59-60`, `:93-96` (T20260827-420045 narrative, real PR links, `Synx-Data-Labs`).
- Verified stale refs: dead link `../../dev/TODO/T20260827-201400-migrate-task-skill.md`; step 1 says resolution via `_taskid/in-this-repo.sh` (`:20-21`) but `migrate.sh:196-206` uses a plain glob; remote-slug + /tmp clone steps unimplemented (`migrate.sh:214`).
- Eval cases
  - `/migrate-task T<id> /path/to/target --dry-run` on fixtures → Bash call runs `migrate.sh` with those args; output contains `=== would add to` and `=== would update .../queue.md ===`; both repos' `git status` clean afterwards.
  - Task with non-empty `claimed_by` → exit 7 reported, no diff printed.
  - Live run (no `--dry-run`) → skill must not claim success; either reports exit 8 / manual-steps mode explicitly, or produces two PRs in add-then-remove order (assert target PR merged before source PR opened).

## incept

- Grades: concision B | trigger B | clarity B | determinism A | correctness C
- Est. cuttable: 15%
- Top recommendations
  1. **Bug:** `incept/SKILL.md:111` says "Lint the touched file, scoped, never repo-wide", but `:115` runs `bash ../_docs/lint-docs.sh --fix` with **no path** — per `_docs/lint-docs.sh:24-26,40` that lints and `--fix`es the repo's full config-glob set (or dev/JOURNAL+dev/TODO). Append `dev/TODO/T<id>-*.md`. (Better: the shared lint helper from new-task rec 1.)
  2. `:10-13` and `:34-36` both define "design tree"; `:15-19` is provenance (Matt Pocock vendoring) — move to a comment/JOURNAL. Minor.
  3. Description (`:3`) couples the trigger to `/ccxp Phase 2a.3` internals; fine, but "grill" / "stress-test" are also generic words that could fire during ordinary plan discussions — keep "explicitly asks".
  4. Stop condition "frontier empty" (`:84`) has no bound; add a round cap or "after N rounds with no new branches, synthesize" to avoid endless interviews in unattended contexts.
- Verified stale refs: none found (`/ccxp` 2a.3 at `ccxp/SKILL.md:650`, `design-doc.md` Type line exists).
- Eval cases
  - `/incept T<id>` → first assistant message contains ≥1 `❓ Q1` with a `➡️ Recommendation`, and no file edits in that turn.
  - After user confirms synthesis → only `dev/TODO/T<id>-*.md` modified (`git status --porcelain` shows 1 file), `status:`/`claimed_by:`/`scheduled:` unchanged, `## Design` + `### Test Plan` present, nothing committed.
  - `/incept <free text>` → no files modified at end; offers `/new-task`.

## journal-compact

- Grades: concision A | trigger A | clarity C | determinism A | correctness B
- Est. cuttable: 10%
- Top recommendations
  1. Step 3 (`journal-compact/SKILL.md:27-29`) says "commit … and open it as a normal docs PR" but never says to create a branch first; `dev/guidelines.md` Branch policy forbids committing to `main`. Add `git checkout -b docs/journal-compact-<month>` before commit (or move into the script).
  2. No `--dry-run` step though `compact.sh` supports it (`_journal/README.md:9`); add "run with `--dry-run` first and show the list" for a mass `git mv` — cheap safety.
  3. No guard against compacting the current/incomplete month; either document that `compact.sh` refuses it or add the check (didn't find one in `compact.sh:275-290` arg validation).
  4. Step 1 (`:18-20`) is redundant with step 2's inline `git rev-parse`; merge.
- Verified stale refs: none found (`_journal/compact.sh`, `_journal/README.md`, `tests/journal_compact.bats` exist).
- Eval cases
  - `/journal-compact 2026-04` in fixture → Bash call `compact.sh 2026-04 --repo-root ...`; `dev/JOURNAL/2026-04-digest.md` exists; all `2026-04-*` files under `dev/JOURNAL/archive/2026-04/`; commit is on a non-main branch.
  - `/journal-compact 2026/04` → compact.sh exit 2, no git changes.
  - Re-run on already-compacted month → no new commit (idempotent).
