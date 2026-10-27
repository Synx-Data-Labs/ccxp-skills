# ccxp-agent: resolve the target repo per job and load its CLAUDE.md

- **Why**: owner's ask, "for our own ccxp-agent, it should always load the claude.md for each dispatched job, this will require the ccxp-agent knows which repo the job will run under"
  - A subagent starts in the dispatcher's cwd and loads only that repo's CLAUDE.md hierarchy (`Explore`/`Plan` skip it)
  - The Agent tool has no cwd parameter, and a `cd` inside the job's Bash call neither persists nor loads the other repo's CLAUDE.md or settings
  - `isolation: "worktree"` only makes a worktree of the dispatcher's own repo
- **What** (`agent-pairing/assets/ccxp-agent.md`): new `## Repo context per job` section
  - Resolve the repo before dispatch: user's message, else session cwd's repo, else an optional registry (`~/.claude/ccxp-repos.json`, not built); ambiguous means one question. Resolve to clone path plus `owner/repo` via read-only `git` checks, and record the repo in the ledger row
  - Every job prompt starts with a repo block (`Repo:`, `Path:`, "Before anything else, Read <path>/CLAUDE.md ..."), plus a `gh` account hint (`.envrc` `GH_CONFIG_DIR`, else verify with `gh auth status`)
  - The dispatcher only `ls`-verifies the file and never reads it into its own context; the job reads it
  - Other-repo repo-changing jobs get no dispatch-level `isolation`; the job makes its own worktree from the target clone. The same-repo hard rule is unchanged
  - Skill-driven jobs and detached jobs get the block too; multi-repo requests get one job (or one block) per repo
- **Tests**: three new cases in `tests/agent_pairing.bats` assert the section, the block wording, the light-dispatcher rule, the worktree form and the surviving hard rule
- **Rollout**: an installed profile keeps the old definition until `agent-pairing update`, and takes effect at the next session start
- **Version**: new backward-compatible behavior = MINOR; the bump is a separate maintainer PR per `dev/guidelines.md`
