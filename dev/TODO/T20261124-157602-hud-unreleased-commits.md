---
status: Open
estimation: 1
source: owner request, job 1462, 2026-11-24
type: feature
---

# T20261124-157602: HUD shows unreleased commits after the plugin repo URL

## Problem

- **Type**: feature
- Owner's words: "maybe in the hud, you can actually show the commits after the current version? (right after the URL of the plugin github repo?)"
- The HUD already shows the plugin repo URL (`hud/model.ts` `PLUGIN_URL_DEFAULT`, version data from `hud/scripts/hud-version.sh`).
- Add right after that URL the commits on origin/main after the release tag `ccxp-skills--v<installed version>`: a count plus up to 3 short subjects and "+N more".
- Computed by a script in `hud/scripts/` with bats tests; TTL-cached and never blocking (no per-render git fetch or gh call); silent when offline, tag not found, or zero unreleased commits; works from the installed plugin cache (no git checkout).
- Update `hud/README.md` and the HUD help text. No version bump, tag or release.
