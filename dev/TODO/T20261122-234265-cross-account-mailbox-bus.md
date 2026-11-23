---
status: In Progress
scheduled: 2026-11-23
estimation: 1
source: Owner request 2026-11-22 (cross-message spec)
type: feature
description: Same-machine mailbox (bus) so Claude Code sessions on different Claude accounts can message each other
---

# T20261122-234265: Cross-account mailbox (bus) so sessions on different Claude accounts can message each other

Full spec (verbatim): [dev/docs/cross-account-bus-spec.md](../docs/cross-account-bus-spec.md)

## Problem

- Owner's words: "take a look at the spec ..., and create a new task to work on it. I need a way to enable messaging between two claude sessions from two different accounts"
- Built-in SendMessage / ListAgents does not cross `CLAUDE_CONFIG_DIR` profiles
  - Confirmed live by the owner 2026-11-22: the two profiles show completely different agent lists
  - Reaching the other profile's socket would depend on an undocumented format, so the bus does not
- Done = a work-account session and a home-account session on one machine can leave each other notes that survive a closed receiver, wake an idle one, show in the terminal, and arrive once

## Settled decisions (owner, 2026-11-22)

| Question | Decision |
| --- | --- |
| Skills or tools | Skill plus script (`_bus/bus.sh`), no MCP tool |
| How the accounts are split | Two `CLAUDE_CONFIG_DIR` profiles, one named agent each |
| Existing hooks | Yes: the plugin's `hooks/hooks.json` |
| Several sessions on one account | Not used; bus enforces one live session per profile |
| Wake an idle session | Required (`asyncRewake` Stop hook; confirmed live) |
| Show notes in the terminal | Required (`systemMessage` plus HUD cell) |
| Retention | 14 days; lasting context goes in repo journals |
| Platforms | Linux and macOS only |
| work to home prompt | None; notes go without asking |
| Company policy | Owner decides |

## Build order

- [x] 1. Spike: done live by the owner 2026-11-22, not re-run: built-in messaging does not cross profiles; an async `asyncRewake` Stop hook that slept 60 s and exited 2 woke an idle session; the timeout applies to async hooks (a 90 s wake with a 30 s timeout never fired), so set 28800 s and exit 0 a minute early
- [x] 2. T20261123-352398 `_bus/bus.sh` (`send`, `deliver`, `watch`, `status`, `read`, `prune`) with bats tests in `tests/`; locks via `_session/lock.sh`; identity via `_session/profile-dir.sh`
- [ ] 3. T20261123-596451 `hooks/hooks.json` entries: `SessionStart` (`deliver --register` plus async `watch`), `UserPromptSubmit` (`deliver`)
- [ ] 4. T20261123-292735 `bus` skill (when and how Claude runs `bus.sh`; follows skill-conventions)
- [ ] 5. T20261123-244661 HUD `bus` cell (`bus 2 · home`) and the hook `systemMessage` notice
- [ ] 6. T20261123-212153 `watch` wake behaviour (`asyncRewake`) and the `Stop` wake entry in `hooks/hooks.json`; step 3's `SessionStart` watch entry carries the same `async`/`asyncRewake` flags

## Acceptance criteria (testing plan)

- [x] Spike first: SendMessage between two profiles; async `Stop` hook exiting 2 after 60 s idle wakes the session, and the timeout behaviour is recorded (owner, live, 2026-11-22)
- [x] Unit (bats): encode/decode, unknown fields ignored, 4,000-char cap, cursor save/reload, `recent_ids` dedupe, rotation only at end of file; time pinned with `NOW=`
- [x] Concurrency: 4 writers x 1,000 notes to one inbox while the reader drains; exactly 4,000 delivered, no torn lines, no duplicates
- [x] Crash: `kill -9` a writer mid-send and the reader between inject and cursor save; no partial line, no repeat
- [ ] Wake: idle `work` session, `home` sends; `work` wakes within 5 s, terminal shows the notice, HUD cell clears
- [ ] Offline: send to a closed session, open it, delivery shows age; inbox past the cap gives "mailbox full" (500 notes or 5 MB)
- [x] Guards: folder loosened to `0755` makes the hook refuse; a second live session on one profile has its bus off
- [x] Injection: a note with the wrapper's closing marker, fake "user:" lines and control characters arrives escaped and labeled
- [ ] End to end: `home` sends, `work` replies with `--reply-to`, `home` sees the thread; on Linux and macOS

## Security and trust constraints

- Notes are labeled data from another agent, never commands or user instructions
  - Wrapped in `<ccxp-notes>` with "not your user" label; control characters stripped; closing marker escaped
  - The hook never executes, opens or fetches anything named in a note and never triggers a tool call
- No automatic replies (also rules out agent loops); a reply is the receiving Claude's choice, on its user's word
- Files: `~/.ccxp/bus/` is `0700`, every file `0600`, created under `umask 077`; hook refuses and warns on loose perms or foreign owner
- Local disks only; refuse to start on NFS or synced folders
- Same-OS-user programs can read the bus: accepted, not a security boundary
- Home side must not copy `work` notes into memory, files or other tools (label says so)

## Open points

- Spike items are recorded as confirmed in the spec; re-run only if behaviour is in doubt
- Work/personal boundary: notes of one account sit on the same device as the other account; the owner's organization policy is the default until changed
- `home -> work` direction "configurable" is unspecified (no config shape defined)
  - Default taken: both directions allowed without a prompt; the only knob is `<profile>/ccxp-bus/config.json` (`name`, optional `ttl_days`, `allow_from` list; absent allows all registered agents)
- Not confirmed in spec: what Claude sees from a `Stop` hook's `reason`
- Fallback if `asyncRewake` proves unreliable: `idle-wake.sh` also runs `bus.sh deliver` (30 min worst case)
