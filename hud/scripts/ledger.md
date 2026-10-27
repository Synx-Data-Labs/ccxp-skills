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
bash <plugin>/hud/scripts/ledger.sh show
```

Writes are atomic (temp file + `mv`); a missing or corrupt file starts fresh.
