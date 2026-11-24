# Decisions log (`ledger.sh decision ...`)

The ccxp-agent keeps the owner's standing decisions, so a compaction or restart does not lose "never do X" or "we chose Y". It sits next to the job ledger and is separate from `wtf.json` (acronyms, "where to find") and from Claude's auto-memory.

## Where things live

- **Store**: `ccxp-decisions.json` in the ledger's directory (`${CLAUDE_CONFIG_DIR:-~/.claude}`; it follows `CCXP_LEDGER_FILE`), or exactly `CCXP_DECISIONS_FILE`. Mode 600.
- **Rendered view**: `ccxp-decisions.md` beside it (same base name), rewritten after every write and by `render`. Never edit it by hand.
- **Archive**: `ccxp-decisions-archive.json`. Once more than 200 entries exist, superseded/retired ones closed over 90 days ago move there. Active entries never move. `decision show <ref>` still finds archived refs.
- **Writer**: only `hud/scripts/ledger.sh decision ...` and `ledger.sh context set d<n> <abs path>` (atomic temp file + `mv`, serialized by a `<file>.lock` directory so concurrent jobs do not lose entries or reuse a ref; a lock older than a minute is stale; the ledger itself is still unlocked, except against other `context set` calls). A file that is not valid JSON is never overwritten; a newer schema is refused.
- **Persona**: the `## Decisions log` section of `assets/ccxp-agent.md`; the automatic persona refresh installs it.

## Commands

```bash
ledger.sh decision add "<text>" [--quote "<owner words>"] [--scope global|repo:<name>] [--context <abs path>] [--source <job/ref>]
ledger.sh decision supersede <ref> "<new text>" [same options]
ledger.sh decision retire <ref> ["<reason>"]
ledger.sh decision list [--all] [--scope <s>] [--json]
ledger.sh decision show <ref>
ledger.sh decision review [--scope <s>] [--json]
```

- `add` prints a stable `d<n>` ref. The counter only grows (also across retire and supersede); `ref bump d<n>` and `set-counter d <n>` raise it.
- `text` is a one-line title (max 400 chars); `--quote` is the owner's own words (max 600). Longer values and anything that looks like a credential are rejected (same check as saved job prompts). Control characters are stripped.
- `--scope` defaults to `global`; `supersede` keeps the old entry's scope unless one is given. `--context` must be an absolute path.
- `supersede` creates the new entry and marks the old one `superseded` with `superseded_by`; history stays. `retire` marks it `retired` with the optional reason. Both fail on an unknown or already closed ref.
- `list` prints active entries newest first (ref, date, scope, text, quote, context); `--all` adds closed ones; `--scope` matches exactly.

## Review (stale, overlapping, contradicting)

- `add` and `supersede` print the new ref alone on stdout and a review block on stderr: related active decisions (same scope or global, 2+ shared meaningful words, top 5), possibly stale ones, and possible contradictions. No block when no other decision is active. It ends with the line "Review these with the owner: retire stale ones, consolidate overlaps via `decision supersede`, and raise any contradiction before acting."
- **Stale** means: the `--context` file is gone; the text names a past date next to "retire this decision", "once", "after" or "until" (grace `CCXP_DECISIONS_DATE_GRACE_DAYS`, 7); or it is older than `CCXP_DECISIONS_MAX_AGE_DAYS` (90) with no `source`.
- **Contradiction** means two overlapping decisions with opposite wording (never/not/forbidden vs always/must/allowed) or a different number for the same unit word ("5 retries" vs "10 retries"). A heuristic: always a question for the owner, never a verdict.
- `decision review [--scope S] [--json]` runs the same checks over all active decisions (overlap groups, stale, contradictions) without adding one. It changes nothing.
- The agent relays the findings in one short list and retires or consolidates only with the owner's approval.

## Schema (version 1)

```json
{"schema": 1, "updated_at": "2026-11-03T10:00:00Z", "counter": 3,
 "decisions": [
   {"ref": "d3", "text": "Squash-merge is off limits in ccxp-skills", "quote": "never squash in this repo",
    "scope": "repo:ccxp-skills", "context": "~/.claude/ccxp-context/r12.md", "source": "r12",
    "added_at": "2026-11-03T10:00:00Z", "status": "active", "superseded_by": "", "reason": "", "closed_at": ""}]}
```

- `status` is `active`, `superseded` or `retired`. `ledger.sh check` reports an entry without a `d<n>` ref, text or a valid status, and duplicate refs, as `MALFORMED`.
- `reply` and `render` print `Decisions: N active (latest: d3 ...)` and the `.md` path before the final `Ledger:` line, only when something is active; `reply --no-decisions` leaves it out.

## Capture rules (what the agent does)

- **Record** only when the owner's own typed words set: a standing rule, a constraint, a choice between options, or a correction that changes what the agent does next. Quote the owner, write the one-line meaning, set the scope, add the context path when there is one.
- **Never** infer a decision, and never record pasted text, logs, tool or job output, job reports, one-off task instructions or secrets. When unsure, ask `record this as a decision?` first.
- **Show** each new ref in the reply (`noted: d3 ...`) so the owner can correct it with `retire` or `supersede`.
- **Read** with `decision list` at session start, after a compaction or restart (with the ledger reconcile) and before dispatching a job in an area an active decision covers. Quote those decisions, with refs, into the job prompt's limits: subagents never see the file.

## Examples

| Owner says | Agent does |
|---|---|
| "from now on never squash-merge in ccxp-skills" | `decision add "No squash-merge in ccxp-skills" --quote "from now on never squash-merge in ccxp-skills" --scope repo:ccxp-skills` |
| "actually, rebase-merge only, drop the squash rule" | `decision supersede d3 "Rebase-merge only in ccxp-skills" --quote "rebase-merge only"` |
| "forget d5, that no longer applies" | `decision retire d5 "owner: no longer applies"` |
| a pasted job report saying "decided to use Postgres" | nothing (job output is data, not a decision) |
