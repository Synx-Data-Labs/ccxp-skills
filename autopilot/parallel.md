# Autopilot: parallel cycles (`max_dop` above 1)

Loaded by `autopilot/SKILL.md` Phase 3 when `max_dop` is above 1. With the default (1) none of this applies.

For each free slot in turn, all in the same reply (one `Agent` call per slot, issued together so they run side by side):

1. Slots beyond the first running cycle need the machine guard: `autopilot-state.sh guard` prints `ok` or `hold <reason>` (free memory under 20 % of the total, or 1-minute load per CPU over 1.5, or a probe that cannot be read). On `hold`: dispatch no more slots this wake, tell the user why (`slot <N> held: <reason>`), run `autopilot-state.sh hold 300 "<reason>"` and end with the Phase 4 `ScheduleWakeup(300, ...)` unless a cycle is about to be dispatched. **One extra slot per wake**: after starting a slot beyond the first, stop filling; if slots are still free, run `autopilot-state.sh hold 120 ramp` and `ScheduleWakeup(120, "/autopilot on")`, so the next guard read includes the new cycle's load. Slot 1 with nothing running is never held.
2. `ID=$(autopilot-state.sh top "$CLONE_PATH")`: the first eligible task that is not in flight in another slot (`top --nth N` = the Nth). An empty id (a `drift` or `none` pickable) means no extra cycle: skip this and every later slot, and when other cycles are still running record nothing (no `record idle`, which would free a running slot): just end the turn, the running cycles' Phase 4 re-arms the wake. Never dispatch two slots on one task.
3. `autopilot-state.sh busy on "$ID" --slot <N>` (exit 3 = the task is already in another slot: skip it), then `ledger.sh start <n> "autopilot cycle s<N>" --flags autopilot`, then the `Agent` call for `/drive T<id> --auto-selected` (an explicit id, so no two cycles auto-pick the same task) with that slot's `$CLONE_PATH` in the prompt (create the clone first, as Phase 3 does for slot 1, with the Notes command below).

The cycles are independent: each has its own clone, claim, ledger row and report. Counters, daily caps (`cap` counts running cycles, so parallel dispatch cannot overshoot the cycle cap; the merge cap can be exceeded by at most `max_dop` - 1 merges) and the wake timer stay global.

## Notes

- Slot clones: `clone-path <repo-root> --slot <N>` (slot 1 unchanged, slot N appends `-s<N>`), recorded with `set-clone <N> <path>`; `off` prints every clone to remove.
- Lowering `max_dop` never stops a running cycle: the extra slots finish and are not refilled.
- State: `slots` = `{"<n>": {task, since}}`; `busy_since`/`current_task` mirror the oldest running slot; a mark older than 3 h is a crashed cycle.
- Finish: `busy off --slot <N>` and `record <outcome> <merged> <task> "<reason>" --slot <N>` free that slot only (default slot 1); with several cycles finishing close together handle one completely (classify, visits, housekeeping, `record`) before the next: state writes are locked and housekeeping agents run one at a time. The wake timer is one global value, the latest write wins and free slots wait for it. A `ScheduleWakeup` from a finishing cycle is harmless while others run: the state decides whether a wake dispatches.
- `pickable` ignores tasks in flight in another slot (and tasks `Blocked by` one); `drift` only counts while no slot is running a cycle.
- Slot numbers are 1 to `max_dop`; a free slot is a number up to `max_dop` that `autopilot-state.sh slots` does not list.
