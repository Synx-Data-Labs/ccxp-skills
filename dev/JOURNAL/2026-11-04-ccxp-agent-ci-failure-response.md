# ccxp-agent: CI failure auto-response rule

- Owner: "for the ccxp-agent, if you detect the CI failure, I'd like to add an instruction for you to immediately started investigation and create new task, top it, and drive it right away."
- Added `## CI failure response` to `agent-pairing/assets/ccxp-agent.md`: one read-only `gh run list` check per turn / autopilot wake, dedupe by run id, one background job per new failure (`/rca`, `/new-task`, `/top`, `/drive`), max 3 per turn.
- Detection only works while the agent is active; no background watcher.
- Bats: `asset: CI failure response section ...` in `tests/agent_pairing.bats`. No version bump; the owner decides the release.
