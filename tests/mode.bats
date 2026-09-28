#!/usr/bin/env bats
# Tests for repo-conventions/scripts/mode.sh — switches a repo's Branch and
# Merge Policy section between solo/team wording and applies the matching
# GitHub branch-protection API state (DELETE for solo, PUT for team).
#
# GH_SH is stubbed to a fake script that records every invocation's args (and
# stdin, for the PUT body) to a file, so tests never call real GitHub.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODE_SH="$REPO_ROOT/repo-conventions/scripts/mode.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev"
  CALLS="$BATS_TEST_TMPDIR/gh_calls.log"
  GH_STUB="$BATS_TEST_TMPDIR/gh_stub.sh"
  cd "$WORK"
}

# Default stub: records "ARGS: ..." (+ "STDIN: ..." when input is piped) per
# invocation, exits 0, and answers `repo view` so --repo can be omitted.
mk_gh_stub() {
  cat > "$GH_STUB" <<STUB
#!/usr/bin/env bash
{
  echo "ARGS: \$*"
  if [ ! -t 0 ]; then
    echo "STDIN:"
    cat
  fi
  echo "---"
} >> "$CALLS"
if [[ "\$*" == *"repo view"* ]]; then
  echo "test-org/test-repo"
fi
exit 0
STUB
  chmod +x "$GH_STUB"
}

mk_team_doc() {
  cat > "$WORK/dev/guidelines.md" <<'EOF'
# Developer Guidelines

## Branch and Merge Policy

The `main` branch is the source of truth. Never push directly to `main`.

1. **Create a feature branch** — all changes go through a feature branch, no exceptions
2. **Branch naming**: `t{task-id}-short-description` for tracked tasks; `fix/`, `feat/`, `docs/` prefixes for untracked work
3. **Open a PR** — clear summary and test plan
4. **CI must pass** — all checks green before merge
5. **Merge method** — rebase and merge
6. **Delete the branch after merge**

## TODO Lifecycle

placeholder
EOF
}

mk_solo_doc() {
  cat > "$WORK/dev/guidelines.md" <<'EOF'
# Developer Guidelines

## Branch and Merge Policy

This is a solo repo with no CI — direct-to-main, no feature-branch PRs required.

1. **Push directly to `main`** — no feature branch or PR required

## TODO Lifecycle

placeholder
EOF
}

@test "team on a solo-mode doc rewrites to team wording and calls PUT" {
  mk_gh_stub
  mk_solo_doc
  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -q "CI must pass" "$WORK/dev/guidelines.md"
  grep -q "PUT" "$CALLS"
  grep -q "branches/main/protection" "$CALLS"
  # assert the actual JSON body, not just that a PUT happened
  grep -q '"required_approving_review_count": 0' "$CALLS"
  grep -q '"enforce_admins": false' "$CALLS"
  grep -q '"restrictions": null' "$CALLS"
}

@test "solo on a team-mode doc rewrites to solo wording and calls DELETE" {
  mk_gh_stub
  mk_team_doc
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -qi "no ci" "$WORK/dev/guidelines.md"
  grep -qi "direct.to.main" "$WORK/dev/guidelines.md"
  grep -q "DELETE" "$CALLS"
  grep -q "branches/main/protection" "$CALLS"
}

@test "team errors with no CI workflows and no --skip-ci-check, doc untouched, no API call" {
  mk_gh_stub
  mk_solo_doc
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
  grep -qi "no ci" "$WORK/dev/guidelines.md"
}

@test "team proceeds with --skip-ci-check despite no workflows" {
  mk_gh_stub
  mk_solo_doc
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes --skip-ci-check
  [ "$status" -eq 0 ]
  grep -q "PUT" "$CALLS"
}

@test "requesting the mode already in effect is a no-op: no rewrite, no API call" {
  mk_gh_stub
  mk_team_doc
  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  before="$(cat "$WORK/dev/guidelines.md")"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/dev/guidelines.md")" = "$before" ]
  [ ! -s "$CALLS" ]
}

@test "prefers dev/guidelines.md over CLAUDE.md when both have a Policy heading" {
  mk_gh_stub
  mk_team_doc
  cat > "$WORK/CLAUDE.md" <<'EOF'
# Test repo

## Branch and Merge Policy

placeholder team text — should NOT be touched
EOF
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -qi "no ci" "$WORK/dev/guidelines.md"
  ! grep -qi "no ci" "$WORK/CLAUDE.md"
}

@test "falls back to CLAUDE.md when dev/guidelines.md has no Policy heading" {
  mk_gh_stub
  cat > "$WORK/dev/guidelines.md" <<'EOF'
# Guidelines
no policy section here
EOF
  cat > "$WORK/CLAUDE.md" <<'EOF'
# Test repo

## Branch and Merge Policy

The `main` branch is the source of truth. Never push directly to `main`.

1. **Create a feature branch**
2. **Branch naming**
3. **Open a PR**
4. **CI must pass**
5. **Merge method**
6. **Delete the branch after merge**
EOF
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -qi "no ci" "$WORK/CLAUDE.md"
}

@test "missing Policy heading in both files is a hard error, no API call" {
  mk_gh_stub
  echo "# no policy" > "$WORK/dev/guidelines.md"
  echo "# no policy" > "$WORK/CLAUDE.md"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --repo test-org/test-repo --yes
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "solo tolerates a 404 (no existing protection) as success" {
  cat > "$GH_STUB" <<STUB
#!/usr/bin/env bash
echo "ARGS: \$*" >> "$CALLS"
echo "gh: Branch not protected (HTTP 404: Not Found)" >&2
exit 1
STUB
  chmod +x "$GH_STUB"
  mk_team_doc
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -qi "no ci" "$WORK/dev/guidelines.md"
}

@test "team fails hard on a genuine (non-404) API error, doc left untouched" {
  cat > "$GH_STUB" <<STUB
#!/usr/bin/env bash
echo "ARGS: \$*" >> "$CALLS"
echo "gh: HTTP 403: Forbidden" >&2
exit 1
STUB
  chmod +x "$GH_STUB"
  mk_solo_doc
  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes
  [ "$status" -ne 0 ]
  grep -qi "no ci" "$WORK/dev/guidelines.md"
}

@test "without --yes and non-interactive stdin, refuses to mutate" {
  mk_gh_stub
  mk_solo_doc
  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo < /dev/null
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "--doc overrides the target file explicitly" {
  mk_gh_stub
  mkdir -p "$WORK/other"
  mk_team_doc
  cp "$WORK/dev/guidelines.md" "$WORK/other/policy.md"
  # blank out dev/guidelines.md's Policy heading so the default resolution
  # would fail — proves --doc, not the default, is what got used
  echo "# no policy" > "$WORK/dev/guidelines.md"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" solo --doc "$WORK/other/policy.md" --repo test-org/test-repo --yes
  [ "$status" -eq 0 ]
  grep -qi "no ci" "$WORK/other/policy.md"
}

@test "a doc-rewrite failure AFTER a successful API call is a hard error, not silent success" {
  mk_gh_stub
  mk_solo_doc
  mkdir -p "$WORK/.github/workflows"
  touch "$WORK/.github/workflows/ci.yml"
  chmod 444 "$WORK/dev/guidelines.md"
  run env GH_SH="$GH_STUB" bash "$MODE_SH" team --repo test-org/test-repo --yes
  chmod 644 "$WORK/dev/guidelines.md"
  [ "$status" -ne 0 ]
  # the API call still happened (protection state and doc are now out of
  # sync, by construction of this test) — the failure must be reported,
  # never swallowed into a false success
  grep -q "PUT" "$CALLS"
}

@test "missing mode argument is a usage error" {
  run bash "$MODE_SH"
  [ "$status" -ne 0 ]
}

@test "invalid mode argument is a usage error" {
  run bash "$MODE_SH" bogus
  [ "$status" -ne 0 ]
}
