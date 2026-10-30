# _threads

Single owner of `.claude/state/drive-threads.json` (the local record of Slack
escalation threads). Skills call `threads.sh` instead of editing the JSON with
their own `jq`.

| Command | What it does | Exit |
|---|---|---|
| `add <key> --channel --ts --type --summary [--sent-at]` | create or replace the entry | 0 / 2 / 4 |
| `resolve <key> [--at] [--resolution]` | mark resolved | 0 / 3 absent or already resolved / 4 |
| `fix-ref <key> --channel --ts` | repair a stale channel/ts in place, keep everything else | 0 / 2 / 3 absent / 4 |
| `list [--unresolved] [--full]` | TSV: key, resolved, type, sent_at, summary (`--full`: + channel_id, message_ts) | 0 / 4 |
| `prune [--days N]` | drop resolved entries older than N days (default 7) | 0 / 3 nothing to prune / 4 |

- Global flags: `--file F` (default `$THREADS_FILE`, else `.claude/state/drive-threads.json`), `--dry-run` (print, do not write).
- Writes are atomic; a malformed file is never modified (exit 4).
- `NOW=<YYYY-MM-DDTHH:MM:SSZ>` pins the clock for tests.
- Depends on `_date/date.sh` (portable GNU/BSD date arithmetic).
