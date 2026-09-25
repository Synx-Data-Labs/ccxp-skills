---
status: Done
scheduled: 2026-09-21
estimation: 1h
source: T20260910-919422's Closed section, 2026-09-22 — the +/- and comma-spacing corruption itself is not fixed by that task's scoping fix
related: T20260910-919422
claimed_by:
claimed_role:
---

# T20260922-383156: `markdownlint-cli2 --fix` still flips a bare leading `+` to `-` and drops comma-spacing — scoping contains it, doesn't fix it

## TLDR

- **Type**: bug
- **Problem**: the scoped single-file `--fix` path (`_docs/lint-docs.sh`)
  still silently corrupts prose — a hard-wrapped `+` continuation line
  flips to `-`, and glob-pattern asterisks (`*.ext`) drop adjacent
  comma-spacing.
- **Solution**: both symptoms are confirmed as two distinct, precise rules
  (`MD004`/ul-style, `MD037`/no-space-in-emphasis); disable only those two,
  only for the scoped single-file `--fix` invocation, via an isolated
  temp-directory config override (a naive `--config` override can't
  suppress `MD004` while the real `.markdownlint-cli2.jsonc` is
  discoverable — it explicitly sets that rule, and an explicit setting
  wins over `--config` per-rule) — repo-wide/CI enforcement of both rules
  is untouched.

## Problem

- **Type**: bug
- `T20260910-919422` fixed `_docs/lint-docs.sh` so `--fix` no longer touches
  *unrelated* files, but the underlying corruption of the file it IS asked
  to lint is unchanged: a hard-wrapped prose line beginning with a bare `+`
  (meaning "and/plus", not a list item) still gets rewritten to `-` by
  MD004's dash-style enforcement — confirmed twice in real consumer-repo
  JOURNAL entries (`T20260910-919422`'s Problem/Confirmed-recurrence
  sections have the exact before/after examples and file:line evidence).
- **New, still-unexplained symptom** (same lint pass, 2026-09-22
  recurrence): dropped the space after a comma in 2 lines
  (`*.lyrics.md,*.service.md` from `*.lyrics.md, *.service.md`) — comma-
  spacing normalization isn't a documented `markdownlint-cli2`/MD004
  behavior, so the mechanism isn't yet confirmed to be the same code path
  as the `+`/`-` flip.
- Impact: any file legitimately created/edited via the doc-lint bundle that
  happens to contain a bare-leading-`+` continuation line (or comma-spaced
  text matching whatever triggers the second symptom) still gets silently
  corrupted — now caught by `git diff` review before commit (since scoping
  means it's only ever the one file actually being touched), but not
  prevented.
- Done looks like: either (a) the `+`/`-` flip is confirmed as MD004's
  dash-style rule and a targeted, non-repo-wide-weakening fix is found
  (e.g., a per-invocation rule override for the single scoped `--fix` call,
  not a blanket MD004 config change — see `T20260910-919422`'s Solution
  section for why a repo-wide MD004 reconfiguration was rejected), or (b)
  root-caused as unfixable-safely and the doc-lint bundle's callers are
  told to review the diff before committing rather than trust "fix-then-
  continue" blindly for this rule; separately, the comma-spacing symptom is
  root-caused (same mechanism or different) before deciding how to handle
  it. **Resolved: option (a) — see Root cause / Solution below.**

## Context

- `_docs/lint-docs.sh` (the shared doc-lint wrapper) — `T20260910-919422`'s
  `--no-globs` fix already merged; this task is scoped to the remaining
  content-corruption issue that fix explicitly did not address.
- `.markdownlint-cli2.jsonc`'s `MD004: {style: "dash"}` config is what
  drives the `+` → `-` rewrite when MD004 misreads prose as a list.
- This repo's own `dev/TODO/*.md` filenames use bare `T{ID}` refs that
  `lint_refs.py` auto-links (see `T20260910-919422`) — the ambiguous-`+`
  and glob-asterisk patterns this task fixes are exactly the kind of
  prose that also appears throughout task/journal files, so the fix must
  hold for that content shape specifically, not just generic markdown.

## Root cause

- **Both symptoms reproduced and root-caused empirically** (isolated repro
  under `/tmp/T383156-repro`, throwaway 2-file tree, real
  `.markdownlint-cli2.jsonc` copied from this repo — reproduced 2026-09-24):
  - Fixture (`dev/JOURNAL/target.md`):

    ```
    Some paragraph text that discusses a topic in detail and mentions PDF
    + PDF) as a parenthetical continuation that happens to start with plus.

    Another paragraph with a comma list: *.lyrics.md, *.service.md should stay spaced.
    ```

  - `markdownlint-cli2 --fix --no-globs dev/JOURNAL/target.md` against the
    real config produces exactly both previously-unexplained symptoms in
    one pass:
    - `MD004/ul-style` fires (`Expected: dash; Actual: plus`) and rewrites
      the line to `- PDF) as a parenthetical continuation...` — **confirms
      the `+`→`-` flip is MD004's dash-style enforcement**, exactly as this
      task's own Done-when criteria (a) anticipated.
    - The comma-spacing drop is a **separate rule, not MD004**:
      `MD037/no-space-in-emphasis` fires on `", *"` — the parser
      misinterprets the literal `*` in `*.service.md` (a glob pattern, not
      markdown emphasis) as an emphasis-open marker, and its fix strips the
      adjacent space to eliminate the perceived "space inside emphasis",
      collapsing `*.lyrics.md, *.service.md` → `*.lyrics.md,*.service.md`.
      **Root-caused as a distinct rule/mechanism from the `+`/`-` flip**,
      resolving this task's own "not yet confirmed to share a root cause"
      open question.
- **A naive per-invocation `--config <override>` does NOT reliably work
  when the real `.markdownlint-cli2.jsonc` is discoverable** — verified
  empirically, and the mechanism is more precise than "ignored wholesale":
  it's a **per-rule cascade**. An override file (bare rules object,
  `MD004: false`, `MD037: false`) passed via `--config`, with the real
  config still discoverable, left `MD037` successfully overridden (comma-
  spacing preserved) but **`MD004` still fired and flipped `+`→`-`
  regardless** — because the real config *explicitly* sets `MD004: {style:
  dash}`, and an explicit directory-local setting wins over `--config`'s
  base for that specific rule; `MD037` isn't explicitly mentioned in the
  real config (only implicitly on via `default: true`), so `--config`
  could override it. **Net effect: since `MD004` — the rule that causes
  the higher-severity meaning-changing corruption — is exactly the one
  rule the real config pins explicitly, a naive `--config` override can
  never suppress it while the real config is discoverable.** Full
  directory isolation (below) is therefore necessary, not just a
  preference. Confirmed by removing the real config file entirely: the
  same override then took full effect, `0 errors`, both lines preserved.
- **Confirmed fix mechanism** (same repro, real config temporarily moved
  aside, override config applied from an isolated directory): disabling
  only `MD004` and `MD037` — leaving every other rule (including `MD032`,
  which correctly still adds a blank line around the ambiguous `+` line —
  a safe, meaning-preserving fix, not corruption) — produces `0 errors` and
  preserves both the `+` and the comma-spacing byte-for-byte. No other rule
  needed disabling; the two-rule set is precise, not a broad weakening.

## Solution

- **Confirmed: Done-when option (a)** — a targeted, per-invocation rule
  override, not a blanket `.markdownlint-cli2.jsonc` change.
- **Mechanism** — `_docs/lint-docs.sh`'s `_lint_docs_run_tool` gains a
  "safe-fix" path, applied **only** when both `explicit=1` (an explicit
  path was given — T20260910-919422's existing parameter) **and** `fix=1`
  (a `--fix` call, not a check-only lint): the scoped single-file(s) fix
  path from `new-task`, `gcpr` Step 1.5, and `drive` Phase 7's two
  close-commit calls — exactly the callers `--no-globs` already scoped.
  1. Create an isolated temp directory (outside the repo tree, e.g.
     `mktemp -d`) — no `.markdownlint-cli2.jsonc` is reachable from there
     via directory-walk, so `--config` genuinely takes effect (per Root
     cause's confirmed precedence finding).
  2. Copy each target file into that directory (preserving its
     repo-relative path, to avoid basename collisions across multiple
     scoped files in one call).
  3. Discover the real repo's `.markdownlint-cli2.jsonc`, extract its
     `config` object, clone it, force `MD004: false` and `MD037: false`
     (the two confirmed-precise rules — no others), and write the bare
     rules object (no `config`/`globs` wrapper — the shape `--config`
     actually honors) to the temp directory.
  4. Run `markdownlint-cli2 --fix --no-globs <copied-path(s)>` from
     within the temp directory against that derived config.
  5. Copy the fixed content back to each file's real repo path. Report
     exit code / output the same way the existing tool invocation does.
  - **Check-only calls, the default-scope bare call (`dev/JOURNAL
    dev/TODO`, used by pre-commit guards), and CI's own full-tree lint are
    completely unchanged** — all keep using the real config with
    `MD004`/`MD037` fully enforced. Nothing is silently weakened
    repo-wide; a human/agent running a full check still sees a real
    non-dash bullet or a real "space inside emphasis" as a reportable
    violation to fix by hand.
- **Trade-off accepted**: a scoped single-file `--fix` call no longer
  auto-normalizes a genuinely-intentional non-dash bullet list (e.g., a
  real `*`-bullet list an author typed by hand) in that one file during
  the fix pass — it's still flagged by the separate repo-wide check-only
  lint, just not silently rewritten. Given this repo's own convention
  already uses `-` throughout, this is a narrow, rare cost against
  categorically eliminating a real content-corruption class.
- **Alternatives rejected**:
  - *Blanket repo-wide `MD004`/`MD037` config change* — rejected per this
    task's own framing and `T20260910-919422`'s prior reasoning: both
    rules correctly catch real formatting issues elsewhere; disabling them
    repo-wide would mask that value for a problem that scoping already
    narrows to one reviewable file.
  - *Content-level pre/post escaping of ambiguous patterns* (e.g.,
    temporarily backslash-escaping leading `+`/bare `*.ext` tokens before
    `--fix`, restoring after) — rejected as more fragile than disabling
    two now-confirmed, precise rules: it requires enumerating every
    ambiguous pattern by hand and re-verifying escape/unescape
    round-trips, where the rule-disable approach is exhaustive by
    construction (whatever `MD004`/`MD037` would have flagged, simply
    doesn't get auto-fixed).
  - *Fall back to Done-when option (b)* (root-cause as unfixable-safely,
    tell callers to review the diff) — moot now that option (a) is
    confirmed and empirically verified; no need for the weaker
    trust-the-human mitigation.

## Test plan

- [x] Unit (`tests/lint-docs.bats`): "runs the isolated markdownlint-cli2
      invocation from a temp directory with a derived --config" —
      argv/PWD-inspection via the fake-`markdownlint-cli2` fixture (extended
      with `PWD:` logging), confirms the invocation cwd differs from the
      original and both `--config`/`--no-globs` are passed.
- [x] Unit: real-tool end-to-end regression of this task's own repro —
      "preserves an ambiguous leading + and glob-comma spacing, still
      fixes real MD032 gaps": both preserved byte-for-byte, MD032 still
      inserts the needed blank line.
- [x] Unit: "does not rewrite a genuine non-dash bullet list, but
      check-only still flags it" — the accepted trade-off, verified both
      directions.
- [x] Unit: the default-scope bare call and check-only calls are
      structurally unaffected — gated on `explicit==1 && fix==1`
      (`lint_docs_run`'s existing parameters), plus the two pre-existing
      `--no-globs` tests (unchanged, still passing) cover the bare-call
      case directly.
- [x] Regression: full `bats tests/*.bats` suite green — 743/743, 0
      failures (fresh run, `/tmp/full-bats-run.log`).
- [x] Manual: re-ran the Root-cause repro against the shipped script
      directly (not a throwaway copy) — same before/after result,
      confirmed during implementation debugging (which also surfaced and
      fixed a real bug: naming the derived config exactly
      `.markdownlint-cli2.jsonc` silently defeated it via
      markdownlint-cli2's own auto-discovery, even under explicit
      `--config` — fixed by using a non-colliding filename).

## Done criteria

- [x] `_docs/lint-docs.sh`'s scoped single-file `--fix` path no longer
      flips a bare leading `+` to `-` nor drops comma-spacing around a
      glob-pattern asterisk — `tests/lint-docs.bats` (new cases).
- [x] The default-scope bare call and check-only calls are provably
      unchanged (same config, no temp-directory indirection) —
      `tests/lint-docs.bats`.
- [x] Repo-wide/CI full-tree lint still enforces `MD004`/`MD037` at full
      strength — `.markdownlint-cli2.jsonc` itself untouched (verified:
      `git diff` shows zero changes to that file).
- [x] Full `bats tests/*.bats` suite green (regression check) — 743/743.
- [x] All Test plan items above pass.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_docs/lint-docs.sh` | 195-252 (`_lint_docs_safe_fix`, new), 268-295 (`_lint_docs_run_tool`, modified) | The isolated-temp-directory "safe-fix" path, gated on `explicit=1 && fix=1` |
| `.markdownlint-cli2.jsonc` | 1-23 | Source config cloned/derived from for the temp override (not modified itself) |
| `tests/lint-docs.bats` | whole file | 3 new test cases (safe-fix preservation, accepted-trade-off, isolation/argv), 1 existing case updated to a non-triggering fixture |
| `tests/fixtures/lint-docs/fake-markdownlint-cli2.sh` | +1 line | Added `PWD:` logging to the shared fixture (additive, other tests unaffected) |
| `dev/JOURNAL/2026-09-22-T20260910-919422-lint-docs-fix-corrupts-content.md` | 124-131 | Prior task's explicit "out of scope, follow-up filed" note this task closes |

## Closed (2026-09-24)

- Shipped in [PR #145](https://github.com/Synx-Data-Labs/ccxp-skills/pull/145) (design in [PR #144](https://github.com/Synx-Data-Labs/ccxp-skills/pull/144)). Both `+`→`-` and comma-spacing
  corruption symptoms fixed via an isolated-temp-directory safe-fix path in
  `_docs/lint-docs.sh`, gated on `explicit=1 && fix=1` (the scoped
  single-file `--fix` callers `T20260910-919422` already narrowed via
  `--no-globs`). Repo-wide/CI full-tree lint enforcement of `MD004`/`MD037`
  is unchanged.
- All Done criteria met; full `bats tests/*.bats` suite green (743/743, 0
  failures, fresh run).
- Implementation surfaced and fixed one real bug beyond the design: naming
  the derived override config exactly `.markdownlint-cli2.jsonc` silently
  defeated it, since `markdownlint-cli2` does its own auto-discovery walk
  for that exact filename with different parsing expectations than a file
  supplied via `--config` — even the identical content, under that reserved
  name, failed to suppress `MD037`. Fixed by using a non-colliding filename
  (`lint-docs-safe-fix-override.jsonc`).
- Quality probe recorded (`dev/quality/metrics.jsonl`): `shellcheck` clean,
  `max_fn_lines`/`file_loc` regressed (+27/+286) — expected given the new
  function and test cases added, not a quality concern.
- No follow-up tasks filed — this closes T20260910-919422's own
  explicitly-deferred follow-up cleanly, no further open threads.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0, code-class;
  wrote 3 new `tests/lint-docs.bats` cases first, watched all 3 fail for
  the expected reason (feature missing), implemented to green, then found
  and fixed the `.markdownlint-cli2.jsonc`-filename bug through the same
  red→green cycle on the failing assertions.
- Verification (`superpowers:verification-before-completion`): yes — fresh
  full-suite re-run (743/743) and shellcheck check before opening the PR,
  not relying on the earlier truncated background-run output.
- Systematic debugging (`superpowers:systematic-debugging`): implicitly
  applied (hypothesis-driven isolation of the `.markdownlint-cli2.jsonc`
  auto-discovery bug via a sequence of controlled variable-elimination
  repros) though not formally invoked as a separate skill call — the
  debugging matched its spirit closely enough that a separate invocation
  would have been redundant.
- Receiving code review (`superpowers:receiving-code-review`): yes — used
  at the design-PR stage ([PR #144](https://github.com/Synx-Data-Labs/ccxp-skills/pull/144), 3 review rounds, all findings fixed,
  none pushed back on).
