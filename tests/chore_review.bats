#!/usr/bin/env bats
# Tests for retro/scripts/chore-review.sh — /retro's chore-index review step
# (build-pipeline-repo T20260608-246336). Repo-agnostic: a repo without
# dev/chore.md must be a clean no-op for both subcommands.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/retro/scripts/chore-review.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK/dev"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name tester
}

commit_dated() {
  local d="$1" msg="$2"
  git -C "$WORK" add -A
  GIT_AUTHOR_DATE="${d}T12:00:00" GIT_COMMITTER_DATE="${d}T12:00:00" \
    git -C "$WORK" commit -q -m "$msg"
}

@test "list-due: no dev/chore.md -> clean no-op" {
  run bash "$SCRIPT" list-due --repo-root "$WORK" --today 2026-07-02
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list-due: selects a row >= 1 iteration old with a blank Outcome" {
  cat > "$WORK/dev/chore.md" <<'EOF'
# Chore index

| Goal | Task | Started | Outcome |
|------|------|---------|---------|
| Due chore, no outcome yet | [T20260601-111111](https://example.com/1) | 2026-06-01 | |
EOF
  run bash "$SCRIPT" list-due --repo-root "$WORK" --today 2026-07-02
  [ "$status" -eq 0 ]
  [[ "$output" == *"T20260601-111111"* ]]
  [[ "$output" == *"Due chore, no outcome yet"* ]]
}

@test "list-due: excludes a row started less than 1 iteration ago" {
  cat > "$WORK/dev/chore.md" <<'EOF'
# Chore index

| Goal | Task | Started | Outcome |
|------|------|---------|---------|
| Too new | [T20260628-222222](https://example.com/2) | 2026-06-30 | |
EOF
  run bash "$SCRIPT" list-due --repo-root "$WORK" --today 2026-07-02
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list-due: excludes a row with an already-recorded verdict" {
  cat > "$WORK/dev/chore.md" <<'EOF'
# Chore index

| Goal | Task | Started | Outcome |
|------|------|---------|---------|
| Already evaluated | [T20260501-333333](https://example.com/3) | 2026-05-01 | **Kept** — done |
EOF
  run bash "$SCRIPT" list-due --repo-root "$WORK" --today 2026-07-02
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan-untracked: no dev/chore.md -> clean no-op" {
  run bash "$SCRIPT" scan-untracked --repo-root "$WORK" --since 2026-06-10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan-untracked: flags a process doc with no matching chore.md row" {
  cat > "$WORK/dev/chore.md" <<'EOF'
# Chore index

| Goal | Task | Started | Outcome |
|------|------|---------|---------|
| Tracked chore | [T20260601-111111](https://example.com/1) | 2026-06-01 | |
EOF
  commit_dated 2026-06-01 "seed chore.md"

  printf '# Some policy\nReferences T20260601-111111 as the tracked chore.\n' > "$WORK/dev/some-policy.md"
  commit_dated 2026-06-15 "add tracked policy doc"

  printf '# An untracked process change\nNo chore.md row for this.\n' > "$WORK/dev/untracked-policy.md"
  commit_dated 2026-06-20 "add untracked policy doc"

  run bash "$SCRIPT" scan-untracked --repo-root "$WORK" --since 2026-06-10
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev/untracked-policy.md"* ]]
  [[ "$output" != *"dev/some-policy.md"* ]]
}

@test "scan-untracked: ignores dev/TODO, dev/JOURNAL, dev/PARKING, and dev/chore.md itself" {
  mkdir -p "$WORK/dev/TODO" "$WORK/dev/JOURNAL" "$WORK/dev/PARKING"
  cat > "$WORK/dev/chore.md" <<'EOF'
# Chore index

| Goal | Task | Started | Outcome |
|------|------|---------|---------|
| Tracked chore | [T20260601-111111](https://example.com/1) | 2026-06-01 | |
EOF
  printf '# A task\n' > "$WORK/dev/TODO/T20260620-999999-x.md"
  printf '# A journal entry\n' > "$WORK/dev/JOURNAL/2026-06-20-T20260620-888888-y.md"
  printf '# A parked task\n' > "$WORK/dev/PARKING/T20260620-777777-z.md"
  commit_dated 2026-06-20 "add task/journal/parking files + chore.md"

  run bash "$SCRIPT" scan-untracked --repo-root "$WORK" --since 2026-06-10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan-untracked: --since is required (usage error, exit 2)" {
  run bash "$SCRIPT" scan-untracked --repo-root "$WORK"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand -> usage error (exit 2)" {
  run bash "$SCRIPT" bogus-command --repo-root "$WORK"
  [ "$status" -eq 2 ]
}
