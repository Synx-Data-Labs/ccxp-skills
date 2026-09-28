# Batch 4 skill review

Line numbers are file-local to each `<skill>/SKILL.md` unless another file is named.

Environment check: `superpowers:writing-skills` is not installed here. `~/.claude/plugins` holds only `synced`, `~/.claude/skills` holds only `session-start-hook`, and `find / -name writing-skills` finds nothing.

---

## repo-conventions

- Grades: concision C | trigger B | clarity B | determinism A | correctness B
- Est. cuttable: 40%
- Top recommendations:
  1. Remove the design rationale and history from the lint sections (lines 60-103). Lines 69-75 argue at length for leaving bare `#N` out of scope (T20260616-130977, "a future task could revisit"). Lines 97-103 explain false positives from other scans and mention "the two real leak incidents". Cut each lint to about 3 bullets saying what it checks, how to configure it and how to fix a hit. Move the reasoning to the JOURNAL entries it came from.
  2. The `check` bullet list (lines 119-128) repeats the Canonical Rules (lines 21-58) a second time. `lint.sh` already prints a ✅/❌ line for each check. Replace lines 119-128 with "run lint.sh; relay its output; exit code is the verdict".
  3. Line 8 says "how Your Company repos…". This is placeholder text left from the split out of the private repo. Replace it with "repos that adopt this suite". Line 36 has the same problem: its Information-Mapping essay repeats the wording of `templates/guidelines.md` and `dev/guidelines.md:73`. Keep only the requirement and the pointer to the template.
  4. `sync` (lines 134-141) is still interactive prose. A `sync.sh --dry-run` that lists missing or empty files and prints diffs would make it predictable. Lines 105-107 ("Authoring a skill") and 172-180 ("Pointing a repo at this skill") are off-topic for a lint/sync skill and can go down to one line each.
- Verified stale refs: T20260616-130977 (line 73) is not in this repo's `dev/`. Line 8 "Your Company" is a leftover placeholder. Everything else resolves: `lint.sh` has all 8 checks (`lint.sh:55-127`), `mode.sh` flags match line 155, `_taskid/url.sh` defines `taskid-mdlink`, `KNOWN_SIBLING_REPOS` exists in `lint_refs.py:81`, and the allowlist matches `lint_tasks.py:18-25`. One small drift: `lint_tasks.py` also allows `claimed_role`, which line 56 does not list.
- Eval cases:
  - Run "check this repo against conventions" in a fixture repo whose CLAUDE.md is 60 lines → the skill runs `lint.sh`, reports the ❌ line-cap failure, and edits no file.
  - Run "`/repo-conventions sync`" in a fixture with a non-empty, hand-edited `dev/guidelines.md` → a diff is shown and a question is asked before any write; the file's mtime is unchanged if the user declines.
  - Run "`/repo-conventions mode team`" with no `.github/workflows/` → `mode.sh` refuses, and no `gh api` PUT to branch protection is issued.

## skill-conventions

- Grades: concision C | trigger B | clarity C | determinism C | correctness C
- Est. cuttable: 35%
- Top recommendations:
  1. **The skill cannot stand on its own as a rubric.** Lines 10, 20, 48, 66 and 80 hand every generic question to `superpowers:writing-skills`, which is not installed. Without it the skill says nothing about description length, keeping the body lean, when to split work into `references/`, or how to test. `retro/SKILL.md:380` only grades "if a rubric exists", and it never does. Add an inline "Minimum rubric" of about 10 lines covering: description rules and a length cap, a body size budget (for example, 150 lines or fewer), no task-ID or changelog narrative in the skill body, no content duplicated from other skills or `lifecycle.md`, script paths resolved from the skill's base directory, explicit stop conditions, and 2-3 eval prompts per skill. Treat superpowers as optional extra depth.
  2. §5 (lines 43-48) says "Prose-only skills need no tests — the prose IS the deliverable". This works against the owner's goal of skills that can be improved over time. Require at least one `evals` fixture per skill (a prompt plus an assertion), even when it is only run by hand.
  3. §7 (line 59) is a single 100-word sentence about cross-repo dispatch and frontmatter key spelling. That belongs in `lifecycle.md` or `/drive`, not in authoring conventions. Cut it to one pointer line. Line 76 (a worked example with a T-id) is useful but could shrink to half its length.
  4. Fix the internal inconsistencies. Line 80 says "§1–7 guardrails" but there are 9 sections. Line 14 offers `show` as its only verb, which is a meaningless argument. §4 (line 41) lists only `_gh/`, `_taskid/` and `_session/`, but `_ipm/`, `_journal/` and `_docs/` also exist at the repo root. Add a new rule: bundled script invocations should use one convention (see the cross-cutting note in the summary).
- Verified stale refs: `superpowers:writing-skills` is not installed (lines 10, 66, 80). The §4 lib list is incomplete. `/retro` Phase 4c exists (`retro/SKILL.md:373`). The JOURNAL link on line 76 resolves.
- Eval cases:
  - Ask "Write a new skill `/foo` that sends a digest" with no superpowers installed → the SKILL.md produced has a `Use when the user explicitly asks…` description, an `argument-hint`, and `disable-model-invocation: false`, and it contains no T-id narrative.
  - Ask "Should this helper live in the skill or in a shared lib?" with 2 consumers → the answer cites §4 and proposes a `_<prefix>/` directory with a README.
  - Ask "Port this deterministic step to a script" → the plan includes a BATS parity test *before* the SKILL.md prose is replaced (§9).

## spinup

- Grades: concision C | trigger A | clarity B | determinism C | correctness C
- Est. cuttable: 45%
- Top recommendations:
  1. **The workflow rests on a false claim.** Line 32 says `/spinup` "inherits … `/1password-env-setup`'s own confirm-before-overwrite behavior". In fact, 1password-env-setup replaces any `.envrc` that is not byte-identical, and never asks (see `1password-env-setup/SKILL.md:74-79` and `pes-write-envrc` at `1password-env-setup.sh:45-56`). Either add a confirm or backup step before dispatch in step 4, or fix 1password-env-setup and then drop the sentence.
  2. Steps 3-4 (lines 22-26) are full of defensive wording such as "don't treat all-clean as a loop condition", "can't recur here" and "not an unfinished loop". Each step can be one line: "3. `check`; if the CLAUDE.md/guidelines files are empty or missing → `sync`, then re-`check` once; report all other findings verbatim. 4. If `.env.tpl` exists → `/1password-env-setup`." Line 26's precedent argument about `/drive` can go.
  3. Line 21 is `/init`'s stop condition. Step 1 checks only for a git repo, and `lint.sh` takes a path argument (`lint.sh:12`). Say explicitly to run `bash <base>/../repo-conventions/scripts/lint.sh <path>`. As written, "`/repo-conventions check` against `<path>`" never says how the path reaches the check.
  4. Lines 29-33 (Important Notes) repeat steps 3-5. Lines 35-40 (Cross-references) repeat lines 10-12. Remove both.
- Verified stale refs: `superpowers:writing-skills` is not installed (lines 12, 27, 40). The overwrite-safety claim on line 32 is false (see rec 1).
- Eval cases:
  - Run "spin up this repo" on a git repo with no CLAUDE.md → the skill stops after telling the user to run `/init`; no files are created.
  - Run "`/spinup`" on a repo with a clean layout plus `.env.tpl` and a hand-edited `.envrc` → the user is asked before `.envrc` is replaced, or the original is backed up. This currently fails, which is the bug in rec 1.
  - Run "`/spinup`" on a repo with an unlinked `T<id>` in `dev/TODO/` → the summary lists the file and `lint_refs.py --fix`, and `sync` is not re-run.

## design-score

- Grades: concision C | trigger B | clarity B | determinism A | correctness B
- Est. cuttable: 50%
- Top recommendations:
  1. The check table and normalisation essay (lines 46-75) repeat what `score.sh` implements and what `--json`/the default output already shows. The agent only needs: run it, read the breakdown, fix the gaps, re-run. Keep a one-line summary of each check (name and max). Drop the history on lines 67-70 ("the `TLDR` addition above used to require exactly that kind of trim") and the T-id on line 13.
  2. Lines 82-84 tell the reader to "Mirror the `/drive` Phase 3.0 docs/code classifier". That instruction is aimed at a script author, not at Claude running the skill, and it creates a drift risk: two classifiers that must stay in sync. Either share the classifier as a lib function that `/drive` calls, or state which one is canonical.
  3. The description (line 3) has the right scope, but it is framed only around `/drive`. Add "or when the user asks to score a design doc" so ad-hoc use triggers.
  4. Lines 86-98 (Rubric intent and Testing) are for maintainers. Move them to a comment in `tests/design_score.bats` or to the script header.
- Verified stale refs: T20260609-204303 (line 13) is not in this repo. `tests/design_score.bats`, `tests/fixtures/design-score/` and `repo-conventions/templates/design-doc.md` all exist. `/drive` Phase 2→3 gate exists (`drive/SKILL.md:192-198`). The script path `../design-score/scripts/score.sh` is relative to an unspecified cwd.
- Eval cases:
  - Run "Score dev/TODO/<fixture-good>.md" → the skill runs `score.sh` and reports PASS ≥85, with exit 0.
  - Run "Score this design" on a fixture with `TBD` in the body and no TLDR → the reported score is below 70 and names both the TLDR (C2) gap and the placeholder penalty.
  - Run "Score it as docs" on a code-heavy fixture → `--kind docs` is passed, and the JSON has `"kind":"docs"`.

## quality-probe

- Grades: concision C | trigger B | clarity B | determinism A | correctness B
- Est. cuttable: 45%
- Top recommendations:
  1. The Argument (lines 22-44), Testing (lines 111-124) and script-structure paragraph (lines 58-61) describe the script's interface and its tests to maintainers. Replace them with one invocation line, `--help`, and "exit 0 always; WARNING lines = regressions". The BATS coverage list belongs in the test file.
  2. The long shellcheck note in the probes table (line 72) and the "consumes signal the repo already generates but never reads (T20260609-204303 #257)" remark (line 77) are rationale. Cut the table to Field → Tool → skip behaviour.
  3. The "ccxp hooks" section (lines 102-109) describes `/drive` 3.8 and `/retro` 4d, which live in those skills. That is duplicated content that will drift. Replace it with a one-line pointer.
  4. The description (line 3) is good. Add "or when the user asks to measure touched-file quality" so it can be invoked by hand.
- Verified stale refs: T20260609-204303 is not in this repo (lines 13, 77). `engineering-standards.md` "Quality metrics" exists (line 44 of that file). `_gh/gh.sh`, `tests/quality_probe.bats` and the fixtures all exist. `/drive` Phase 3.8 exists (`drive/SKILL.md:378`), as does `/retro` Phase 4d (`retro/SKILL.md:399`).
- Eval cases:
  - Run "Run the quality probe for T20260610-123456 on scripts/foo.sh" in a temp repo → `dev/quality/metrics.jsonl` gains exactly one valid JSON line with `"task":"T20260610-123456"`.
  - Run the probe with shellcheck removed from PATH → the record has `"shellcheck":null`, stderr contains `skip: shellcheck`, and the exit is 0.
  - Run the probe on a seeded baseline with fewer warnings → the output contains `WARNING: shellcheck_warning regressed` and the exit is 0.

## memory-to-skill

- Grades: concision B | trigger A | clarity C | determinism B | correctness C
- Est. cuttable: 30%
- Top recommendations:
  1. **Tasks filed by step 5 would fail the repo's own lint.** Line 110 tags tasks `Category: process` and `Source: memory-to-skill …`. `category` is not in `lint_tasks.py:18-25`'s allowlist, and the allowed key is lowercase `source`. Change it to `source: memory-to-skill YYYY-MM-DD` and drop Category. Step 5 (`_taskid/new.sh` plus the template) also contradicts Cross-references line 136, which says `/new-task` files the consolidation tasks. Pick one path; `/new-task` is better, since it scaffolds valid frontmatter.
  2. Line 94 puts `/new-task "…"` inside a ```bash block, but it is a slash command, not shell. Write it as prose: "invoke the `/new-task` skill with …".
  3. The `dry-run` rule is stated 4 times (lines 53-56, 62-63, 90-91, 106-108) and again at 125-126. State it once, as a gate that applies to every mutating step. Also delete line 15-17's history and line 130-135's "may in future call this skill… follow-up" remark.
  4. `find-memory-dir.sh` encodes only `/`→`-` (`find-memory-dir.sh:68`). Claude Code also turns other non-alphanumeric characters (such as `.` and `_`) into `-`, so a clone path like `/Users/a.b/x` will likely resolve to "no memory". The script also ignores `$CLAUDE_CONFIG_DIR`. Verify against the harness encoding and add BATS cases. Separately, line 37 invokes `bash memory-to-skill/scripts/…`, which only works when the cwd is the skills repo, but the skill runs in consumer clones.
- Verified stale refs: `DEPENDENCIES.md` (lines 10, 74, 138) does not exist in this repo. That is acceptable as a consumer-repo target, but say "if present". The `category` key is not allowed by the lint. `gotchas.md`, `_taskid/new.sh --check`, `/retro` Phase 1b and `tests/memory_to_skill.bats` all exist.
- Eval cases:
  - Run "`/memory-to-skill dry-run`" with a fixture memory dir holding 1 stale and 1 codifiable memory → the memory dir and `dev/TODO/` are byte-identical before and after, and the report has "would remove" and "would consolidate" lines.
  - Run "review my memories" in a clone with no memory dir → the output is "no memory to review" and nothing else runs.
  - Run the skill (non-dry) where a new-skill candidate exists → any new `dev/TODO/*.md` passes `lint_tasks.py --all`. This currently fails because of `Category:`.

## 1password-env-setup

- Grades: concision C | trigger A | clarity C | determinism A | correctness C
- Est. cuttable: 40%
- Top recommendations:
  1. **Contradiction about overwriting.** Line 74 opens with "Never overwrites a hand-edited `.envrc` silently", but lines 75-77 say any non-identical `.envrc` "is replaced". The script (`pes-write-envrc`, `1password-env-setup.sh:45-56`) replaces it without asking. Either back up to `.envrc.bak` and print a diff (preferred; add a BATS test), or reword the note honestly. `/spinup:32` depends on this.
  2. **The staleness rationale is wrong** (lines 67-70). Rotating a secret in 1Password changes the vault value, not `.env.tpl`. So `.env -nt .env.tpl` stays true and the stale secret is never refreshed. Document the limitation ("rotation requires `rm .env` or re-running with `--force`") and consider adding `--force`.
  3. Lines 17-22 and 90-99 say twice that vault layout, CI sync and rotation are out of scope. Say it once. Line 44's T-id and lines 80-85 (helper function names, "see statusline-setup for the same pattern") are maintainer notes; move them to the script header.
  4. Workflow steps 1-5 (lines 31-48) restate what the script does. Put the invocation first and keep one line per step. Fix the script path (line 53, `bash 1password-env-setup/scripts/…`), which assumes the cwd is the skills repo.
- Verified stale refs: the script error message cites "hub-repo T20260510-161133" (`1password-env-setup.sh:36`), which is not in this repo. That is a private-repo leftover in user-facing output. T20260918-214522 resolves in JOURNAL. `tests/1password_env_setup.bats` exists.
- Eval cases:
  - Run "set up 1Password env" on a dir without `.env.tpl` → the skill exits non-zero with guidance, and no `.envrc` is created.
  - Run it on a dir with `.env.tpl` and a custom `.envrc` → the original content survives (as a backup, or the user is asked). This currently fails.
  - Run it with `op` stubbed to exit 1 → the output reports failure, not "materialized", and `direnv allow` is not run.

## statusline-setup

- Grades: concision C | trigger A | clarity B | determinism C | correctness B
- Est. cuttable: 45%
- Top recommendations:
  1. Remove the history: lines 16-20 (the script "previously lived loose…" and was "formerly named `set-statusline`"). Lines 111-117 (a 7-line note on the built-in `statusline-setup` agent name collision) can become one sentence, or go entirely.
  2. The Deploy steps (lines 38-81) are prose that makes Claude grep aliases and hand-check JSON paths in every config directory. A `scripts/check-deploy.sh` would make this deterministic: it would enumerate `~/.claude*` and `$CLAUDE_CONFIG_DIR` dirs, read `statusLine.command`, compare the path with the newest `plugins/cache/ccxp-skills/ccxp-skills/<ver>/`, and print "ok" or "repoint to X". BATS could test it against fixture dirs.
  3. Step 1 (line 38) tells Claude to run `/plugin update ccxp-skills`, which is a built-in command a skill cannot invoke (spinup line 21 says exactly that). Tell the user to run it.
  4. Lines 108-110 explain the purpose of the frontmatter, and lines 98-101 name the helper functions for tests. Both are maintainer notes; remove them.
- Verified stale refs: none are broken. `sl-repo-root`, `sl-clone-id`, `sl-claimed-task-label` and `sl-join` exist, and `sl-branch-name` exists but is not listed. `tests/statusline_setup.bats` and `_session/task_claim.sh` exist, and the plugin name `ccxp-skills` matches `.claude-plugin/plugin.json`. Paths are hardcoded to macOS `/Users/YOUR_USERNAME` (lines 67, 74).
- Eval cases:
  - Run "`/statusline-setup test`" → the skill runs `bats tests/statusline_setup.bats` and reports pass/fail counts, with no edits.
  - Run "redeploy the statusline" with a fixture `~/.claude-personal/settings.json` pointing at an old version dir → the report names both config dirs and says the personal one needs repointing, with the exact new path.
  - Pipe `{}` into `statusline-command.sh` → the exit is 0 and the output is a single line (it never hangs or errors).

## slack

- Grades: concision C | trigger C | clarity C | determinism C | correctness D
- Est. cuttable: 40%
- Top recommendations:
  1. **A named channel can silently post to the default channel.** Line 64 runs `SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_FOO" bash slack-send.sh`. If `SLACK_WEBHOOK_URL_FOO` lives only in `~/.claude/.env` (the location lines 39-42 recommend), it expands to empty in Claude's shell. `slack-send.sh:20-27` then sees an empty `SLACK_WEBHOOK_URL`, sources `~/.claude/.env`, and posts to the **default** channel. Line 67 ("the script loads ~/.claude/.env itself") makes this worse. Fix: move `--channel` parsing and the `_<NAME>` lookup into `slack-send.sh`, fail loudly if the named var is unset, add a BATS case, and reduce the Workflow to one command.
  2. **The trigger contradicts itself.** The description (line 3) says "explicitly asks", but "When to notify proactively" (lines 71-73) tells Claude to send "not only when explicitly asked". The description also says "the configured channel", but any channel works. Pick one behaviour. Given §1 of skill-conventions, remove lines 71-73.
  3. Line 24's `dev` row is a 60-word cross-skill policy note (ccxp 1.4, autopilot Phase 5, T20260717-433409). Those policies belong to those skills. Cut it to "`dev` — webhook fallback channel".
  4. Channel mapping is explained 3 times (lines 12-16, 30-31, 55-56), and the env-file block (lines 45-49) repeats the table. Keep one explanation. Line 8 also lacks a `# Slack` H1 or structure per §6.
- Verified stale refs: T20260717-433409 is not in this repo. `slack-send.sh` has no `--channel` support (checked the usage at `slack-send.sh:29-40`). `ccxp` §1.4 (`ccxp/SKILL.md:441`) and `autopilot` Phase 5 (`autopilot/SKILL.md:83,103`) exist.
- Eval cases:
  - Run "`/slack --channel foo hi`" with `SLACK_WEBHOOK_URL_FOO` only in `~/.claude/.env` (stub curl) → the POST goes to the FOO URL, not the default. This currently fails.
  - Run "`/slack --channel bar hi`" with no `SLACK_WEBHOOK_URL_BAR` anywhere → the command errors naming the missing var, and no POST is made.
  - Finish a long CI wait without mentioning Slack → no `/slack` call is made (tests the explicit-only trigger).

## slack-check-reply

- Grades: concision C | trigger B | clarity C | determinism C | correctness C
- Est. cuttable: 35%
- Top recommendations:
  1. **The channel for the search fallback is wrong.** Step 4 (line 104) searches `in:#$SLACK_STANDUP_CHANNEL` to recover a stale escalation thread. But `/drive` posts escalations to `DRIVE_ESCALATION_CHANNEL_ID` (`drive/SKILL.md:574-579`), and Prerequisites lines 51-52 wrongly claim escalations go to the standup channel. Search by `channel_id` from the state entry, or by `DRIVE_ESCALATION_CHANNEL_ID`, and fix line 51.
  2. The "Why the standup thread matters" block (lines 19-28) is rationale. Cut it to one rule: "`all`/empty/`standup` always include the standup thread, discovered live." Lines 58-60 cite `vpn/scripts/vpn.sh`'s `load_vpn_env`, which does not exist in this repo. Delete it.
  3. The env lookup and the "skip if `SLACK_STANDUP_CHANNEL` unset" rule are explained 3 times (lines 55-69, 80-83, 101-103). Also, nothing says who sets `resolved: true`. `/drive` does (`drive/SKILL.md:45`), and one line would stop Claude from guessing.
  4. Selecting the state entries in step 1 (lines 74-76) is a jq filter that could be scripted. Splitting standup replies per task (line 98) is judgement and should stay in prose. Also, `T304536` (line 14) is not the repo's `TYYYYMMDD-NNNNNN` ID format.
- Verified stale refs: `vpn/scripts/vpn.sh` / `load_vpn_env` does not exist (the reference is also in `_session/_lib.sh:43` and `ccxp/scripts/update-roadmap.sh`). The claim at line 51 that escalations post to the standup channel contradicts `drive/SKILL.md:574`. `_session/_lib.sh` `_session_load_env` exists.
- Eval cases:
  - Run "`/slack-check-reply`" with no state file and `SLACK_STANDUP_CHANNEL` set → a `slack_search_public_and_private` call includes `"Daily Standup"`, and the skill does not stop with "no state file".
  - Run "`/slack-check-reply T20260101-000001`" with a missing entry → it errors "not found" and makes no standup search.
  - A mocked standup reply covering 2 task IDs plus 1 new request → the output attributes a directive under each task ID and has a "New scope raised" item.

## email-triage

- Grades: concision B | trigger A | clarity B | determinism C | correctness C
- Est. cuttable: 25%
- Top recommendations:
  1. **The read-only guarantee is false.** Line 172 says "The Anthropic Gmail connector is read-only as of writing". The connector in this session exposes `send_message`, `trash_thread`, `label_thread`, `mark_thread_spam` and more. Read-only must be an explicit instruction: "Use only `search_threads`, `get_thread`, `list_labels`; never call any mutating Gmail tool." Put it in the Workflow, not a Note.
  2. Lines 81 and 152 hardcode "last 7d" in the output templates, even when `--window` is given. Use `<window>`. Line 114 says "optionally `get_thread`" and line 120 says "cap at 3". Make it deterministic: always read #1, and read #2-3 only if their score is within 1 point of #1.
  3. The scoring in Phase 4 (lines 97-110) is mechanical once each thread's features are extracted. A `scripts/rank.sh` (JSON features in, sorted list out) with BATS would make ranking reproducible and tunable (as line 176 asks). The key-contacts list (line 106) needs a defined location (for example, `EMAIL_TRIAGE_KEY_CONTACTS` in `~/.claude/.env`), not "lives outside the skill".
  4. Cut the ASCII mental model (lines 10-27) to one sentence. Notes line 177 repeats line 74, and line 175 repeats line 120. Lines 146-149's DM-resolution fallbacks are vague ("if exposed"). Name the actual Slack MCP call to use (`slack_send_message` with the user's `U…` ID).
- Verified stale refs: the `/schedule` skill (lines 164-167) does not exist in this repo or in the available skills list. Point to the `loop` skill or a Routine instead. The read-only connector claim on line 172 is stale.
- Eval cases:
  - Run "triage my inbox" against a mocked Gmail → the transcript contains zero calls to `send_message`, `trash_*`, `label_*`, or `mark_*_spam`.
  - Run "`/email-triage --window 24h --no-slack`" → the search query contains `newer_than:1d` (or 24h), the output header says 24h and not 7d, and there are no Slack calls.
  - A fixture with a `noreply@` newsletter and a human "invoice due Friday" thread → the invoice thread is the Top action item and the newsletter appears in the digest.
