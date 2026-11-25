---
name: nightly-rca
description: Use when a nightly or scheduled pipeline run is red and the cause may be an upstream input that moved (manifest pin, submodule gitlink, mirror branch) rather than our own code — investigate read-only and write a fixed-structure briefing
argument-hint: "<run-id|run-url> [--repo owner/repo]"
---

# /nightly-rca

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

The deeper step after `/nightly-check`, `/labrun-rca` and `/rca`: those find and diagnose the failed run; this one answers "which input moved since the last green run, and who owns the fix". It encodes the recipe of the 2026-11-04/05 red-nightly investigation.

## Argument

- `<run-id|run-url>`: the failed run (a URL is reduced to the id after `/runs/`, never a trailing `/job/<id>`). `--repo owner/repo`: default the working repo (`gh repo view --json nameWithOwner`).

## Rules

- Read-only: no workflow re-run, no push, no tag, no post, no ping. Drafts only, in the briefing.
- Verify every actor claim against run logs and the GitHub activity API. A mirror branch is usually pushed by the sync workflow with one shared SSH key, so GitHub shows one account: never name a person.
- State corrections to earlier claims in the briefing (for example "queued ~8 h, not hung").
- Never open an issue on a `hashdata-*` mirror repo; the upstream issue is drafted for `synx-skills:upstream-issue` (a `dev_collaboration` ticket).
- GitLab and Nexus need the VPN (`/synx-skills:vpn`); without it, skip those checks and say so.

## Workflow

Helpers: `bash <skills-root>/nightly-rca/scripts/nightly-rca.sh <subcommand>` (see its header; tests `tests/nightly_rca.bats`).

1. **Announcement**: read the Slack alert thread when there is one (`slack_read_thread`, read-only), then run `/rca <id> --repo <repo> --no-post`. Do not run `/labrun-rca` here: it replies in the thread, which this skill never does (`/nightly-check` owns that path). Keep the failing job and step.
2. **Classify**: `gh run view <id> --repo <repo> --json name,conclusion,createdAt,startedAt,updatedAt,jobs > $RUN`, then `nightly-rca.sh classify $RUN`. `queued` (long wait, no conclusion), `running`, `hung` and `other` (skipped, startup_failure) are different from `failed`; report queue time apart from run time, and the failing job and step.
3. **Last green and input diff**:
   - `nightly-rca.sh last-green <repo> <workflow file> <run id>` gives the previous green run and its head SHA.
   - Diff the inputs between the two SHAs: `git show <sha>:manifests/<m>.yml` for both, then `nightly-rca.sh pin-diff old.yml new.yml`; also compare submodule gitlinks per component (for example lightning to arrow) and prepared-branch divergence (`prepared/upstream` against `upstream`).
   - For every changed or suspicious pin run `nightly-rca.sh sha-reachable <mirror owner/repo> <branch> <sha>` against the mirror's real branch (check the repo's default branch; a missing branch exits 3). `missing` or `unreachable` is the squash/rebase-rewrite signature (an MR head SHA is gone after the merge). Confirm against GitLab `refs/merge-requests/*/head` when the VPN is up.
   - Find who pushes the branch: the sync workflow's runs and `gh api repos/<r>/activity`, not commit authors.
4. **Swallowed errors**: grep the prepare and build scripts the failing step runs for `2>/dev/null`, `|| true` and `|| echo`; compare with pre-fix history (`git log -S`, `git show <fix>^:<path>`).
5. **Artifacts**: releases are in Cloudsmith; Nexus holds only conan dependencies and images, no lightning or synxdb4 artifacts. Check the right store for what the run should have produced.
6. **Briefing**: `nightly-rca.sh briefing <run id> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-context"` writes the skeleton (mode 600); fill verdict with confidence, timeline, flow diagram, options and who to ask (a role, not a name), plus the draft upstream issue. No secrets, masked long strings.
7. **Report** the briefing path and the one-line verdict to the caller. Filing follow-up tasks is `/rca`'s procedure; never duplicate a task for a run id already tracked.

## Important Notes

- Task: T20261105-423915 (hub: synxdb-build-pipeline). Worked example: run 41982384896 (`Upstream Prepare`, step `Phase 1.5: Commit`), lightning pin 8065acd9 absent from the arrow mirror's `upstream` branch.
