# Decisions log (`ledger.sh decision ...`)

The ccxp-agent keeps the owner's standing decisions, so a compaction or restart does not lose "never do X" or "we chose Y". It sits next to the job ledger and is separate from `terms.json` (acronyms) and from Claude's auto-memory.

## Where things live

- **Store**: `ccxp-decisions.json` in the ledger's directory (`${CLAUDE_CONFIG_DIR:-~/.claude}`; it follows `CCXP_LEDGER_FILE`), or exactly `CCXP_DECISIONS_FILE`. Mode 600.
- **Rendered view**: `ccxp-decisions.md` beside it (same base name), rewritten after every write and by `render`. Never edit it by hand.
- **Archive**: `ccxp-decisions-archive.json`. Once more than 200 entries exist, superseded/retired ones closed over 90 days ago move there. Active entries never move. `decision show <ref>` still finds archived refs.
- **Writer**: only `hud/scripts/ledger.sh decision ...` (atomic temp file + `mv`, serialized by a `<file>.lock` directory so concurrent jobs do not lose entries or reuse a ref; a lock older than a minute is stale; the ledger itself is still unlocked). A file that is not valid JSON is never overwritten; a newer schema is refused.
- **Persona**: the `## Decisions log` section of `assets/ccxp-agent.md`; the automatic persona refresh installs it.

## Commands

```bash
ledger.sh decision add "<text>" [--quote "<owner words>"] [--scope global|repo:<name>] [--context <abs path>] [--source <job/ref>]
ledger.sh decision supersede <ref> "<new text>" [same options]
ledger.sh decision retire <ref> ["<reason>"]
ledger.sh decision list [--all] [--scope <s>] [--json]
ledger.sh decision show <ref>
```

- `add` prints a stable `d<n>` ref. The counter only grows (also across retire and supersede); `ref bump d<n>` and `set-counter d <n>` raise it.
- `text` is a one-line title (max 400 chars); `--quote` is the owner's own words (max 600). Longer values and anything that looks like a credential are rejected (same check as saved job prompts). Control characters are stripped.
- `--scope` defaults to `global`; `supersede` keeps the old entry's scope unless one is given. `--context` must be an absolute path.
- `supersede` creates the new entry and marks the old one `superseded` with `superseded_by`; history stays. `retire` marks it `retired` with the optional reason. Both fail on an unknown or already closed ref.
- `list` prints active entries newest first (ref, date, scope, text, quote, context); `--all` adds closed ones; `--scope` matches exactly.

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
