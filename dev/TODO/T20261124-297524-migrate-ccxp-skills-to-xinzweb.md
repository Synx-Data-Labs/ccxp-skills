---
status: Open
estimation: 1
needs: [owner-decision]
source: owner request, job 1545, 2026-11-24
description: Publish the latest ccxp-skills as a new public repo under the xinzweb user and freeze the Synx-Data-Labs one (not authorized to start until the owner says go)
---

# T20261124-297524: Move ccxp-skills development to a new public xinzweb/ccxp-skills repo

## Problem

- **Type**: chore
- **Owner's words**: "for the ccxp-skills, create a new task, that I want to migrate it from synx-data-labs/ org to xinzweb/ tag."
  - "tag" is read as a typo for org/account; the owner later confirmed: "xinzweb is a user."
  - **NOT AUTHORIZED TO START until the owner says go.** Filing this task changes nothing on GitHub.
- **Not a GitHub transfer.** Owner: "The existing repo still kept under SYNX, but just no longer updated. I will put latest and greatest under xinzweb."
  - `Synx-Data-Labs/ccxp-skills` stays, frozen; archiving it later only if the owner says so.
  - The latest lives in a NEW repo `xinzweb/ccxp-skills` (user account).
- **Goal**: marketplace users, the HUD and the release flow all work from `xinzweb/ccxp-skills`, and the old repo points there.

## Decided by the owner (quoted)

- **Account**: "xinzweb is a user."
- **Ownership, IP, licence**: "it's an open project, and it's not limited to SYNX. you can check the license in that repo."
  - Verified: `LICENSE` is Apache-2.0, and `plugin.json` says `"license": "Apache-2.0"`. It has no copyright line naming Synx, only the standard boilerplate and appendix.
  - Still names Synx and needs review before going public (names of places, not findings): `plugin.json` and `marketplace.json` author/owner `Synx Data Labs`, `README.md`, `hud/scripts/hud-nightly.sh` and `hud/show.ts` (default nightly repo `Synx-Data-Labs/synxdb-build-pipeline`), `customer-support/`, `labrun-rca/`, `address-pr/scripts/auto-pick.sh`, `drive/SKILL.md`, several `dev/TODO` and `dev/JOURNAL` files that mention synxdb/hashdata.
- **Visibility**: "it will be public." The repo is already public today.
- **Marketplace**: "I want to publish this plugin to claude code marketplace if possible."
- **Secrets**: "secrets are still only stored in 1password, and github app, we need to assess what are the github dependencies to keep it under xinzweb."
- **Release tags**: "release tags same as before" (`ccxp-skills--v<version>`).
- **HUD**: "HUD version URL will be reflected to the xinzweb one after migration."
- **Old repo**: stays under Synx-Data-Labs, no longer updated; it gets a README pointer to the new repo (not done by this task until the owner says go).

## Checklist (read-only assessment first; nothing here is started)

- **Consumer repos (optional, later, NOT a migration blocker)**: a consumer is any other repo or machine that installs or references the plugin, for example a Claude settings entry that adds the marketplace, or a repo whose docs, hooks or scripts hardcode the repo URL or plugin cache path.
  - Owner: "then, "consumer repos", won't be affected. They still point to a valid plugin, but just frozen."
  - The old repo stays valid but frozen, so existing consumers keep working; only consumers that want updates must repoint to `xinzweb/ccxp-skills` (settings marketplace or plugin source, hardcoded URLs).
  - Information only, read-only grep results to list when convenient: `extraKnownMarketplaces` and plugin sources pointing at `Synx-Data-Labs/ccxp-skills`, repos such as `synxdb-build-pipeline` that hardcode the URL or cache path, CI that checks out the plugin.
  - Known inside this repo: `README.md` (`/plugin marketplace add Synx-Data-Labs/ccxp-skills`).
- **Public hygiene before the new repo is created**
  - Run the repo's sensitivity and secrets checks (`/secrets-check`, `synx-skills:sensitivity-audit`, the CI identifier check) over the full history, not only the tip.
  - Never print or save findings that contain secrets; record counts and file names only.
  - Decide per Synx-named item above: keep, generalise or remove; decide whether to push full history or a squashed one.
- **Claude Code marketplace publishing: find out what it needs**
  - Verified locally: `.claude-plugin/marketplace.json` has `name`, `owner`, `description` and one plugin with `"source": "./"`; `plugin.json` has `name`, `version` (6.7.0), `author`, `homepage`, `repository`, `license`, `keywords`.
  - Unknown, to verify with the `claude-code-guide` agent or the official docs: whether there is a central listing or submission process, required manifest fields, review or naming rules, and what version/tag convention the marketplace expects.
  - Record what was verified and what stayed unknown, with sources.
- **GitHub dependency assessment (do not read secret values)**
  - List every dependency and what it needs to be recreated under a user account (a user account has no org-level secrets; Apps must be installed on the new repo):
    - Actions secrets: workflows reference `INTERNAL_IDENTIFIERS` and `INTERNAL_PRIVATE_REPOS` in `.github/workflows/tests.yml`; unset is a silent no-op there. Check repo-level and org-level secrets by name only.
    - GitHub Apps and installations: `synx-merge-bot` (approval gate, `address-pr/scripts/approve-dispatch.sh`, `_gh/gh-app-token.sh`); `GH_APP_ID` and its key come from 1Password. The App must be installed on the new repo, or replaced.
    - Workflow permissions (both workflows use `contents: read`), `CODEOWNERS`, branch protection (none seen on `main` today), runners, Pages, release automation, org-only features.
- **Tags and releases**: existing tags and releases must reach the new repo. Options, owner to choose:
  - push all tags with the full history, then re-create the GitHub Releases;
  - push history and re-tag selected versions with the same `ccxp-skills--v<version>` names;
  - start the new repo at the current version and leave history tags in the old repo.
- **HUD and manifest URL**: the HUD version cell and the unreleased-commits lookup derive the URL from the manifest `repository` (else `homepage`), so after the move the manifest points at the xinzweb repo. Files to change:
  - `.claude-plugin/plugin.json` (`repository`, `homepage`, `author.url`) and `.claude-plugin/marketplace.json` (`owner.url`);
  - `hud/scripts/hud-version.sh` (`HVR_REMOTE_DEFAULT`), `hud/model.ts` (`PLUGIN_URL_DEFAULT`), `hud/README.md`, `tests/hud_version.bats`;
  - `README.md` install line, plus any `hud/` or test fixtures found by grep.
- **Other items**: CI and open issues/PRs (issues and PRs do not move to a new repo: decide whether to leave them in the old repo or recreate), and which `gh` profile (`xinzweb` or `75033us`) jobs use; local clones and remotes under `~/workspace/synx-data-labs/`.

## Suggested step order (once the owner says go)

- **Prepare**
  - Owner go; answer the open choices (history vs squash, tag option, Synx-named items).
  - Run the assessments above; fix or generalise what must change before going public.
- **Create**
  - Create `xinzweb/ccxp-skills` (public), push history and tags per the chosen option; set up secrets via 1Password and install the App.
  - Land the manifest and HUD URL changes there, run CI, cut a release `ccxp-skills--v<version>`.
- **Switch**
  - Test `/plugin marketplace add xinzweb/ccxp-skills` and update from a clean and an existing install; repoint consumers later, only those that want updates.
  - Try the marketplace listing once the publishing requirements are known.
- **Freeze**: put a README pointer in the old repo, stop updating it; archive only if the owner says so. Then journal this task.

## Rollback

- Nothing in the old repo is removed or renamed, so it keeps working as the fallback until the owner says otherwise.
- If the new repo is bad, point the manifests, HUD default and consumer entries back at `Synx-Data-Labs/ccxp-skills` (revert the PRs) and keep developing there; the new repo can be made private or deleted by the owner.
- Keep a `git clone --mirror` of the old repo and the inventory of secrets and App installs (names only).
