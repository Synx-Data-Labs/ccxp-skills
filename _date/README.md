# _date

Portable (GNU and BSD/macOS) date arithmetic for skills. Replaces ad-hoc
`date -d` (GNU only) and `date -v` (BSD only) calls.

| Command | Result |
|---|---|
| `date.sh today` | today, `YYYY-MM-DD` (`TODAY=` overrides) |
| `date.sh dow [DATE]` | ISO weekday, 1=Mon .. 7=Sun |
| `date.sh add DATE N` | DATE plus N days (N may be negative) |
| `date.sh monday [DATE] [--next]` | Monday on or before DATE; `--next`: on or after |
| `date.sh ago N` | UTC timestamp N days ago (`NOW=` pins the clock) |

- `monday.sh` is a thin front for `date.sh monday`.
- Exit 0 ok, 2 usage or invalid date (impossible dates like 2026-02-31 are rejected).
- Sourceable: functions are prefixed `d_`.
