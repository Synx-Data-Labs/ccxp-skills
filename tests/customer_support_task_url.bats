#!/usr/bin/env bats
# Tests for customer-support/scripts/task_url.sh (T20261021-289402): resolves a
# backing task id to a full SHA-pinned URL. Fakes only (CS_GH); no real repo,
# issue or token is touched.

load test_helper
setup() {
  SCRIPT="$REPO_ROOT/customer-support/scripts/task_url.sh"
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX"
  cd "$BATS_TEST_TMPDIR"
  ID="T20261021-113866"
  cat > gh-fake.sh <<'FAKE'
#!/usr/bin/env bash
# Fixture-driven `gh api` fake: path (without host) -> file in $FX, with
# / ? & = mapped to _. A missing fixture is a 404 (exit 1).
echo "$*" >> "$FX/../calls.log"
[[ "$1" == "api" ]] || exit 0
shift
while [[ "${1:-}" == "-H" ]]; do shift 2; done
f="$FX/$(printf '%s' "$1" | sed 's#[/?&=]#_#g')"
if [[ -f "$f" ]]; then cat "$f"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
FAKE
  chmod +x gh-fake.sh
  export FX CS_GH="$BATS_TEST_TMPDIR/gh-fake.sh"
}

_fx() { printf '%s' "$2" > "$FX/$(printf '%s' "$1" | sed 's#[/?&=]#_#g')"; }

_repo() {
  _fx "repos/acme/proj" '{"default_branch":"main"}'
  _fx "repos/acme/proj/commits/main" '{"sha":"abc123"}'
}

@test "task on the default branch: SHA-pinned permalink + title" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" "[{\"name\":\"${ID}-do-thing.md\",\"path\":\"dev/TODO/${ID}-do-thing.md\"}]"
  _fx "repos/acme/proj/contents/dev/TODO/${ID}-do-thing.md?ref=abc123" "---
status: Open
---

# ${ID}: Do the thing
"
  run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 0 ]
  IFS=$'\037' read -r kind url title prurl <<<"$output"
  [ "$kind" = main ]
  [ "$url" = "https://github.com/acme/proj/blob/abc123/dev/TODO/${ID}-do-thing.md" ]
  [ "$title" = "Do the thing" ]
  [ -z "$prurl" ]
}

@test "owner-qualified ref is accepted and wins over the default owner" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" "[{\"name\":\"${ID}-x.md\",\"path\":\"dev/TODO/${ID}-x.md\"}]"
  run bash "$SCRIPT" "acme/proj#${ID}" other
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/acme/proj/blob/abc123/dev/TODO/${ID}-x.md"* ]]
}

@test "task already in JOURNAL: pinned link to the journal file" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" '[]'
  _fx "repos/acme/proj/contents/dev/JOURNAL?ref=abc123" "[{\"name\":\"2026-10-22-${ID}-done.md\",\"path\":\"dev/JOURNAL/2026-10-22-${ID}-done.md\"}]"
  run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 0 ]
  [[ "$output" == journal* ]]
  [[ "$output" == *"https://github.com/acme/proj/blob/abc123/dev/JOURNAL/2026-10-22-${ID}-done.md"* ]]
}

@test "task only on an open PR: head-SHA link in the head repo plus the PR URL" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" '[]'
  _fx "repos/acme/proj/pulls?state=open&per_page=100" "[
   {\"number\":7,\"title\":\"unrelated\",\"body\":\"\",\"head\":{\"ref\":\"x\",\"sha\":\"s0\",\"repo\":{\"full_name\":\"acme/proj\"}},\"html_url\":\"https://github.com/acme/proj/pull/7\"},
   {\"number\":9,\"title\":\"docs(queue): stage ${ID}\",\"body\":\"\",\"head\":{\"ref\":\"docs/stage\",\"sha\":\"feed99\",\"repo\":{\"full_name\":\"fork/proj\"}},\"html_url\":\"https://github.com/acme/proj/pull/9\"}]"
  _fx "repos/acme/proj/pulls/9/files?per_page=100" "[{\"filename\":\"dev/TODO/queue.md\"},{\"filename\":\"dev/TODO/${ID}-pr-only.md\"}]"
  _fx "repos/fork/proj/contents/dev/TODO/${ID}-pr-only.md?ref=feed99" "# ${ID}: Only on a PR
"
  run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 0 ]
  IFS=$'\037' read -r kind url title prurl <<<"$output"
  [ "$kind" = pr ]
  [ "$url" = "https://github.com/fork/proj/blob/feed99/dev/TODO/${ID}-pr-only.md" ]
  [ "$title" = "Only on a PR" ]
  [ "$prurl" = "https://github.com/acme/proj/pull/9" ]
}

@test "missing task: fails loudly, names the cause, prints no URL" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" '[]'
  _fx "repos/acme/proj/contents/dev/JOURNAL?ref=abc123" '[]'
  _fx "repos/acme/proj/pulls?state=open&per_page=100" '[]'
  run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"task ${ID} not found in acme/proj"* ]]
  [[ "$output" != *"https://github.com/acme/proj/blob"* ]]
}

@test "private repo without access: 'not readable' (not 'missing'), points at gh auth, leaks no token" {
  # No fixtures at all: repos/acme/proj is a 404, as a private repo looks without access.
  GH_TOKEN="ghp_SECRET_SHOULD_NEVER_PRINT" run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read acme/proj"* ]]
  [[ "$output" == *"gh auth"* ]]
  [[ "$output" != *"SECRET"* ]]
  [[ "$output" != *"not found in"* ]]
  # Only the repo probe was attempted; nothing past it.
  [ "$(wc -l < calls.log)" -eq 1 ]
}

@test "private repo with access behaves exactly like a public one (same api path, no extra auth handling)" {
  _repo
  _fx "repos/acme/proj/contents/dev/TODO?ref=abc123" "[{\"name\":\"${ID}-p.md\",\"path\":\"dev/TODO/${ID}-p.md\"}]"
  run bash "$SCRIPT" "proj#${ID}" acme
  [ "$status" -eq 0 ]
  if grep -qi 'token\|authorization' calls.log; then false; fi
}

@test "malformed ref is rejected before any API call" {
  run bash "$SCRIPT" 'proj#T1 2 3 && echo pwned' acme
  [ "$status" -eq 2 ]
  [[ "$output" == *"must look like"* ]]
  [ ! -f calls.log ]
}

@test "bare repo ref with no default owner is rejected" {
  run bash "$SCRIPT" "proj#${ID}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no owner"* ]]
}
