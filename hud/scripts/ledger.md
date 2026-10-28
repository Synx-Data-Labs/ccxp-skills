# Job ledger (`ledger.sh`)

The HUD `jobs` cell reads `${CCXP_LEDGER_FILE:-${CLAUDE_CONFIG_DIR:-~/.claude}/ccxp-ledger.json}`
and shows one word in the band: green `READY` when no job is running, yellow
`WORKING (N)` while N are (`WORKING` alone when the row is narrow). No ledger
hides the cell; the text line prints its own section only when the ledger exists.
`tot` = highest job number ever started. Only the dispatcher knows job numbers, so it must make these calls
(the plugin ships no hook for them; settings are never touched):

```bash
bash <plugin>/hud/scripts/ledger.sh start <n> "<title>"   # job r<n> dispatched
bash <plugin>/hud/scripts/ledger.sh finish <n>            # job r<n> done/failed/killed
bash <plugin>/hud/scripts/ledger.sh park <k>              # k<k> parked (k5 or 5)
bash <plugin>/hud/scripts/ledger.sh unpark <k>            # k<k> resumed/dropped
bash <plugin>/hud/scripts/ledger.sh set-parked <n>        # resync the count
bash <plugin>/hud/scripts/ledger.sh show [--brief]
```

Open questions, user actions and ref numbers (the dispatcher persists what it prints in its reply, so a restart can rebuild it):

```bash
ledger.sh input add "<text>"    # prints i<n>; ledger.sh input done <ref>
ledger.sh action add "<text>"   # prints a<n>; ledger.sh action done <ref>
ledger.sh ref next <i|a|s|k>    # allocate and print the next ref (s and k)
ledger.sh ref bump <ref>        # raise the counter to at least this number
```

- Fields: `inputs` and `actions` (`[{ref,text,added_at}]`), `ref_counters` (`{i,a,s,k}`, highest number ever used, never lowered), `show` also reports `inputs_open` and `actions_open`.
- `park <k>` also bumps `ref_counters.k`; `done` on an unknown ref is a no-op.
- Text is cut to 300 characters and control characters are stripped. Titles and questions only: never pass secrets, tokens or credentials (the file is plain JSON, mode 600).
- Old files without these fields keep working; the fields appear on the next write.

Writes are atomic (temp file + `mv`); a missing or corrupt file starts fresh.
