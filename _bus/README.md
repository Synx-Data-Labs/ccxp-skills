# _bus

Same-machine mailbox so Claude Code sessions on different profiles (`CLAUDE_CONFIG_DIR`) can leave each other short text notes. Single owner: `bus.sh`. Spec: [dev/docs/cross-account-bus-spec.md](../dev/docs/cross-account-bus-spec.md).

| Command | Called by | Does |
|---|---|---|
| `init --name N [--label L]` | the owner, once per profile | writes `<profile>/ccxp-bus/config.json`; the bus is inert without it |
| `send --to A [--reply-to ID] TEXT` | Claude (the `bus` skill) | appends one note to A's inbox; prints `queued <id>; A last seen ...` |
| `deliver [--register]` | `SessionStart`, `UserPromptSubmit` hooks | prints unread notes as hook JSON (`systemMessage` + wrapped `additionalContext`) |
| `watch` | async hook | waits for a note, prints it on stderr, exits 2 (wakes the idle session) |
| `status` | HUD | `bus 2 · home` when notes are unread, else nothing; read-only, no lock |
| `read [--thread ID]` | Claude or the owner | history from inbox and archives, wrapped like a delivery |
| `prune [--days N]` | `deliver`, once a day | deletes archives older than the retention (default 14 days) |

- **Exit codes**: 0 ok or nothing to do, 2 usage, 3 unknown recipient or not configured, 4 mailbox full, 5 unsafe bus, 6 lock timeout. Hook commands never fail loudly.
- **Config** (`<profile>/ccxp-bus/config.json`): `name` (a-z0-9-, 32 chars; else the profile folder's base name), optional `label`, `retention_days`, `allow_from` (list of agent names; absent allows every registered agent).
- **Layout** under `~/.ccxp/bus/` (`0700`, files `0600`): `agents.json`, `inbox/`, `cursor/`, `lock/`, `watch/`, `archive/`, `bad/`.
- **Delivery**: at least once, deduped by `id` (the last 200 delivered ids sit in the cursor). The cursor is saved with the new ids first, then the offset after the output, so a crash in between repeats nothing.
- **Limits**: 4000 characters per note, 10 notes and 8000 rendered characters per delivery, 500 unread notes or 5 MB before "mailbox full".
- **One live session per name**: a second live session on the same profile gets the bus switched off with a warning. A new session id under the same process (`/clear`, `/resume`) is not a second session.
- **Trust**: notes are sanitized (control and bidi characters stripped, `<` escaped, each line prefixed with a greater-than sign) and wrapped in `<ccxp-notes>` with a label saying they are another agent's words, not the user's. Nothing in a note is executed or fetched; there are no automatic replies.
- **Needs**: bash 3.2 or newer, `jq`, POSIX tools. Locks come from `_session/lock.sh`, never `flock`. The bus refuses network, fuse and synced folders.
- **Tests**: `tests/bus.bats`; `NOW=<YYYY-MM-DDTHH:MM:SSZ>` pins the clock, `BUS_STRESS_NOTES` sets the notes per writer of the concurrency test (default 250; the spec's 1000 passes too).
