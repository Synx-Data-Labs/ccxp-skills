# ccxp-agent: maintain the HUD job ledger

- **Why**: the HUD jobs cell (READY / WORKING (N), job list) stayed hidden because nothing wrote `ccxp-ledger.json`
  - Only `hud/scripts/ledger.sh` writes it, and only the dispatcher knows job numbers
  - The installed `ccxp-agent.md` never mentioned the ledger, and its Bash is read-only
- **What** (`agent-pairing/assets/ccxp-agent.md`): new `## HUD job ledger` section
  - Every job prompt (Agent and detached) carries two best-effort lines after the repo context block: `ledger.sh start <n> "<title>"` as the first action, `ledger.sh finish <n>` as the very last
  - Ledger number and title equal the Agent `description` (`#<n> <title>`); the job writes its own entry, so a compacted dispatcher context cannot lose it
  - A job that dies early (failed, killed, TaskStop) is closed by the dispatcher itself with `ledger.sh finish <n>`; chosen over a follow-up job because `finish` is idempotent, touches only the ledger file, and a job would need its own ledger entry
  - Parked items (`k<n>`) are not jobs, so the dispatcher runs `park`/`unpark` itself; the carve-out is exactly `finish`, `park`, `unpark`
  - The "Bash is read-only" sentence and the detached-launch "one allowed state-changing call" sentence now name the carve-outs
- **Known limits**
  - A harness that refuses the script call (seen in worktree-isolated jobs) makes `start` fail too, so the job is simply not listed; nothing goes stale
  - `ledger.sh` is last-write-wins without locking; two jobs starting in the same instant can drop one entry
- **Tests**: three cases in `tests/agent_pairing.bats` (section and start/finish wording, carve-out limits, the documented calls against `ledger.sh`)
- **Rollout**: needs a release, then `agent-pairing update` (backup kept), then a new session; no version bump here (backward-compatible behavior = MINOR, separate maintainer PR)
