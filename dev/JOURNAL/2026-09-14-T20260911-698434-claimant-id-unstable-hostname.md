---
status: Done
estimation: 1d
source: consumer-repo session, 2026-09-09 — discovered while running /address-pr on a multi-account clone
related: T20260911-140914
scheduled: 2026-09-14
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

- **Format** — `claimed_by: cc1-<machine-id>:<path-hash>`. `<machine-id>`
  is 8 hex, random, cached at `~/.claude/state/machine-id` (mirrors
  `session_cc_session_id`'s `${raw:0:8}` convention in `_lib.sh`);
  `<path-hash>` is 16 hex of `sha256(secret ‖ clone-path)`. The `cc1-`
  version marker rides *inside* the host field rather than being a field
  of its own, which preserves the historical two-field `<host>:<path>`
  shape — see "Format alternatives" below, this is the whole reason the
  format looks like this.
- **Secret** — a separate per-machine random value at
  `~/.claude/state/claimant-secret`, mode 600, never committed. The path
  hash is salted with the *secret*, not `<machine-id>`: `<machine-id>` is
  published in the claim string, so salting with it would leave the clone
  path brute-forceable from a guessed username list.
- **`hostname` is no longer consulted**, which is what removes the drift
  this task was filed for. `session_machine()` loses its only caller.
- **Two fields, not one hash** — keeping `<machine-id>` visible as its own
  field is load-bearing, not cosmetic: `_tc_is_own_cross_repo_clone` needs "same
  machine, different clone" to remain decidable (see below). A single
  combined hash would make that feature impossible.
- **Reclaim** — add an arm to `_tc_reclaim_decide`'s `case`
  (`task_claim.sh:256`) matching the **anchored** shape
  `^cc1-[0-9a-f]{8}:[0-9a-f]{16}$`, not a `cc1-*` glob, so a real hostname
  that happens to start with `cc1-` can never be mistaken for the new
  format independently of arm ordering. Keep `*:/*` and
  `^[0-9a-fA-F]{6,}@` for legacy. Without the new arm a `cc1-` value
  matches neither existing shape and falls to the human-override arm,
  making every claim **permanently unreclaimable**.
- **Reader before writer** — the `cc1-` arm lands as an earlier, separate
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
  not `cc1-`-shaped, so every pre-migration retro still attributes
  correctly without touching git history.
- **Cross-repo ownership** — `_tc_is_own_cross_repo_clone` (`task_claim.sh:595`, parsing at
  `:613-614`)
  does `claim_host="${claimed_by%%:*}"` / `claim_path="${claimed_by#*:}"`.
  Because `cc1-` lives inside the host field, `claim_host` evaluates to
  `cc1-<machine-id>` — still distinct per machine — so **the host
  comparison needs no change at all** and the "a foreign host is never
  mine" guard keeps working. Only the tail needs fixing: `my_path` is now
  a hash, so `basename "$my_path"` can no longer match
  `<task-id>-*-target` and the function would return 1 always, regressing
  cross-repo PRs to the exact `owned:` deferral T20260626-195977 fixed.
  Take the real local clone path from `session_clone_path()` for that
  check instead of parsing it back out of the id. (Under the rejected
  `cc1:<mid>:<hash>` spelling `claim_host` would have collapsed to the
  literal `cc1` for every claim, silently voiding the guard — the reason
  the format changed.)
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
- **Board and logs** — `sync.py:758` projects `cc1-<machine-id first 6>`
  plus the role instead of the raw value; `reclaim_sweep.sh:98`'s log line
  follows suit.

### Format alternatives considered

Recorded so this is not relitigated. The constraint that decides it: the
frontmatter is parsed by real YAML (`sync.py:643`, `lint_tasks.py:54` both
call `yaml.safe_load`), the value is grepped as a regex by the statusline,
and it is passed as a shell word in test fixtures.

| candidate | verdict |
|---|---|
| `cc1:<mid>:<hash>` | rejected — `${v%%:*}` collapses to `cc1` for every claim, silently voiding `_tc_is_own_cross_repo_clone`'s foreign-host guard |
| `[cc1] <mid>:<hash>` | rejected — **`yaml.safe_load` raises `ParserError`** (`[cc1]` opens a flow sequence), breaking board sync and the task linter on every claimed task; `[`/`]` are also regex-special and the statusline's escaper only escapes `\` and `.`; the space invites word-splitting in unquoted fixtures |
| `cc1@<mid>:<hash>` | viable — parses, discriminates, no regex-special chars. Rejected only to keep `@` meaning exactly one thing (the legacy `<sid>@<machine>` shape). Note `^[0-9a-fA-F]{6,}@` matches any 6+ hex-char prefix, so `ccdef1@…` *would* hit the legacy arm — `cc1@` is safe only by being 3 characters |
| `cc1-<mid>:<hash>` | **chosen** — preserves the two-field `<host>:<path>` shape, parses as a plain YAML string, no whitespace, no regex-special characters, and leaves `@` unambiguous |

### Full change surface

Identity is constructed in 3 places and parsed in 2. Constructed:
`_lib.sh:97,99`, `task_claim.sh:105`, `statusline-command.sh:19`. Parsed:
`attribution.sh:114`, `task_claim.sh:613-614`. Also touched: `claim_gap.sh`,
`reclaim_sweep.sh`, `sync.py`, `lint_tasks.py` (allow `claimed_role`), and
the docs that pin the format — `_session/README.md` (5 sites),
`claim/SKILL.md`, `address-pr/SKILL.md`, `drive/SKILL.md`, `ccxp/SKILL.md`,
`glossary.md`, `statusline-setup/SKILL.md`, `templates/task.md`.

Tests: one new suite (`tests/claimant_id.bats`) plus migrations and
additions in `tests/task_claim.bats`, `tests/statusline_setup.bats`,
`tests/attribution.bats`, `tests/reclaim_sweep.bats`,
`tests/claim_gap.bats`, `tests/session_lib.bats` and
`actions/sync-tasks/test_sync.py` — see the Test Plan for what each gains.

### Test Plan

The existing suites are strong on behaviour but share one blind spot:
**every suite hardcodes a plaintext claimant fixture** (`h:/p` in
`task_claim.bats`, `cdw:/tmp/...` in the cross-repo cases,
`"$(hostname):$repo"` in `statusline_setup.bats`, `cdw:/home/ci/...` in
`test_sync.py`). If production starts emitting `cc1-…` and the fixtures
are not migrated with it, every suite stays green while testing a format
nothing writes. Migrating fixtures is therefore part of the work, not a
follow-up — and the contract test below is what stops them drifting again.

Worth recording honestly: the cross-repo anti-steal direction is already
well covered (`task_claim.bats:560,567,603,611`). Once its fixtures are on
the new format those tests *do* catch the vacuous-host-guard failure — but
only after the `basename` half is fixed, because a broken `basename` check
fails closed and masks it. That interaction is why the rejected
`cc1:<mid>:<hash>` spelling was dangerous rather than merely wrong.

**New suite — `tests/claimant_id.bats`** (no existing home; the helpers
land in `_lib.sh`):

- `_tc_claimant_id` output matches `^cc1-[0-9a-f]{8}:[0-9a-f]{16}$` — the
  **format contract** every other suite's fixtures are validated against
- stable across calls in one clone; unchanged when `hostname` changes
  mid-flight (the original drift repro); distinct for two clones on one
  machine
- `machine-id` and the secret are generated once and reused; the secret
  file is mode 600 and never equals `machine-id`
- unwritable `~/.claude/state/` → claim aborts non-zero with a readable
  message (fail-closed), and writes no `claimed_by`
- the portable sha256 helper agrees across `shasum -a 256`, `sha256sum`
  and `openssl dgst -sha256`, and still works with any one of them absent
  from `PATH`
- **privacy guard**: a written `claimed_by` matches none of
  `/Users/`, `/home/`, `\.ts\.net`, or `$(hostname)` — the test that
  stops this leak returning
- **YAML guard**: the written frontmatter line round-trips through
  `yaml.safe_load` as a plain string — the test that would have caught the
  `[cc1] <mid>:<hash>` spelling, which no suite could see today

**Extended — `tests/task_claim.bats`** (42 `claimed_by` refs to migrate):

- a `cc1-` claim is subject to the staleness window; a bare human name
  still never auto-reclaims; legacy `h:/p` and `deadbeef@box` classify
  exactly as before
- a legacy plaintext claim whose host half begins `cc1-` is **not**
  mistaken for the new format (guards the anchored-shape decision)
- migration: a legacy claim whose path half matches re-stamps to `cc1-`
  and reads as mine; a non-matching path half still refuses
- cross-repo cases 560/567/603/611 re-fixtured onto `cc1-`, keeping both
  the positive and the two anti-steal negatives

**Extended — `tests/statusline_setup.bats`** (6 hardcoded format sites):

- **cross-check**: `sl-clone-id` output equals `_tc_claimant_id` output —
  the assertion that makes the duplicate implementation safe, and the one
  thing the current suite structurally cannot do

**Extended — `tests/attribution.bats`**:

- `cc1-` + `claimed_role: ccxp` → `ccxp`; missing role → `interactive`
- a historical plaintext value still resolves via the first-colon path
  fallback (protects every pre-migration retro)

**Extended — `actions/sync-tasks/test_sync.py`**:

- `claimed_by` projection emits the short `cc1-<machine-id first 6>` plus
  role, and still clears to empty on release

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
across 9 source files, 1 new and 7 migrated test suites, and 8 documents, with
`tests/task_claim.bats` alone carrying 42 `claimed_by` references and
`tests/statusline_setup.bats` 6 hardcoded format sites.

## Done criteria

- [x] `_tc_claimant_id()` no longer consults `hostname`, and no written
      `claimed_by` contains a hostname, username, or filesystem path
- [x] `cc1-` claims are auto-reclaimable; human overrides still never are
- [x] Cross-repo `pr-owner` still reports `mine` for the ephemeral target
      clone, and `owned:` for a foreign machine
- [x] Legacy plaintext claims self-heal on first touch; no operator step
- [x] Statusline resolves the claimed task, with a cross-check test
      pinning it to `_tc_claimant_id`
- [x] Claiming fails closed, loudly, when `~/.claude/state/` is unwritable
- [x] `tests/claimant_id.bats` exists and pins the format contract, the
      privacy guard and the YAML guard; no suite still asserts against a
      plaintext claimant fixture

## Outcome

Landed on `main` in three sequenced commits (reader, writer, presentation +
docs), later squashed into `2afef98` by the pre-publication history rewrite.

### Fix

`claimed_by` is now `cc1-<machine-id>:<path-hash>`. `<machine-id>` is random
and cached in `~/.claude/state/machine-id`, so `hostname` is never consulted
and drift cannot reach it; `<path-hash>` is `sha256(secret ‖ clone-path)`
salted with a separate local secret. Nothing derived from the machine name,
the OS user or the filesystem path is written to a task file any more.

The reader landed first, deliberately: `_tc_reclaim_decide` classifies an
unrecognised shape as a human override that is NEVER auto-reclaimable, so
had the writer gone first every claim would have become permanently
unreclaimable. That arm is marked in-code as a one-way door.

### What the grill caught that the original sketch missed

- **Shape detection.** A `cc1-` value matches neither `*:/*` nor the legacy
  `hex@` arm. Without a new arm, every claim strands.
- **Cross-repo guard.** `_tc_is_own_cross_repo_clone` splits `claimed_by` on
  the first `:`. Under the rejected `cc1:<mid>:<hash>` spelling that yields
  the literal `cc1` for every claim, voiding the foreign-machine guard. The
  chosen spelling keeps the marker inside the host field so the guard needs
  no change at all — only the ephemeral-target check needed the real local
  path.
- **Second implementation.** `statusline-command.sh` reimplemented the format,
  coupled only by a comment, and fails silently on a mismatch while its own
  tests pinned the old shape against itself. Both now source one definition.
- **YAML.** `sync.py` and `lint_tasks.py` both `yaml.safe_load` the
  frontmatter. The `[cc1] <mid>:<hash>` candidate raises `ParserError` and
  would have broken board sync on every claimed task, invisibly to bats.

### Files changed

| File | Change |
|------|--------|
| `_session/claimant-id.sh` | **new** — the single definition of the identity; side-effect-free so the statusline can source it per prompt render |
| `_session/task_claim.sh` | `_tc_claimant_id` rewrite; `cc1-` reclaim arm; cross-repo `$4`; legacy-claim carve-out; `claimed_role` write/clear |
| `_session/attribution.sh` | consume `claimed_role`; keep path parsing for pre-migration history |
| `_session/claim_gap.sh` | adopt the portable sha256 helper (bare `sha256sum` is GNU-only) |
| `_session/reclaim_sweep.sh` | render the claimant via `claimant_display` |
| `statusline-setup/scripts/statusline-command.sh` | source the shared definition instead of reimplementing it |
| `actions/sync-tasks/sync.py` | `claim_display()`; project short form + role; `claimed_role` scalar key |
| `repo-conventions/scripts/lint_tasks.py` | allow `claimed_role` |
| `tests/claimant_id.bats` | **new** — format contract, privacy guard, YAML guard, fail-closed, portability |
| `tests/task_claim.bats` | migrate fixtures off plaintext; reclaim, migration, cross-repo cases |
| `tests/statusline_setup.bats` | cross-check `sl-clone-id` == `_tc_claimant_id` |
| `tests/attribution.bats` | role plus legacy path fallback |
| `actions/sync-tasks/test_sync.py` | projection + `claim_display` shapes |
| 9 documents | `_session/README.md` (reasoning, not just the string), `claim`, `address-pr`, `drive`, `ccxp`, `glossary`, `statusline-setup`, `templates/task.md` |

574 bats assertions pass, python suites green, doc lint clean.

### Bugs found by running the code, not reasoning about it

- `local name="$1" file="$DIR/$name"` silently yields an empty `$name` — bash
  expands every word of a `local` before assigning any of them.
- `shasum` prints `<hash>  -`, so `awk '{print $NF}'` grabs the dash.
- `env PATH=… bash` cannot find `bash` under the restricted PATH.

### Next steps

- Board/log rendering now exists in bash and Python. A cross-language test
  pins them together; if a third consumer appears, that pairing needs
  revisiting.
- The migration carve-out matches on clone path alone (it cannot compare
  hostnames — drift is the bug). Two machines sharing an identical clone path
  can each read the other's legacy claim as their own during the migration
  window. Merge-to-`main` still arbitrates, so this changes who wins a race,
  not whether the lock holds. Window closes once every claim is re-stamped.
