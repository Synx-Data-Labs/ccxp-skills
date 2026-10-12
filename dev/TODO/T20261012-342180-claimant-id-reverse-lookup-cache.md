---
status: Open
estimation: 1
source: this conversation, 2026-10-12
---

# T20261012-342180: Local reverse-lookup cache for claimant ids (who owns what on this box)

## Problem

- **Type**: feature
- Verified: `claimed_by` is `cc1-<machine-id>:<path-hash>` (`_session/claimant-id.sh:90-96`, wrapped by `_tc_claimant_id` at `_session/task_claim.sh:106`).
  - The machine-id half is stable per box (`claimant_machine_id`, `claimant-id.sh:83`).
  - The path half is a 16-hex hash of the clone path keyed with a per-machine secret (`claimant_secret`, `claimant-id.sh:84`), so it cannot be recomputed from outside the box and is opaque even on it.
- Verified: `pr-owner` prints `owned:<claimed_by>` (`task_claim.sh:947`) and `/todo list`'s Claimed column shows the raw value (`lifecycle.md:102`). Nobody can tell which clone, repo, branch or session holds a claim.
- Verified: `_tc_is_own_cross_repo_clone` (`task_claim.sh:860`) already needs the real clone path passed separately, because the hash cannot be read back.
- Wanted: on one dev box, resolve a claimant id to clone path / repo / branch, so "who owns what" is answerable locally.

## Proposed design (not decided; open for grilling)

- **Cache file**: machine-local JSON (or JSONL), claimant-id -> `{clone_path, repo_slug, branch, last_seen, session_label?, host}`.
  - Location under the Claude profile dir, honoring `CLAUDE_CONFIG_DIR` (default `~/.claude`), e.g. `$CLAUDE_CONFIG_DIR/ccxp/claimants.json`.
  - Never inside a repo, never committed, mode 600.
- **Write side**: populated lazily when `task_claim.sh claimant-id` / `acquire` computes the id from a path.
  - Idempotent upsert, atomic write (temp file + rename, flock or mkdir lock) so parallel sessions cannot corrupt it.
  - Refresh `last_seen` on each acquire/read.
- **Read side**: new `task_claim.sh whois <claimant-id>` (maybe also `mine` / `list-local`).
  - Resolves an id from `claimed_by` or `owned:` output to path/repo/branch.
  - Optional enrichment: scan claimed tasks across known clone paths for claimant -> tasks currently claimed.
  - Possibly surface the resolved path in `/todo list`'s Claimed column and in address-pr's `owned:` deferral message.
- **Staleness**: entries whose path no longer exists are flagged, and removed by `--prune`.
  - Foreign-machine ids are unresolvable locally and report "unknown (other host)" rather than failing.

## Open questions

- Which profile dir wins when several exist (`~/.claude` vs `~/.claude-personal`)?
- Record Claude session name/pid for live-vs-dead? Real liveness checking (`ListAgents`-like) is out of scope.
- Cross-repo ephemeral target clones (basename `<task-id>-*-target`) should map back to their hub task.
- Relationship to the reclaim sweep (`reclaimable`, `task_claim.sh:642`): should a missing path feed reclaim decisions, or stay purely informational?

## Done criteria

- bats tests for: upsert idempotency, concurrent writers, `whois` hit / miss / foreign host, `CLAUDE_CONFIG_DIR` override, `--prune`.
- Docs in `_session/README.md` and the lifecycle/todo docs.
