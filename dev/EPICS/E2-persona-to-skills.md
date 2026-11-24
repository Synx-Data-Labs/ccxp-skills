### E2 — Persona to skills, skills to scripts

Goal: shrink the ccxp-agent persona by moving procedures into skills with scripts, let `/retro` keep the persona current from the decisions log, and turn deterministic skill prose into tested `scripts/*.sh`
Done when: every member below is closed (in `dev/JOURNAL/`) and the targets in "Baseline and targets" are met or revised with evidence in the closing member

Owner's words (2026-11-24, decision d155): "for the persona, one tip to reduce size would be create skills and put logic into the skills, and scripts associated with the skills. let's enhance the /retro to continously improve the ccxp-persona from the decisions, and then refactor the logic from the persona into skills, and refactor skills from md into scripts."

Baseline (measured 2026-11-24 on main at 13cf8ac):

- Persona `agent-pairing/assets/ccxp-agent.md`: 48481 B, 232 lines; bats cap 48500 B (`tests/agent_pairing.bats`, 2 places), so 19 B of headroom.
- Largest persona sections: HUD job ledger 7934 B, Consent 5212 B, Ledger 3354 B, Writing a job prompt 3219 B, Resume 2921 B, Repo context 2741 B, Terms 2552 B, CI failure response 2439 B, Detached jobs 2303 B, Decisions log 1583 B, Slack alerts 1345 B, Repo freshness 1343 B, Routines due 1011 B, Idle wake 471 B.
- SKILL.md prose: drive 694 L / 74633 B, ccxp 647 L / 63904 B, retro 617 L / 48157 B, address-pr 369 L / 37747 B, autopilot 193 L / 24794 B (its script `autopilot-state.sh` is already 1072 L).
- Already in place: persona-side docs `alerts.md`, `bg-jobs.md`, `decisions.md`, `idle-wake.md`, `rituals.md`, `terms.md` and scripts `alerts-due.sh`, `job-launch.sh`, `job-status.sh`, `terms.sh`, `idle-wake.sh`; the persona repeats part of what they say.

Targets (revise with evidence, never silently):

- After the retro step: persona unchanged; `retro/SKILL.md` grows at most 15 lines (logic lives in `retro/scripts/persona-review.sh`).
- After the first persona move: persona at most 46500 B. After the second: at most 41500 B. Epic goal: at most 40000 B (-17%) with every kept rule still present (bats key-rule test).
- Skills: each skill task states its own before/after lines of prose and the number of new script tests; autopilot Phase 3/4 first, then the address-pr gate steps and drive phases.

Constraints:

- The installed persona refreshes itself after a plugin update (`agent-pairing/persona-refresh.md`: hook compares the bundled asset, backs up, replaces). A smaller persona needs no change there; a rule moved into a doc reaches a running session only after that refresh plus a restart, and the pointer must name the doc and the command so the agent finds it.
- Persona behaviour stays identical: every move adds or extends a bats test that the asset stays under the cap and that the key rules still appear.
- Persona edits and decision changes (`decision add/retire/supersede`) only with the owner's agreement; the retro step proposes, never applies.
- Input from the prior read-only review, job #1456 (32 decisions: 3 persona additions d147/d129/d96, 7 retire/fold, 5 profile/config, 11 keep-in-log, 5 already covered, 1 contradiction d101/d112): report `r1456-decisions-review-report.md` kept in the owner's local ccxp-context directory (not in the repo).
- Pending follow-ups from that review: n384 (d101 kept, d112 retired by the owner on 2026-11-24); d147, d129, d96 persona additions wait for trims from the persona moves below.
- Later clusters to file after the second persona move, from the section sizes above: CI failure response and Repo freshness, HUD job ledger, Consent, Writing a job prompt; further skills (ccxp, retro, ipm, todo) by the same ranking.

- [T20261124-147908](../TODO/T20261124-147908-retro-persona-review-step-and-script.md) — retro step and `persona-review.sh`: classify decisions, propose persona edits
- [T20261124-420719](../TODO/T20261124-420719-persona-move-alerts-routines-idle-wake-to-docs.md) — persona move 1: alerts, routines due, idle wake become pointers
- [T20261124-315192](../TODO/T20261124-315192-persona-move-detached-jobs-decisions-terms-to-skill.md) — persona move 2: detached jobs, decisions log, terms become pointers
- [T20261124-870400](../TODO/T20261124-870400-autopilot-phase-3-4-prose-to-scripts.md) — autopilot Phase 3/4 classification and housekeeping dispatch into scripts
- [T20261124-444596](../TODO/T20261124-444596-address-pr-gates-and-drive-phases-prose-to-scripts-survey.md) — address-pr gate steps and drive phases: survey, then first script
