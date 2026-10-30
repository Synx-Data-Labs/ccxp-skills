#!/usr/bin/env bats
# Tests for gcpr/scripts/gcpr-prep.sh (the mechanical prep behind /gcpr and its
# alias /land) and the thin structure of land/SKILL.md. Offline: fixture git
# repos under $BATS_TEST_TMPDIR, the shared fake gh (GCPR_GH=gh resolves to the
# PATH shim). Nothing here commits to a real repo, pushes or opens a PR; the
# script has no such verb. Secret-looking strings are built at runtime.

load test_helper
PREP="$REPO_ROOT/gcpr/scripts/gcpr-prep.sh"
WRAP="$REPO_ROOT/land/SKILL.md"

setup() {
  R="$(make_fixture_repo "$BATS_TEST_TMPDIR/repo")"
  cd "$R"
  FX="$BATS_TEST_TMPDIR/ghfx"; mkdir -p "$FX"
  fake_gh "$FX"
  export GCPR_GH=gh
}

_prep() { run bash "$PREP" "$@"; }
_commit() { git add -A && git commit -q -m "$1"; }
_ghp() { printf 'ghp_'; printf 'a1B2c3D4e5%.0s' 1 2 3 4; }       # 4+40 chars
_aws() { printf 'AK''IA'; printf 'Q%.0s' $(seq 16); }

# ---- assess ----------------------------------------------------------------

@test "assess: clean main -> clean-main, exit 3, no gh call" {
  _prep assess
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATE=clean-main"* ]]
  refute_calls "$FAKE_GH_LOG" '^pr list'
}

@test "assess: uncommitted changes -> dirty, exit 0, untracked counted" {
  echo x > new.txt; echo y >> dev/TODO/queue.md
  _prep assess
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE=dirty"* ]]
  [[ "$output" == *"DIRTY=2"* ]]
}

@test "assess: dirty on a feature branch is still dirty (no PR lookup)" {
  git checkout -q -b feat/x; echo x > new.txt
  _prep assess
  [[ "$output" == *"STATE=dirty"* ]]
  refute_calls "$FAKE_GH_LOG" '^pr list'
}

@test "assess: feature branch with no commits ahead -> clean-no-commits, exit 3" {
  git checkout -q -b feat/x
  _prep assess
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATE=clean-no-commits"* ]]
}

@test "assess: commits ahead and no PR -> ahead-no-pr" {
  git checkout -q -b feat-x; echo a > a.txt; _commit a
  : > "$FX/pr_list_head_feat_x.txt"
  _prep assess
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE=ahead-no-pr"* ]]
  [[ "$output" == *"AHEAD=1"* ]]
  assert_calls "$FAKE_GH_LOG" '^pr list --head feat-x --state all'
}

@test "assess: commits ahead and an existing PR -> ahead-pr:<n>" {
  git checkout -q -b feat-x; echo a > a.txt; _commit a
  echo 7 > "$FX/pr_list_head_feat_x.txt"
  _prep assess
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE=ahead-pr:7"* ]]
  [[ "$output" == *"PR=7"* ]]
}

@test "assess: a gh failure is never read as 'no PR' (exit 4, STATE=unknown)" {
  git checkout -q -b feat-x; echo a > a.txt; _commit a
  export FAKE_GH_FAIL='^pr list'
  _prep assess
  [ "$status" -eq 4 ]
  [[ "$output" == *"STATE=unknown"* ]]
  [[ "$output" != *"ahead-no-pr"* ]]
}

@test "assess: detached HEAD, unknown base, bad flag and non-repo all exit 2" {
  git checkout -q --detach; _prep assess; [ "$status" -eq 2 ]
  git checkout -q main; _prep assess --base nope; [ "$status" -eq 2 ]
  _prep assess --bogus; [ "$status" -eq 2 ]
  _prep assess --base; [ "$status" -eq 2 ]
  cd "$BATS_TEST_TMPDIR" && mkdir plain && cd plain && _prep assess; [ "$status" -eq 2 ]
}

# ---- changed / lint -----------------------------------------------------------

@test "changed: resolves renames, skips deletions, lists untracked files individually" {
  mkdir -p dev/TODO dev/JOURNAL dev/PARKING docs
  echo a > docs/old.md; echo b > docs/gone.md; echo c > notes.txt
  _commit seed
  git mv docs/old.md docs/new.md; git rm -q docs/gone.md
  echo t > dev/TODO/T20000101-000001-x.md; echo j > dev/JOURNAL/j.md
  echo p > dev/PARKING/p.md; echo z >> notes.txt
  _prep changed md
  [ "$(printf '%s\n' "$output" | sort | paste -sd' ' -)" = "dev/JOURNAL/j.md dev/PARKING/p.md dev/TODO/T20000101-000001-x.md docs/new.md" ]
  _prep changed tasks
  [ "$(printf '%s\n' "$output" | sort | paste -sd' ' -)" = "dev/PARKING/p.md dev/TODO/T20000101-000001-x.md" ]
  _prep changed refs
  [ "$(printf '%s\n' "$output" | sort | paste -sd' ' -)" = "dev/JOURNAL/j.md dev/TODO/T20000101-000001-x.md" ]
}

@test "changed: paths with spaces survive, bad kind exits 2, no changes prints nothing" {
  _prep changed md; [ "$status" -eq 0 ]; [ -z "$output" ]
  mkdir -p "a b"; echo x > "a b/c d.md"
  _prep changed md; [ "$output" = "a b/c d.md" ]
  _prep changed bogus; [ "$status" -eq 2 ]
  _prep changed; [ "$status" -eq 2 ]
}

@test "lint: runs only over changed files and always exits 0 (check-then-continue)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$REPO_ROOT/tests/fixtures/lint-docs/fake-markdownlint-cli2.sh" "$BATS_TEST_TMPDIR/bin/markdownlint-cli2"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_MDL_CALLLOG="$BATS_TEST_TMPDIR/mdl.log"
  echo untouched > keep.md; _commit seed
  echo '# changed' > changed.md
  printf -- '---\nstatus: Open\n---\n\n# T20000101-000001: x\n' > dev/TODO/T20000101-000001-x.md
  _prep lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT md=2 tasks=1 refs=1"* ]]
  grep -q 'changed.md' "$FAKE_MDL_CALLLOG"
  ! grep -q 'keep.md' "$FAKE_MDL_CALLLOG"
}

@test "lint: with nothing to lint prints zero counts and exits 0" {
  _prep lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"LINT md=0 tasks=0 refs=0"* ]]
}

# ---- branch-name ---------------------------------------------------------------

@test "branch-name: <type>/<slug>, lowercased, punctuation collapsed, 40 char cap" {
  _prep branch-name fix "Conan Profile: mismatch (arm64)!"
  [ "$output" = "fix/conan-profile-mismatch-arm64" ]
  _prep branch-name docs "$(printf 'word %.0s' $(seq 30))"
  [ "$status" -eq 0 ]
  slug="${output#docs/}"
  [ "${#slug}" -le 40 ]
  [[ "$slug" != *- ]]
}

@test "branch-name: unknown type, empty slug and missing text exit 2" {
  _prep branch-name wip hello; [ "$status" -eq 2 ]
  _prep branch-name fix '!!!'; [ "$status" -eq 2 ]
  _prep branch-name fix; [ "$status" -eq 2 ]
}

@test "branch-name --check: accepts a valid name, rejects the base, bad refs and leading dash" {
  _prep branch-name --check t63-conan-fix; [ "$status" -eq 0 ]
  _prep branch-name --check main; [ "$status" -eq 1 ]
  _prep branch-name --check master; [ "$status" -eq 1 ]
  _prep branch-name --check develop --base develop; [ "$status" -eq 1 ]
  _prep branch-name --check 'a b'; [ "$status" -eq 1 ]
  _prep branch-name --check 'a..b'; [ "$status" -eq 1 ]
  _prep branch-name --check -x; [ "$status" -eq 1 ]
  _prep branch-name --check; [ "$status" -eq 2 ]
}

# ---- review-flip -----------------------------------------------------------------

_task() { printf -- '---\nestimation: 1\nstatus: %s\n---\n\n# T20000101-000001: x\n\nstatus: In Progress in the body stays\n' "$1" > dev/TODO/T20000101-000001-x.md; }

@test "review-flip: In Progress -> Review, only in the frontmatter" {
  _task "In Progress"
  _prep review-flip T20000101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == "FLIPPED dev/TODO/T20000101-000001-x.md" ]]
  grep -q '^status: Review$' dev/TODO/T20000101-000001-x.md
  grep -q '^status: In Progress in the body stays$' dev/TODO/T20000101-000001-x.md
}

@test "review-flip: --dry-run changes nothing" {
  _task "In Progress"
  _prep review-flip T20000101-000001 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == WOULD-FLIP* ]]
  grep -q '^status: In Progress$' dev/TODO/T20000101-000001-x.md
}

@test "review-flip: other statuses and a missing file are a no-op (exit 3)" {
  for s in Open Design Review Done; do
    _task "$s"
    _prep review-flip T20000101-000001
    [ "$status" -eq 3 ]
    grep -q "^status: $s\$" dev/TODO/T20000101-000001-x.md
  done
  _prep review-flip T20000101-000009
  [ "$status" -eq 3 ]
}

@test "review-flip: CRLF and quoted status values are handled" {
  printf -- '---
status: "In Progress"
---

# x
' > dev/TODO/T20000101-000001-x.md
  _prep review-flip T20000101-000001
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p dev/TODO/T20000101-000001-x.md | tr -d '\r')" = "status: Review" ]
  [ "$(tr -cd '\r' < dev/TODO/T20000101-000001-x.md | wc -c | tr -d ' ')" -eq 5 ]
}

@test "review-flip: second run is a no-op; bad id and ambiguous match exit 2" {
  _task "In Progress"
  _prep review-flip T20000101-000001; [ "$status" -eq 0 ]
  _prep review-flip T20000101-000001; [ "$status" -eq 3 ]
  _prep review-flip T1; [ "$status" -eq 2 ]
  _prep review-flip; [ "$status" -eq 2 ]
  _task "In Progress"; cp dev/TODO/T20000101-000001-x.md dev/TODO/T20000101-000001-y.md
  _prep review-flip T20000101-000001; [ "$status" -eq 2 ]
}

# ---- secrets-check -----------------------------------------------------------------

@test "secrets-check: clean changes -> SECRETS=clean, exit 0" {
  echo "just prose, token rotation is documented elsewhere" > a.md
  echo "KEY=op://vault/item/field" > .env.tpl
  _prep secrets-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRETS=clean files=2"* ]]
}

@test "secrets-check: a staged .env is blocked by name" {
  echo "A=1" > .env; git add .env
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK .env env-file"* ]]
  [[ "$output" == *"SECRETS=blocked"* ]]
}

@test "secrets-check: credential-like names are blocked, templates and pubkeys are not" {
  mkdir -p .aws sub
  : > .aws/credentials; : > sub/server.pem; : > sub/id_ed25519; : > .env.production
  : > .env.example; : > sub/id_ed25519.pub; : > .env.tpl
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK .aws/credentials credential-file"* ]]
  [[ "$output" == *"BLOCK sub/server.pem key-or-state-file"* ]]
  [[ "$output" == *"BLOCK sub/id_ed25519 ssh-private-key"* ]]
  [[ "$output" == *"BLOCK .env.production env-file"* ]]
  [[ "$output" != *".env.example"* ]]
  [[ "$output" != *"id_ed25519.pub"* ]]
  [[ "$output" != *".env.tpl"* ]]
}

@test "secrets-check: token-shaped content is blocked with file:line and rule, never the value" {
  tok="$(_ghp)"; aws="$(_aws)"
  printf 'line1\nexport T=%s\n' "$tok" > a.sh
  printf 'k = %s\n' "$aws" > b.txt
  printf -- '-----BEGIN RSA PRIVATE %s-----\n' KEY > c.txt
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK a.sh:2 github-token"* ]]
  [[ "$output" == *"BLOCK b.txt:1 aws-access-key"* ]]
  [[ "$output" == *"BLOCK c.txt:1 private-key"* ]]
  [[ "$output" != *"$tok"* ]]
  [[ "$output" != *"$aws"* ]]
}

@test "secrets-check: slack token, jwt, url credentials and assigned secrets are blocked" {
  printf 'x=%s\n' "xoxb-$(printf '1234567890%.0s' 1 2)" > s.txt
  printf 'j=%s.%s.%s\n' "eyJ$(printf 'a%.0s' $(seq 12))" "eyJ$(printf 'b%.0s' $(seq 12))" "$(printf 'c%.0s' $(seq 12))" > j.txt
  printf 'u=https://user:%s@host.example/x\n' 'hunter2hunter2' > u.txt
  printf 'api_key: "%s"\n' "$(printf 'Ab3%.0s' $(seq 8))" > k.yaml
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"s.txt:1 slack-token"* ]]
  [[ "$output" == *"j.txt:1 jwt"* ]]
  [[ "$output" == *"u.txt:1 url-credentials"* ]]
  [[ "$output" == *"k.yaml:1 assigned-secret"* ]]
}

@test "secrets-check: placeholders and plain identifiers in assignments do not block" {
  printf 'token = ${GITHUB_TOKEN}\npassword: <your-password-here>\nsecret_name = some_long_identifier_name_here\nkey=op://v/i/f\n' > cfg.txt
  _prep secrets-check
  [ "$status" -eq 0 ]
}

@test "secrets-check: the staged (index) version is scanned even if the worktree copy was cleaned" {
  printf 'T=%s\n' "$(_ghp)" > a.sh; git add a.sh
  echo clean > a.sh
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK a.sh (index):1 github-token"* ]]
}

@test "secrets-check --base: committed files on the branch are scanned too" {
  git checkout -q -b feat-x
  printf 'T=%s\n' "$(_ghp)" > a.sh; _commit leak
  _prep secrets-check
  [ "$status" -eq 0 ]
  _prep secrets-check --base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK a.sh:1 github-token"* ]]
}

@test "secrets-check: unscannable things fail closed (binary, symlink); media is name-checked only" {
  printf '\x00\x01\x02binary' > blob.dat
  printf '\x89PNG\x00\x01' > pic.png
  ln -s /etc/hosts link.txt
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK blob.dat unscannable-binary"* ]]
  [[ "$output" == *"BLOCK link.txt unscannable-symlink"* ]]
  [[ "$output" != *"pic.png"* ]]
}

@test "secrets-check: deleted files are skipped; no changes is clean; bad base and non-repo exit 2" {
  echo x > gone.txt; _commit seed; git rm -q gone.txt
  _prep secrets-check; [ "$status" -eq 0 ]
  _prep secrets-check --base nope; [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS=blocked"* ]]
  _prep secrets-check --bogus; [ "$status" -eq 2 ]
  cd "$BATS_TEST_TMPDIR" && mkdir plain && cd plain && _prep secrets-check
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS=blocked"* ]]
}

@test "secrets-check: runs from the repo root even when invoked from a subdirectory" {
  mkdir sub; printf 'T=%s\n' "$(_ghp)" > sub/a.sh
  cd sub
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK sub/a.sh:1 github-token"* ]]
  _prep changed md; [ "$status" -eq 0 ]
}

@test "secrets-check: a staged secret deleted from the worktree is still seen" {
  printf 'T=%s\n' "$(_ghp)" > a.sh; git add a.sh; rm a.sh
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK a.sh (index):1 github-token"* ]]
}

@test "secrets-check --base: a secret added in one commit and removed in a later one is flagged" {
  git checkout -q -b feat-x
  printf 'T=%s\n' "$(_ghp)" > a.sh; _commit leak
  echo clean > a.sh; _commit fix
  _prep secrets-check --base main
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCK a.sh ("* ]]
  [[ "$output" == *"github-token"* ]]
}

@test "secrets-check: pgp key blocks, bearer tokens, short passwords with a symbol or digit, config credential files" {
  printf -- '-----BEGIN PGP PRIVATE KEY %s-----\n' BLOCK > p.txt
  printf 'Authorization: Bearer %s\n' "$(printf 'Zz9%.0s' $(seq 10))" > h.txt
  printf 'password = hunter2!\n' > pw.conf
  : > .npmrc; mkdir .docker; : > .docker/config.json
  _prep secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"p.txt:1 private-key"* ]]
  [[ "$output" == *"h.txt:1 bearer-token"* ]]
  [[ "$output" == *"pw.conf:1 assigned-password"* ]]
  [[ "$output" == *"BLOCK .npmrc credential-file"* ]]
  [[ "$output" == *"BLOCK .docker/config.json credential-file"* ]]
}

@test "secrets-check: hyphenated words ending in sk- (disk-, task-) and password placeholders do not block" {
  printf 'see disk-usage-monitoring-script-name and task-queue-operations-staging\npassword = get_password_from_env\npassword: $PASSWORD_VAR\npwd = <changeme>\nBearer <token>\n' > ok.txt
  _prep secrets-check
  [ "$status" -eq 0 ]
}

@test "secrets-check: a grep failure is a block, not a pass" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 2\n' > "$BATS_TEST_TMPDIR/bin/grep"; chmod +x "$BATS_TEST_TMPDIR/bin/grep"
  echo hello > a.txt
  # the stub only shadows grep for the scan; the file looks like text, so every rule errors
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$PREP" secrets-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"unscannable"* ]]
}

@test "no verb moves HEAD, refs or the index (nothing is committed or pushed)" {
  git checkout -q -b feat-x; echo a > a.txt
  before="$(git rev-parse HEAD; git for-each-ref; git diff --cached --name-only)"
  echo "- s" > s.md
  for v in "assess" "lint" "secrets-check --base main" "body --summary-file s.md" "changed md"; do
    _prep $v
  done
  [ "$before" = "$(git rev-parse HEAD; git for-each-ref; git diff --cached --name-only)" ]
}

# ---- body -----------------------------------------------------------------------------

@test "body: always carries Summary, Pre-merge and Post-merge; empty sections become N/A" {
  printf -- '- adds the thing\n' > s.md
  _prep body --summary-file s.md
  [ "$status" -eq 0 ]
  [[ "$output" == "## Summary
- adds the thing

## Test plan

### Pre-merge
N/A

### Post-merge
N/A

Generated with [Claude Code](https://claude.com/claude-code)" ]]
}

@test "body: pre/post content is kept verbatim, blank-only files are N/A, trailing blanks trimmed" {
  printf -- '- one\n- two\n\n\n' > s.md
  printf -- '- [ ] bats green\n- [ ] review clean\n\n' > pre.md
  printf '   \n\n' > post.md
  _prep body --summary-file s.md --pre pre.md --post post.md
  [[ "$output" == *"### Pre-merge
- [ ] bats green
- [ ] review clean

### Post-merge
N/A"* ]]
  [[ "$output" == *"- two

## Test plan"* ]]
}

@test "body: --task-url is the first Summary line; --footer replaces the footer" {
  printf -- '- x\n' > s.md
  _prep body --summary-file s.md --task-url "https://github.com/o/r/blob/main/dev/TODO/T20000101-000001-x.md" --footer "custom footer"
  [[ "$output" == "## Summary
Task: https://github.com/o/r/blob/main/dev/TODO/T20000101-000001-x.md

- x"* ]]
  [[ "$output" == *"custom footer" ]]
  [[ "$output" != *"Generated with"* ]]
}

@test "body: empty or missing summary, bad task URL, unknown or valueless flag exit 2" {
  : > empty.md; printf 'x\n' > s.md
  _prep body --summary-file empty.md; [ "$status" -eq 2 ]
  _prep body --summary-file nope.md; [ "$status" -eq 2 ]
  _prep body; [ "$status" -eq 2 ]
  _prep body --summary-file s.md --task-url "javascript:alert(1)"; [ "$status" -eq 2 ]
  _prep body --summary-file s.md --task-url "https://a b"; [ "$status" -eq 2 ]
  _prep body --summary-file s.md --bogus x; [ "$status" -eq 2 ]
  _prep body --summary-file; [ "$status" -eq 2 ]
}

# ---- dispatch + safety -------------------------------------------------------------------

@test "unknown or missing verb exits 2 with usage" {
  _prep; [ "$status" -eq 2 ]
  _prep commit; [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "the script has no commit, push or PR-create verb and never calls them" {
  ! grep -nE 'git (commit|push)|pr create|gh\.sh pr (create|merge)' "$PREP" | grep -v '^[0-9]*:#'
}

# ---- /land alias structure -----------------------------------------------------------------

@test "land/SKILL.md is a pure alias: delegates to gcpr, has no workflow steps of its own" {
  grep -q '^name: land$' "$WRAP"
  grep -q '\.\./gcpr/SKILL.md' "$WRAP"
  grep -qi 'invoke the `gcpr` skill' "$WRAP"
  [ "$(wc -l < "$WRAP")" -le 20 ]
  ! grep -qE '^#{2,3} [0-9]|git (commit|push|checkout)|gh\.sh' "$WRAP"
  ! grep -q 'scripts/' "$WRAP"
}

@test "land/SKILL.md forwards arguments unchanged and gcpr names the alias back" {
  grep -q 'forward `\$ARGUMENTS` unchanged' "$WRAP"
  grep -q 'land/SKILL.md' "$REPO_ROOT/gcpr/SKILL.md"
  [ -f "$REPO_ROOT/gcpr/SKILL.md" ]
}

@test "gcpr/SKILL.md cites every gcpr-prep verb it relies on, and each exists in the script" {
  for v in assess lint branch-name review-flip secrets-check body; do
    grep -q "gcpr-prep.sh $v" "$REPO_ROOT/gcpr/SKILL.md"
    grep -qE "^ +$v\) " "$PREP"
  done
}
