#!/usr/bin/env bats
# Tests for _taskid/url.sh — task ID -> clickable GitHub URL, map-free.
#
# T20260610-023106 retired the .github/task-issue-map.json sidecar: the blob
# path is now resolved by globbing dev/{TODO,PARKING,JOURNAL}/ in the cwd repo
# (zero network), and the issue number via `gh issue list --search` (the bot
# issue's body carries the task-file permalink, so body search matches even
# issues whose titles lack the ID).
#
# We exercise the production functions directly by sourcing the script (the CLI
# dispatch at the bottom is guarded by BASH_SOURCE[0] == $0, so sourcing is
# side-effect-free). I/O is hermetic: a throwaway git repo in $BATS_TEST_TMPDIR
# supplies `origin` and the dev/ fixture tree; `gh` is a PATH stub.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/_taskid/url.sh"

  # Hermetic repo so `git remote get-url origin` resolves a known slug.
  cd "$BATS_TEST_TMPDIR"
  git init -q .
  git remote add origin https://github.com/your-org/build-pipeline-repo.git

  # Fixture task files — the glob source of truth.
  mkdir -p dev/TODO dev/PARKING dev/JOURNAL
  touch dev/TODO/T20260427-298901-registry-egress-cost-reduction.md
  touch dev/JOURNAL/2026-05-29-T20260320-000026-widgetdb-docker-image.md

  # gh stub injected via TASKID_GH (the helper's DI seam — a PATH stub would
  # be bypassed by the default _gh/gh.sh wrapper). Individual tests overwrite
  # the stub to simulate no-match / failure.
  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "900"
STUB
  chmod +x bin/gh
  export TASKID_GH="$BATS_TEST_TMPDIR/bin/gh"
}

# --- slug derivation --------------------------------------------------------

@test "taskid-repo-slug strips https scheme/host/.git to owner/repo" {
  run taskid-repo-slug
  [ "$status" -eq 0 ]
  [ "$output" = "your-org/build-pipeline-repo" ]
}

@test "taskid-repo-slug handles ssh (git@) remotes" {
  git remote set-url origin git@github.com:your-org/ccxp-skills.git
  run taskid-repo-slug
  [ "$output" = "your-org/ccxp-skills" ]
}

@test "sourcing helper does not mutate caller shell options" {
  run bash -c 'set +u +o pipefail; source "'"$REPO_ROOT"'/_taskid/url.sh"; shopt -qo nounset; echo nounset:$?; shopt -qo pipefail; echo pipefail:$?'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nounset:1"* ]]
  [[ "$output" == *"pipefail:1"* ]]
}

# --- blob (default) URL: resolved by glob, no map, no network ----------------

@test "taskid-url returns a blob link to the current TODO path via glob" {
  run taskid-url T20260427-298901
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/your-org/build-pipeline-repo/blob/main/dev/TODO/T20260427-298901-registry-egress-cost-reduction.md" ]
}

@test "taskid-url finds a moved (JOURNAL) file with its date prefix" {
  # The whole point: a closed task lives under JOURNAL, and the link follows it.
  run taskid-url T20260320-000026
  [[ "$output" == *"/blob/main/dev/JOURNAL/2026-05-29-T20260320-000026-widgetdb-docker-image.md" ]]
}

@test "taskid-url prefers TODO over JOURNAL when both match (abnormal state)" {
  touch dev/JOURNAL/2026-06-01-T20260427-298901-registry-egress-cost-reduction.md
  run taskid-url T20260427-298901
  [[ "$output" == *"/blob/main/dev/TODO/"* ]]
}

@test "taskid-url blob mode ignores a leftover sidecar map" {
  # Regression guard for the retirement: a stale committed map (pointing at a
  # path the file has left) must not win over the live glob.
  mkdir -p .github
  echo '{"T20260427-298901": {"issue": 1, "path": "dev/JOURNAL/stale.md"}}' > .github/task-issue-map.json
  run taskid-url T20260427-298901
  [[ "$output" == *"/blob/main/dev/TODO/T20260427-298901-registry-egress-cost-reduction.md" ]]
}

@test "taskid-url blob mode makes no gh calls" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "gh must not be called in blob mode" >&2
exit 1
STUB
  chmod +x bin/gh
  run taskid-url T20260427-298901
  [ "$status" -eq 0 ]
  [[ "$output" == *"/blob/main/dev/TODO/"* ]]
}

@test "TASKID_URL_BRANCH overrides the blob branch" {
  TASKID_URL_BRANCH=release run taskid-url T20260427-298901
  [[ "$output" == *"/blob/release/dev/TODO/"* ]]
}

# --- issue URL: resolved via gh search --------------------------------------

@test "taskid-url --issue returns the stable issue URL from gh search" {
  run taskid-url T20260427-298901 --issue
  [ "$output" = "https://github.com/your-org/build-pipeline-repo/issues/900" ]
}

@test "taskid-url --issue falls back to code-search when gh finds nothing" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x bin/gh
  run taskid-url T20260427-298901 --issue
  [ "$status" -eq 0 ]
  [[ "$output" == *"/search?q=repo:"* ]]
}

@test "taskid-url --issue falls back to code-search when gh is unavailable" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
exit 4
STUB
  chmod +x bin/gh
  run taskid-url T20260427-298901 --issue
  [ "$status" -eq 0 ]
  [[ "$output" == *"/search?q=repo:"* ]]
}

# --- unmapped fallback ------------------------------------------------------

@test "taskid-url falls back to code-search when no task file matches" {
  run taskid-url T20990101-999999
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/search?q=repo:your-org/build-pipeline-repo+T20990101-999999&type=code" ]]
}

# --- Slack mrkdwn wrapper ---------------------------------------------------

@test "taskid-slacklink wraps the URL in Slack mrkdwn <url|TID>" {
  run taskid-slacklink T20260427-298901
  [ "$status" -eq 0 ]
  [ "$output" = "<https://github.com/your-org/build-pipeline-repo/blob/main/dev/TODO/T20260427-298901-registry-egress-cost-reduction.md|T20260427-298901>" ]
}

@test "taskid-slacklink --issue wraps the issue URL" {
  run taskid-slacklink T20260427-298901 --issue
  [ "$output" = "<https://github.com/your-org/build-pipeline-repo/issues/900|T20260427-298901>" ]
}

# --- zsh portability --------------------------------------------------------

@test "helper works when sourced from zsh (PATH-tied 'path' var, no compgen)" {
  # ccxp sources this helper in the interactive session shell, which is zsh on
  # macOS. Two zsh-only hazards are guarded here: `local path` clobbers the
  # PATH-tied array (commands vanish mid-function), and compgen doesn't exist.
  command -v zsh >/dev/null || skip "zsh not available"
  run zsh -c 'source "'"$REPO_ROOT"'/_taskid/url.sh"; taskid-url T20260427-298901'
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/your-org/build-pipeline-repo/blob/main/dev/TODO/T20260427-298901-registry-egress-cost-reduction.md" ]]
}

# --- error handling ---------------------------------------------------------

@test "taskid-url errors on missing ID" {
  run taskid-url
  [ "$status" -eq 2 ]
}

# --- markdown link wrapper (T20260608-353422) -------------------------------
# Digest docs (ipm-weekly.md, retro-weekly.md) are written once and never
# regenerated, so a blob-mode link baked in at write time can still rot if the
# referenced task later moves. taskid-mdlink defaults to --issue mode (never
# rots) unlike taskid-slacklink, which defaults to blob (fine for a same-day
# Slack message, read before a move is likely).

@test "taskid-mdlink defaults to a stable issue-mode link" {
  run taskid-mdlink T20260427-298901
  [ "$status" -eq 0 ]
  [ "$output" = "[T20260427-298901](https://github.com/your-org/build-pipeline-repo/issues/900)" ]
}

@test "taskid-mdlink --blob uses the current-path blob link instead" {
  run taskid-mdlink T20260427-298901 --blob
  [ "$status" -eq 0 ]
  [ "$output" = "[T20260427-298901](https://github.com/your-org/build-pipeline-repo/blob/main/dev/TODO/T20260427-298901-registry-egress-cost-reduction.md)" ]
}

@test "taskid-mdlink falls back to code-search when the issue can't be found" {
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x bin/gh
  run taskid-mdlink T20260427-298901
  [ "$status" -eq 0 ]
  [[ "$output" == "[T20260427-298901](https://github.com/search?q=repo:"* ]]
}

@test "taskid-mdlink errors on missing ID" {
  run taskid-mdlink
  [ "$status" -eq 2 ]
}
