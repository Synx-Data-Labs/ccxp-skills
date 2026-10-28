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

The reply's single `Next:` section (open questions and user-only actions together) and ref numbers (the dispatcher persists what it prints in its reply, so a restart can rebuild it):

```bash
ledger.sh next add "<text>"     # prints n<k>; ledger.sh next done <ref>
ledger.sh ref next <n|s|k>      # allocate and print the next ref
ledger.sh ref bump <ref>        # raise the counter to at least this number (e.g. n22)
```

- Fields: `next` (`[{ref,text,added_at}]`), `ref_counters` (`{n,s,k}` plus the retired `i`,`a`; highest number ever used, never lowered). `show` reports `next_open`; `inputs_open` and `actions_open` stay in the output as 0 for old callers.
- DEPRECATED: `input add|done` and `action add|done` still work as aliases of `next add|done` (same list, new refs are `n<k>`).
- Old files: their `inputs`/`actions` arrays are merged into `next` with the legacy refs (`i3`, `a2`) kept, and the old arrays are dropped on the first write. `next done i3` closes a legacy item.
- `park <k>` also bumps `ref_counters.k`; `done` on an unknown ref is a no-op.
- Not locked: two writers racing can hand out the same ref (last write wins); the dispatcher is the single writer for refs.
- Text is cut to 300 characters and control characters are stripped. Titles and questions only: never pass secrets, tokens or credentials (the file is plain JSON, mode 600).
- The HUD shows no open-item counts today; a consumer wanting one reads `next_open` (or `inputs_open + actions_open` on a pre-`next` file).

Writes are atomic (temp file + `mv`); a missing or corrupt file starts fresh.
