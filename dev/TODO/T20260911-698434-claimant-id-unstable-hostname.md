---
status: Open
estimation: 1d
source: consumer-repo session, 2026-09-09 — discovered while running /address-pr on a multi-account clone
related: T20260911-140914
---

# T20260911-698434: `_tc_claimant_id()` uses bare `hostname`, which can drift on the same machine

## Problem

- `_session/_lib.sh`'s `session_machine() { hostname; }` — used by
  `_session/task_claim.sh`'s `_tc_claimant_id()` to build the
  `<machine>:<working-dir>` identity that `claimed_by` is stamped with
  and compared against — returns whatever the OS's `hostname` command
  currently resolves to. That value is **not stable across time on the
  same physical machine**: it depends on which naming system currently
  wins (mDNS/Bonjour `<name>.local`, a VPN/mesh-network's own DNS such as
  Tailscale's MagicDNS `<name>.<tailnet>.ts.net`, plain `ComputerName`,
  etc.), and can change when new networking software is installed or
  reconfigured — with no code change and no new session involved.
- Observed failure: a task's `claimed_by` was stamped
  `<machine>.local:/Users/<user>/workspace/<org>/<repo>` at
  claim time. Later, on the exact same machine, exact same working
  directory, running `hostname` returned
  `<machine>-1.<tailnet>.ts.net` instead (Tailscale had been set up
  in the interim). `task_claim.sh pr-owner <pr>` computed `_tc_claimant_id()`
  fresh each call, got the new hostname, compared it against the stored
  `<machine>.local:...`, found no match, and returned
  `owned:<machine>.local:...` — a **false "owned by another agent"**
  verdict against the task's own rightful, currently-active owner.
- This directly defeats the anti-steal purpose `pr-owner` exists for
  (T20260622-404636): a false `owned:` reading either wrongly blocks the
  real owner (if followed literally) or, if routinely overridden by
  hand, erodes trust in the guard for the cases where it's protecting
  against a genuine other agent.

## Context

- `_tc_claimant_id()`'s own comment calls itself "Stable across CC
  invocations in the SAME clone" — true for the working-dir half
  (`session_clone_path()`, via `git rev-parse --show-toplevel`), false
  for the machine half whenever the OS's hostname resolution changes.
- No corroborating signal (a stored machine UUID, `ioreg` hardware
  identifier, etc.) is consulted — `hostname` is the sole source of
  truth for "which machine is this."
- Confirmed via `task_claim.sh reclaimable <id>` returning `live` (not
  stale) at the time of the false-positive — the tool's own staleness
  heuristic already knew the claim was active, just not that it was
  active *by the same machine* under a different name.

## Design

Settled in a `/grill-me` pass (3 frontier rounds). Supersedes the earlier
"Solution (proposed)" sketch: option 1 (cached stable machine id) is adopted
and extended to also remove the PII the old identity leaked into a
soon-to-be-public repo.

### Decisions

- **Format** — `claimed_by: cc1:<machine-id>:<path-hash>`. `cc1:` is a
  versioned prefix; `<machine-id>` is 8 hex, random, cached at
  `~/.claude/state/machine-id` (mirrors `session_cc_session_id`'s
  `${raw:0:8}` convention in `_lib.sh`); `<path-hash>` is 16 hex of
  `sha256(secret ‖ clone-path)`.
- **Secret** — a separate per-machine random value at
  `~/.claude/state/claimant-secret`, mode 600, never committed. The path
  hash is salted with the *secret*, not `<machine-id>`: `<machine-id>` is
  published in the claim string, so salting with it would leave the clone
  path brute-forceable from a guessed username list.
- **`hostname` is no longer consulted**, which is what removes the drift
  this task was filed for. `session_machine()` loses its only caller.
- **Three components, not one hash** — keeping `<machine-id>` separately
  visible is load-bearing, not cosmetic: `_tc_cross_repo_mine` needs
  "same machine, different clone" to remain decidable (see below). A
  single combined hash would make that feature impossible.
- **Reclaim** — add an explicit `cc1:*` arm to `_tc_reclaim_decide`'s
  `case` (`task_claim.sh:256`), keeping `*:/*` and `^[0-9a-fA-F]{6,}@`
  for legacy. Without it a `cc1:` value matches neither shape and falls to
  the human-override arm, making every claim **permanently
  unreclaimable**.
- **Reader before writer** — the `cc1:` arm lands as an earlier, separate
  commit than the code that writes the new format, and carries an in-code
  comment marking it a one-way door: reverting the writer is safe,
  reverting both silently strands every live claim.
- **Attribution** — new `claimed_role: ccxp|interactive` frontmatter
  field, written at acquire and cleared at release exactly like
  `claimed_by`. Derived at claim time from whether the clone path is in
  `ATTRIBUTION_CCXP_PATHS` (already loaded from `~/.claude/.env`,
  `attribution.sh:51`), so there is one source of truth and no caller
  changes. Hashing `ATTRIBUTION_CCXP_PATHS` at compare time was rejected:
  with a per-machine secret the standup machine cannot reproduce another
  machine's path hash.
- **Historical attribution** — `attribution.sh:114` keeps its existing
  first-colon path parsing as a fallback whenever the recovered value is
  not `cc1:`-shaped, so every pre-migration retro still attributes
  correctly without touching git history.
- **Cross-repo ownership** — `_tc_cross_repo_mine` (`task_claim.sh:613`)
  currently does `claim_host="${claimed_by%%:*}"` /
  `claim_path="${claimed_by#*:}"`. Under the new format `claim_host`
  becomes the literal `cc1` for *every* claim, so the "a foreign host is
  never mine" guard goes vacuous, and `basename "$my_path"` can no longer
  match `<task-id>-*-target`, so the function returns 1 always and
  cross-repo PRs regress to the exact `owned:` deferral T20260626-195977
  fixed. Rewrite it to compare the `<machine-id>` component and to take
  the real local clone path from `session_clone_path()` rather than
  parsing it back out of the hashed id.
- **Migration** — carve-out in `_tc_acquire`'s `other` branch: a legacy
  `<host>:<path>` claim whose path half equals my clone path is treated as
  mine and re-stamped. `main` carries zero live claims today, so this repo
  needs no operator step; consumer repos self-heal on first touch.
- **Hashing portability** — portable helper in `_lib.sh`
  (`shasum -a 256` → `sha256sum` → `openssl dgst -sha256`). It runs on
  every claim, so a missing binary would break all claiming.
  `claim_gap.sh:87`'s bare `sha256sum` (GNU-only; broken on macOS without
  coreutils) is refactored onto the same helper.
- **Failure mode** — if `~/.claude/state/` is unwritable, the claim
  **fails closed** with a readable message. Never fall back to plaintext
  (reintroduces the leak); never use an ephemeral secret (the agent stops
  recognising its own claims — the very false-`owned:` failure this task
  exists to kill, made permanent).
- **Statusline** — `statusline-command.sh:19` is a *second, independent*
  implementation of the format, coupled to the canonical one only by a
  comment, and `sl-claimed-task-label` returns empty on no-match, so a
  stale copy renders identically to "no task claimed". Its bats cases
  (`tests/statusline_setup.bats:71,87,102,117,132,215`) pin the old format
  against itself and would stay green while the feature silently broke.
  In scope: update the script, and add a **cross-check test asserting
  `sl-clone-id` equals `_tc_claimant_id`** so any future divergence fails
  loudly.
- **Board and logs** — `sync.py:758` projects `cc1:<machine-id first 6>`
  plus the role instead of the raw value; `reclaim_sweep.sh:98`'s log line
  follows suit.

### Full change surface

Identity is constructed in 3 places and parsed in 2. Constructed:
`_lib.sh:97,99`, `task_claim.sh:105`, `statusline-command.sh:19`. Parsed:
`attribution.sh:114`, `task_claim.sh:613-614`. Also touched: `claim_gap.sh`,
`reclaim_sweep.sh`, `sync.py`, `lint_tasks.py` (allow `claimed_role`), and
the docs that pin the format — `_session/README.md` (5 sites),
`claim/SKILL.md`, `address-pr/SKILL.md`, `drive/SKILL.md`, `ccxp/SKILL.md`,
`glossary.md`, `statusline-setup/SKILL.md`, `templates/task.md`.

### Test Plan

- **Identity**: stable across calls in one clone; unchanged when
  `hostname` changes mid-flight (the original drift repro); distinct for
  two clones on one machine
- **Reclaim**: a `cc1:` claim is subject to the staleness window; a bare
  human name still never auto-reclaims; legacy `h:/p` and `deadbeef@box`
  classify exactly as before
- **Cross-repo**: same machine-id + ephemeral `<task-id>-*-target` clone
  reads `mine`; a foreign machine-id in the same ephemeral clone reads
  `owned:` (guards the vacuous-host-check regression)
- **Migration**: a legacy claim whose path half matches re-stamps to
  `cc1:` and reads as mine; a non-matching path half still refuses
- **Attribution**: `cc1:` + `claimed_role: ccxp` → `ccxp`; a historical
  plaintext value still resolves via the path fallback; missing role →
  `interactive`
- **Statusline**: cross-check test asserts `sl-clone-id` output equals
  `_tc_claimant_id` output
- **Failure**: unwritable `~/.claude/state/` aborts the claim non-zero
  with a readable message
- **Privacy regression guard**: assert no written `claimed_by` matches
  `/Users/|/home/|\.ts\.net|$(hostname)` — the test that stops this
  leak returning

### Open

- A second Claude config dir (e.g. `~/.claude-personal`) keeps its own
  `settings.json`, so its statusline updates independently. Self-correcting
  on pull; the cross-check test cannot span config dirs.
- Whether to ever sunset the legacy `*:/*` and `hex@` arms — no reason to
  decide now, and the `hex@` arm from T20260615-169917 is the precedent
  for keeping them indefinitely.
- A team-shared salt, only if cross-machine clone identification is ever
  wanted. The `claimed_role` decision removed the current need.

### Out of scope

- Rewriting git history to purge existing plaintext `claimed_by` values —
  attribution deliberately still reads them
- The human-assignee `owner:` field
- Any other PII surface in the repo

Estimation revised from 1h to 1d: the grill settled the design but the
surface is far wider than the original bug implied — 2 sequenced commits
across 9 source files plus 7 test files and 8 documents, with
`tests/task_claim.bats` alone carrying 42 `claimed_by` references and
`tests/statusline_setup.bats` 6 hardcoded format sites.

## Done criteria

- [ ] `_tc_claimant_id()` no longer consults `hostname`, and no written
      `claimed_by` contains a hostname, username, or filesystem path
- [ ] `cc1:` claims are auto-reclaimable; human overrides still never are
- [ ] Cross-repo `pr-owner` still reports `mine` for the ephemeral target
      clone, and `owned:` for a foreign machine
- [ ] Legacy plaintext claims self-heal on first touch; no operator step
- [ ] Statusline resolves the claimed task, with a cross-check test
      pinning it to `_tc_claimant_id`
- [ ] Claiming fails closed, loudly, when `~/.claude/state/` is unwritable
