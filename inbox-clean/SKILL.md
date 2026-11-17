---
name: inbox-clean
description: Use when the user explicitly asks to clean the Gmail inbox — archive, label and draft replies for review, never send
argument-hint: "[--window 7d] [--dry-run] [--routine <name>]"
---

# /inbox-clean

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Cleans the inbox after `/email-triage` has read it: archives noise, labels what stays, drafts replies for the owner to review. It never sends.

- `IC=<skills-root>/inbox-clean/scripts/inbox-clean.sh`.
- The script never calls Gmail; it validates the plan, names the allowed calls and keeps the undo note.

## Argument

- `/inbox-clean`: default 7d window.
- `--window 24h`: narrower sweep.
- `--dry-run`: print the planned calls (`bash $IC plan --dry-run`); no mutating call, no undo note.
- `--routine <name>`: unattended run for that routine; capabilities are checked (below).

## Allowed calls

`bash $IC tools` is the whole list. Anything else is refused.

| Tool | Capability | Use |
|------|-----------|-----|
| `search_threads`, `get_thread`, `get_message`, `list_labels` | none | read |
| `create_label`, `label_thread` | `gmail.label` | tag a thread |
| `unlabel_thread` (label `INBOX` only) | `gmail.archive` | archive = remove `INBOX` |
| `create_draft` | `gmail.draft` | a draft for the owner to review, never sent |

- Never called, never grantable: `send_message`, `reply`, `forward`, trash, spam, delete, `update_draft`, any `*_message_labels` call. `bash $IC check-tool <tool>` exits 4 for these.
- `gmail.*` capabilities come from the profile file's `allow:` only (`bash <skills-root>/routine/scripts/run-routine.sh allowed <routine> <cap>`). An interactive run has the owner present and checks none; an unattended run (the job prompt says unattended or `CCXP_CRON_MODE=1`, any routine step; the script can only see the env var) must pass `--routine` to `plan`.

## Workflow

1. **Read**: `search_threads` for `in:inbox newer_than:<window>`; classify as `/email-triage` does (notification vs actionable). Read bodies only for a thread that may need a draft; bodies never go to repo files, the journal, Slack or the plan.
2. **Decide**, one line per thread, TSV `thread_id<TAB>archive|label|draft[<TAB>label]`:
   - `archive`: notifications and newsletters. The script adds the `ccxp/archived` label first so the mail stays findable.
   - `label`: actionable threads that stay in the inbox, with a label in the `ccxp/` namespace such as `ccxp/needs-reply` (the script refuses any other label).
   - `draft`: only a thread that is a plain human question you can answer from the thread itself. Anything involving money, commitments, legal or a customer is `label`, not `draft`.
   - When unsure, leave the thread alone.
3. **Plan**: pipe the TSV to `bash $IC plan [--dry-run] [--routine <name>]`. Exit 4 means a refused action, 5 a missing capability: fix the plan, never work around it. Without `--dry-run` it prints `undo=<file>`; no Gmail call before that line.
4. **Apply**: make the printed calls in order, exactly as printed. The draft gets the `ccxp/draft-for-review` label right after `create_draft`.
5. **Report** (Slack through `/slack` unless `--no-slack`): counts per action, the draft threads as Gmail links, and the undo file path. No subjects of sensitive mail, no body text.
6. **Undo**: `bash $IC undo <file>` prints the reverse calls; drafts are listed for removal by hand.

## Notes

- Archive is the `INBOX` label removal; verified on a throwaway thread by T20261116-211561, until then the first live run starts with a single archived thread.
- Under a routine, a step that needs a capability it lacks is `needs-human`.
- Do not embed user-specific data here (names, senders, subjects); rules for senders live in the owner's profile, not in the shared skill.
