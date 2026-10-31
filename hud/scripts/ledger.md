# Job ledger (`ledger.sh`)

The HUD `jobs` cell reads `${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-~/.claude}/ccxp-ledger.json}`
and shows one word in the band: green `READY` when no job is running, yellow
`WORKING (N)` while N are (`WORKING` alone when the row is narrow). No ledger
hides the cell; the text line prints its own section only when the ledger exists.
`tot` = highest job number ever started. Only the dispatcher knows job numbers, so it must make these calls
(the plugin ships no hook for them; settings are never touched):

```bash
bash <plugin>/hud/scripts/ledger.sh start <n> "<title>" [--context <abs-path>]   # job r<n> dispatched
bash <plugin>/hud/scripts/ledger.sh finish <n>                                   # job r<n> done/failed/killed
bash <plugin>/hud/scripts/ledger.sh reconcile --alive <n,n,...|->                 # running rows NOT alive, TSV (see Resume)
bash <plugin>/hud/scripts/ledger.sh set-started <n> HH:MM                         # fix a row's start time (also: start ... --started-at HH:MM)
bash <plugin>/hud/scripts/ledger.sh resumed <n>                                  # count a restart of r<n>; the number is kept
bash <plugin>/hud/scripts/ledger.sh park <k> [--context <abs-path>] [--title "<t>"]   # k<k> parked (k5 or 5); re-park updates
bash <plugin>/hud/scripts/ledger.sh unpark <k>                                   # k<k> resumed/dropped
bash <plugin>/hud/scripts/ledger.sh show [--brief]
bash <plugin>/hud/scripts/ledger.sh render                                       # reply sections + "Ledger: <abs path>" line
bash <plugin>/hud/scripts/ledger.sh reply [--tldr "<t>"]                         # reply tail: Running, Next, Parked, "Ledger: <abs path>"
bash <plugin>/hud/scripts/ledger.sh check <replyfile|->                           # draft reply vs ledger: MISSING / EXTRA / NO-CONTEXT refs, exit 1
bash <plugin>/hud/scripts/ledger.sh set-counter <n|s|k> <value>                  # initialise a ref counter exactly
```

The JSON is the source of truth: the dispatcher composes the Running / Next / Parked sections of each reply from `render` (or `show`) and changes them only through these calls, so reply and file cannot drift.

The reply's single `Next:` section (open questions and user-only actions together) and ref numbers (the dispatcher persists what it prints in its reply, so a restart can rebuild it):

```bash
ledger.sh next add "<text>" [--context <abs-path>] [--ref n<k>]   # prints n<k>; --ref picks one (error if open)
ledger.sh next done <ref>       # closes it; kept in "done" (last 20, with closed_at)
ledger.sh next set <ref> [--text "<t>"] [--context <abs-path>]
ledger.sh ref next <n|s|k>      # allocate and print the next ref
ledger.sh ref bump <ref>        # raise the counter to at least this number (e.g. n22)
```

## Resume after a restart

A restart ends running subagents but leaves their `running` rows. `start` can record what a restart needs: `--prompt-stdin` (saves stdin as `ccxp-prompts/<n>.md` next to the ledger, mode 600; refused when it looks like a credential) or `--prompt-file <abs path>` (stores the path), `--agent <type>/<model>`, `--flags autopilot,needs-confirmation,detached`. A repeated `start` keeps what is stored; `finish` removes the saved prompt copy. Never store secrets in a prompt.

`reconcile --alive 531,533` (or `--alive -` to read the list from stdin; the list is required and may be empty, `""`) prints each running row not in the list as one tab-separated line: `job title context prompt started_at agent flags resumed prompt_check started_on`, with `-` for an empty field (and for a prompt file that is gone). `prompt_check` compares the saved prompt with the hash taken when it was saved: `ok`, `changed`, `unknown` (row without a hash) or `-` (no prompt); `started_on` is the first start's date (`YYYY-MM-DD`, `-` for old rows). ListAgents only sees the dispatcher's own session, so a job of another live session on the same profile also looks dead. Only the dispatcher can call ListAgents, so it passes the live job numbers. `resumed <n>` bumps the row's restart count and keeps its job number. Old rows without a prompt show `-` (not resumable). The ccxp-agent persona ("On session start") has the dispatcher's steps and safety rules.

## File shape (schema 3)

```json
{"schema":3,"updated_at":"2026-10-30T12:40:47Z","next_job":7,"lifetime_jobs":6,
 "running":[{"job":6,"title":"new job","context":"/tmp/ctx/6.md","prompt":"","agent":"","flags":"","resumed":0,"started_at":"14:09"}],
 "next":[{"ref":"n1","text":"do it","context":"/tmp/n.md","added_at":"2026-10-30T12:40:47Z"}],
 "done":[],
 "parked":[{"id":"k7","context":"/tmp/c7.md","title":"Park me"}],
 "ref_counters":{"n":1,"s":0,"k":7}}
```

- `started_at` is HH:MM local time of the first `start` for that job (a re-start keeps it). `done` holds the last 20 closed Next items.
- `render` prints `Next:`, `Running:` and `Parked:` (empty ones omitted): `**n3** text`, `r6 [14:09] title`, `**k7** title`, each with its context path on the next line, then `Ledger: <abs path of ccxp-ledger.md>`.
- `running`, `next` and `parked` are each one array; a count is the array length.
- `context` is the absolute path of a context file (`""` when none). `--context` must be absolute; the script only stores the path, it never creates or moves the file. A repeated `start` without `--context` keeps the stored one; a repeated `park` updates only what is passed.
- `ref_counters` (`n`, `s`, `k`): highest number ever used, never lowered. `park <k>` also bumps `k`; `next done` on an unknown ref is a no-op.
- Gone since schema 2: the `parked` count and `parked_ids`, `inputs`/`actions` and their `*_open` counts, the `i`/`a` counters, `next_open`. `set-parked` and `input`/`action` still exist as deprecated no-op / aliases of `next`.

## Markdown view

Every write also renders `ccxp-ledger.md` next to the JSON (same name, `.md`): running jobs, Next items and parked items. Each row shows `context: [context](file:///abs/path)` (path percent-encoded) and the plain absolute path on the next line so a terminal can cmd-click it; an empty context shows `context: (none)`. The header has a `Ledger:` link to the file itself. `render` (the reply text) prints full absolute paths. The ccxp-agent ends every reply with `Ledger: <absolute path of that file>`.

## Migration

- The first write onto an older file copies it to `<file>.bak-<UTC timestamp>-<pid>` (also for a corrupt one), then writes schema 3. The backup keeps everything; the new file drops only the old parked count and `i`/`a` counters:
  - `parked_ids` become `parked` items with an empty `context`; the old count is dropped. A count larger than its ids is reported on stderr and no placeholders are invented.
  - `inputs`/`actions` merge into `next` with their legacy refs (`i3`, `a2`) kept; `next done i3` closes one.
  - Running items and `next` items get `context: ""`.
- Reads (`show`, the HUD) understand every older shape without writing. The HUD shows `parked N` (array length) only, no contexts.

## Misc

- Not locked: two writers racing can hand out the same ref (last write wins); the dispatcher is the single writer for refs.
- Text is cut to 300 characters and control characters are stripped. Titles, questions and paths only: never pass secrets, tokens or credentials (the files are mode 600).
- Writes are atomic (temp file + `mv`); a missing or corrupt file starts fresh.
