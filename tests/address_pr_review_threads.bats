#!/usr/bin/env bats
# address-pr/scripts/review-threads.sh — list / reply / resolve of the review
# threads a required-thread-resolution ruleset blocks merge on. Offline: a stub
# gh wrapper (GH_SH) serves fixtures and logs every call; a real throwaway git
# repo backs the sha ancestry/path check.

load test_helper
bats_require_minimum_version 1.5.0

RT="$REPO_ROOT/address-pr/scripts/review-threads.sh"

setup() {
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX"
  LOG="$BATS_TEST_TMPDIR/calls.log"; : > "$LOG"
  export FX LOG
  # throwaway repo: c0 (base) touches a.txt, c1 touches a.txt, c2 touches b.txt (HEAD)
  R="$BATS_TEST_TMPDIR/repo"; mkdir -p "$R"; git -C "$R" init -q -b main; git_identity "$R"
  echo 0 > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -q -m c0; C0="$(git -C "$R" rev-parse HEAD)"
  echo 1 > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -q -m c1; C1="$(git -C "$R" rev-parse HEAD)"
  echo 2 > "$R/b.txt"; git -C "$R" add -A; git -C "$R" commit -q -m c2; C2="$(git -C "$R" rev-parse HEAD)"
  export C0 C1 C2
  echo "$C2" > "$FX/head"; echo "$C0" > "$FX/base"
  echo '{"login":"me"}' > "$FX/user.json"
  cat > "$BATS_TEST_TMPDIR/gh-sh.sh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"FAIL_API"*) ;;
esac
if [ -f "$FX/fail" ] && printf '%s' "$args" | grep -Eq "$(cat "$FX/fail")"; then echo "FAILED $args" >> "$LOG"; exit 1; fi
case "$args" in
  "repo view"*"--jq .owner.login") echo acme ;;
  "repo view"*"--jq .name") echo repo ;;
  "api user") cat "$FX/user.json" ;;
  "pr view"*baseRefOid*) cat "$FX/base" ;;
  "pr view"*headRefOid*) cat "$FX/head" ;;
  *resolveReviewThread*) echo "resolve ${args#*tid=}" | cut -d' ' -f1-2 >> "$LOG"; echo '{}' ;;
  *addPullRequestReviewThreadReply*) echo "reply $args" >> "$LOG"; echo '{}' ;;
  *reviewThreads*)
    if printf '%s' "$args" | grep -q -- "after=CUR1"; then cat "$FX/page2.json"; else cat "$FX/page1.json"; fi ;;
  *) echo "UNMAPPED $args" >> "$LOG"; exit 97 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/gh-sh.sh"
  export GH_SH="$BATS_TEST_TMPDIR/gh-sh.sh"
  cd "$R"
}

# th <id> <resolved> <outdated> <path> <canResolve> <first-author> <first-type> [<our-last-body>]
th() {
  jq -nc --arg id "$1" --argjson res "$2" --argjson out "$3" --arg path "$4" --argjson can "$5" \
    --arg fa "$6" --arg ft "$7" --arg mine "${8:-}" '
    {id:$id,isResolved:$res,isOutdated:$out,viewerCanResolve:$can,path:$path,line:3,
     comments:{nodes:([{body:"finding",author:{login:$fa,__typename:$ft}}]
       + (if $mine == "" then [] else [{body:$mine,author:{login:"me",__typename:"User"}}] end))}}'
}
# page <more:true|false> <cursor> <thread-json>...
page() {
  local more="$1" cur="$2"; shift 2
  local nodes; nodes="$(printf '%s\n' "$@" | jq -s '.')"
  jq -nc --argjson n "$nodes" --argjson m "$more" --arg c "$cur" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$m,endCursor:$c},nodes:$n}}}}}'
}
p1() { page false "" "$@" > "$FX/page1.json"; }
resolves() { grep -c '^resolve' "$LOG" || true; }

@test "usage errors exit 2" {
  run bash "$RT"; [ "$status" -eq 2 ]
  run bash "$RT" list abc; [ "$status" -eq 2 ]
  run bash "$RT" bogus 1; [ "$status" -eq 2 ]
  run bash "$RT" reply 1 T1 --fixed; [ "$status" -eq 2 ]
}

@test "list: no unresolved threads exits 0 with no rows" {
  p1 "$(th T1 true false a.txt true copilot Bot)"
  run bash "$RT" list 7
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "list: bot thread remaining exits 10 and prints the row" {
  p1 "$(th T1 false false a.txt true copilot Bot)"
  run bash "$RT" list 7
  [ "$status" -eq 10 ]
  [ "$output" = "$(printf 'T1\tbot\tcurrent\ta.txt:3\tnone')" ]
}

@test "list: only human-opened threads exits 11" {
  p1 "$(th T1 false true a.txt true alice User)"
  run bash "$RT" list 7
  [ "$status" -eq 11 ]; [[ "$output" == *"human"*"outdated"* ]]
}

@test "list: human and bot threads together exit 10" {
  p1 "$(th T1 false false a.txt true alice User)" "$(th T2 false false a.txt true copilot Bot)"
  run bash "$RT" list 7
  [ "$status" -eq 10 ]
}

@test "list: follows pagination" {
  page true CUR1 "$(th T1 true false a.txt true copilot Bot)" > "$FX/page1.json"
  page false "" "$(th T2 false false b.txt true copilot Bot)" > "$FX/page2.json"
  run bash "$RT" list 7
  [ "$status" -eq 10 ]; [[ "$output" == T2* ]]
}

@test "list: API failure fails closed (3)" {
  p1 "$(th T1 false false a.txt true copilot Bot)"
  echo "graphql" > "$FX/fail"
  run --separate-stderr bash "$RT" list 7
  [ "$status" -eq 3 ]
}

@test "resolve: Addressed in <sha> touching the path resolves the bot thread" {
  p1 "$(th T1 false false a.txt true copilot Bot "Addressed in $C1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 0 ]; [[ "$output" == *"resolved T1 (fixed)"* ]]
  [ "$(resolves)" -eq 1 ]
}

@test "resolve: sha that does not touch the thread's path is not enough" {
  p1 "$(th T1 false false a.txt true copilot Bot "Addressed in $C2")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: sha that is not an ancestor of head is not enough" {
  git checkout -q -b side "$C1"; echo 3 > a.txt; git add -A; git commit -q -m c3; S="$(git rev-parse HEAD)"; git checkout -q main
  p1 "$(th T1 false false a.txt true copilot Bot "Addressed in $S")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: a sha already on the base branch is not a fix of this PR" {
  p1 "$(th T1 false false a.txt true copilot Bot "Addressed in $C0")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: a later bot reply after our marker keeps the thread open" {
  jq -nc --arg m "Addressed in $C1" '{id:"T1",isResolved:false,isOutdated:false,viewerCanResolve:true,path:"a.txt",line:3,
    comments:{nodes:[{body:"f",author:{login:"copilot",__typename:"Bot"}},{body:$m,author:{login:"me",__typename:"User"}},{body:"still wrong",author:{login:"copilot",__typename:"Bot"}}]}}' > "$FX/t1"
  p1 "$(cat "$FX/t1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: a thread of 50+ comments is never resolved" {
  jq -nc --arg m "Addressed in $C1" '{id:"T1",isResolved:false,isOutdated:false,viewerCanResolve:true,path:"a.txt",line:3,
    comments:{nodes:([{body:"f",author:{login:"copilot",__typename:"Bot"}}] + [range(48) | {body:"x",author:{login:"copilot",__typename:"Bot"}}] + [{body:$m,author:{login:"me",__typename:"User"}}])}}' > "$FX/t1"
  p1 "$(cat "$FX/t1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: outdated thread without a marker is never resolved" {
  p1 "$(th T1 false true a.txt true copilot Bot)"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: human-opened thread with a marker is never resolved (exit 11)" {
  p1 "$(th T1 false false a.txt true alice User "Addressed in $C1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 11 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: viewerCanResolve=false is skipped" {
  p1 "$(th T1 false false a.txt false copilot Bot "Addressed in $C1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: another author's marker does not count" {
  jq -nc '{id:"T1",isResolved:false,isOutdated:false,viewerCanResolve:true,path:"a.txt",line:3,
    comments:{nodes:[{body:"f",author:{login:"copilot",__typename:"Bot"}},{body:"Not changing: x",author:{login:"other",__typename:"User"}}]}}' > "$FX/t1"
  p1 "$(cat "$FX/t1")"
  run bash "$RT" resolve 7
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 0 ]
}

@test "resolve: pushback resolutions are capped per run" {
  p1 "$(th T1 false false a.txt true copilot Bot 'Not changing: ok')" "$(th T2 false false a.txt true copilot Bot 'Not changing: ok')"
  run bash "$RT" resolve 7 --max-pushback 1
  [ "$status" -eq 10 ]; [ "$(resolves)" -eq 1 ]; [[ "$output" == *"T2"*"pushback"* ]]
}

@test "resolve: nothing left after resolving everything exits 0" {
  p1 "$(th T1 false false a.txt true copilot Bot 'Not changing: ok')"
  run bash "$RT" resolve 7
  [ "$status" -eq 0 ]; [ "$(resolves)" -eq 1 ]
}

@test "resolve: mutation failure fails closed (3)" {
  p1 "$(th T1 false false a.txt true copilot Bot 'Not changing: ok')"
  echo "resolveReviewThread" > "$FX/fail"
  run --separate-stderr bash "$RT" resolve 7
  [ "$status" -eq 3 ]
}

@test "reply --fixed posts the Addressed marker" {
  run bash "$RT" reply 7 T1 --fixed "$C1"
  [ "$status" -eq 0 ]; grep -q "body=Addressed in $C1" "$LOG"
}

@test "reply --fixed rejects an unknown commit" {
  run --separate-stderr bash "$RT" reply 7 T1 --fixed deadbeefdeadbeef
  [ "$status" -eq 3 ]; ! grep -q '^reply' "$LOG"
}

@test "reply --pushback posts the Not changing marker from a file" {
  printf 'the API requires it\n' > "$BATS_TEST_TMPDIR/why"
  run bash "$RT" reply 7 T1 --pushback "$BATS_TEST_TMPDIR/why"
  [ "$status" -eq 0 ]; grep -q "body=Not changing: the API requires it" "$LOG"
}
