#!/usr/bin/env bats
# labrun-rca/scripts/labrun.sh: parse / extract-run / render-reply. Offline and
# pure text: fake channel ids, fake run ids, fake tokens built at runtime so
# secret scanners do not flag this file. The script never posts or calls gh.

load test_helper

LAB="$REPO_ROOT/labrun-rca/scripts/labrun.sh"
URL=https://example-workspace.slack.com/archives/C000EXAMPLE/p1600000000000000
RUN=https://github.com/example-org/example-repo/actions/runs/12345678901

lab() { run bash "$LAB" "$@"; }

# render <overrides...>: a valid render-reply call; later flags win via env
render() {
  run bash "$LAB" render-reply --workflow "${WF:-Release Example}" --run-id 12345678901 \
    --run-url "$RUN" --error "${T_ERR:-build failed}" --root-cause "${T_ROOT:-a bad pin}" \
    --classification "${CLS:-Our code}" --confidence "${CONF:-Confirmed}" \
    --impact "${IMPACT:-main is red}" --action "${ACTION:-T20000101-000001}"
}

# ---- parse -----------------------------------------------------------------

@test "parse: permalink -> channel id and ts with the dot 6 from the end" {
  lab parse "$URL"
  [ "$status" -eq 0 ]
  [ "$output" = $'channel_id=C000EXAMPLE\nmessage_ts=1600000000.000000' ]
  lab parse https://x.slack.com/archives/G0ABCDEF1/p1712345678123456
  [ "$output" = $'channel_id=G0ABCDEF1\nmessage_ts=1712345678.123456' ]
}

@test "parse: finds the permalink inside Slack-formatted text, drops query" {
  lab parse "failure here <${URL}?thread_ts=1600000000.000000&cid=C000EXAMPLE|link> please look"
  [ "$status" -eq 0 ]
  [[ "$output" == *"message_ts=1600000000.000000"* ]]
}

@test "parse: malformed input exits 2 with a message, prints nothing on stdout" {
  for bad in "" "not a url" "https://x.slack.com/archives/C000EXAMPLE" \
             "https://x.slack.com/archives/C000EXAMPLE/p16000" \
             "https://x.slack.com/archives/X000EXAMPLE/p1600000000000000" \
             "https://x.slack.com/archives/c000example/p1600000000000000" \
             "https://example.com/archives/C000EXAMPLE/p1600000000000000" \
             "https://x.slack.com/archives/C000EXAMPLE/p16000000000000001"; do
    run bash -c 'bash "$1" parse "$2" 2>/dev/null' _ "$LAB" "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
  lab parse
  [ "$status" -eq 2 ]
}

# ---- extract-run -----------------------------------------------------------

@test "extract-run: a run link gives id and url, duplicates collapse" {
  run bash -c 'printf "%s\n" "Release failed <$1|run> see $1" | bash "$2" extract-run' _ "$RUN" "$LAB"
  [ "$status" -eq 0 ]
  [ "$output" = $'run_id=12345678901\nrun_url='"$RUN" ]
}

@test "extract-run: reads a file; 'run #<id>' and a lone bare number work, no url line" {
  printf 'Workflow Release Example, Run #98765432 on main failed\n' > "$BATS_TEST_TMPDIR/n.txt"
  lab extract-run "$BATS_TEST_TMPDIR/n.txt"
  [ "$output" = "run_id=98765432" ]
  run bash -c 'echo "failed: 55555555555 on main ts 1600000000.000000" | bash "$1" extract-run' _ "$LAB"
  [ "$status" -eq 0 ]
  [ "$output" = "run_id=55555555555" ]
}

@test "extract-run: none -> exit 3 (a Slack ts or short number is not a run id)" {
  run bash -c 'echo "build failed at 1600000000.000000, attempt 3" | bash "$1" extract-run 2>/dev/null' _ "$LAB"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  run bash -c 'echo "" | bash "$1" extract-run 2>/dev/null' _ "$LAB"
  [ "$status" -eq 3 ]
}

@test "extract-run: several distinct ids -> exit 4, candidates listed, none chosen" {
  run bash -c 'printf "%s\n%s\n" "$1/actions/runs/111111111" "$1/actions/runs/222222222" | bash "$2" extract-run 2>/dev/null' _ https://github.com/example-org/example-repo "$LAB"
  [ "$status" -eq 4 ]
  [ "$output" = $'candidate=111111111\ncandidate=222222222' ]
  [[ "$output" != *run_id=* ]]
}

@test "extract-run: an epoch timestamp is not a run id; one run linked in two repos yields one url" {
  run bash -c 'echo "failed at 1700000000 attempt" | bash "$1" extract-run 2>/dev/null' _ "$LAB"
  [ "$status" -eq 3 ]
  run bash -c 'printf "%s\n%s\n" https://github.com/a/b/actions/runs/111111111 https://github.com/c/d/actions/runs/111111111 | bash "$1" extract-run' _ "$LAB"
  [ "$status" -eq 0 ]
  [ "$(grep -c run_url <<<"$output")" -eq 1 ]
}

@test "extract-run: two bare ids separated by one space are ambiguous; run <ts> is not an id" {
  run bash -c 'echo "55555555555 66666666666" | bash "$1" extract-run 2>/dev/null' _ "$LAB"
  [ "$status" -eq 4 ]
  run bash -c 'echo "run 1600000000.000000 failed" | bash "$1" extract-run 2>/dev/null' _ "$LAB"
  [ "$status" -eq 3 ]
  run bash -c 'echo "Run 12345678901." | bash "$1" extract-run' _ "$LAB"
  [ "$output" = "run_id=12345678901" ]
}

@test "parse: trailing punctuation and an earlier non-matching link are tolerated" {
  lab parse "see (${URL})."
  [ "$status" -eq 0 ]
  lab parse "https://x.slack.com/archives/C000EXAMPLE and then $URL"
  [ "$status" -eq 0 ]
}

@test "render: --run-id must match the id in --run-url (exit 2)" {
  run bash "$LAB" render-reply --workflow w --run-id 999 --run-url "$RUN" --error e --root-cause r --classification Transient --confidence Confirmed --impact i --action a
  [ "$status" -eq 2 ]
}

@test "extract-run: an unreadable file exits 2" {
  lab extract-run "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -eq 2 ]
}

# ---- render-reply ----------------------------------------------------------

@test "render: the documented template (bats drops blank lines from lines[]), starting with the dedup marker" {
  render
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "*RCA — Release Example run 12345678901*" ]
  [ "${lines[1]}" = '*Error:* `build failed`' ]
  [ "${lines[2]}" = "*Root cause:* a bad pin" ]
  [ "${lines[3]}" = "*Classification:* Our code" ]
  [ "${lines[4]}" = "*Confidence:* Confirmed" ]
  [ "${lines[5]}" = "*Impact:* main is red" ]
  [ "${lines[6]}" = "*Action:* T20000101-000001" ]
  [ "${lines[7]}" = "Logs: <$RUN|run>" ]
}

@test "render: classification and confidence are normalised, all five classes accepted" {
  for c in "our-code:Our code" "INFRASTRUCTURE:Infrastructure" "upstream:Upstream" "Transient:Transient" "configuration:Configuration"; do
    CLS="${c%%:*}" CONF=unconfirmed render
    [ "$status" -eq 0 ]
    [[ "$output" == *"*Classification:* ${c#*:}"* ]]
    [[ "$output" == *"*Confidence:* Unconfirmed"* ]]
  done
}

@test "render: an enum failure exits 5 with nothing on stdout" {
  for c in "flaky" "" "Our codes"; do
    run bash -c 'CLS="$1" . /dev/null; bash "$2" render-reply --workflow w --run-id 12345678901 --run-url "$3" --error e --root-cause r --classification "$1" --confidence Confirmed --impact i --action a 2>/dev/null' _ "$c" "$LAB" "$RUN"
    [ "$status" -eq 5 ]
    [ -z "$output" ]
  done
  CONF=maybe render
  [ "$status" -eq 5 ]
}

@test "render: usage errors exit 2 (missing, unknown, multi-line, empty, bad id or url)" {
  lab render-reply --workflow w
  [ "$status" -eq 2 ]
  lab render-reply --bogus x
  [ "$status" -eq 2 ]
  T_ROOT=$'two\nlines' render; [ "$status" -eq 2 ]
  T_ERR="  " render; [ "$status" -eq 2 ]
  run bash "$LAB" render-reply --workflow w --run-id abc --run-url "$RUN" --error e --root-cause r --classification Transient --confidence Confirmed --impact i --action a
  [ "$status" -eq 2 ]
  run bash "$LAB" render-reply --workflow w --run-id 12345678901 --run-url "https://evil.example/x" --error e --root-cause r --classification Transient --confidence Confirmed --impact i --action a
  [ "$status" -eq 2 ]
}

@test "render: Slack control characters are escaped, backticks cannot break the code span" {
  T_ERR='a <b> & `c`' render
  [ "$status" -eq 0 ]
  [[ "$output" == *'*Error:* `a &lt;b&gt; &amp; '"'c'"'`'* ]]
}

@test "render: a token-like string anywhere exits 6, prints nothing, never echoes the match" {
  # built at runtime so no scanner sees a literal token in this file
  local pfx tok
  for pfx in "gh""p_" "github_pat""_" "xox""b-" "sk""-"; do
    tok="${pfx}$(printf 'A1b2C3d4E5%.0s' 1 2 3)"
    run bash -c 'bash "$1" render-reply --workflow w --run-id 12345678901 --run-url "$2" --error "login failed with $3" --root-cause r --classification Transient --confidence Confirmed --impact i --action a 2>/dev/null' _ "$LAB" "$RUN" "$tok"
    [ "$status" -eq 6 ]
    [ -z "$output" ]
    run bash "$LAB" render-reply --workflow w --run-id 12345678901 --run-url "$RUN" --error e --root-cause "leaked $tok" --classification Transient --confidence Confirmed --impact i --action a
    [ "$status" -eq 6 ]
  done
  # stderr must not repeat the secret
  tok="gh""p_$(printf 'Zz9Yy8Xx7W%.0s' 1 2 3)"
  run bash -c 'bash "$1" render-reply --workflow w --run-id 12345678901 --run-url "$2" --error "$3" --root-cause r --classification Transient --confidence Confirmed --impact i --action a 2>&1 >/dev/null' _ "$LAB" "$RUN" "$tok"
  [ "$status" -eq 6 ]
  [[ "$output" != *"$tok"* ]]
  [[ "$output" == *"token-like"* ]]
}

@test "render: other credential shapes exit 6 (aws key, private key, jwt, webhook, assignment)" {
  local aws="AK""IA$(printf 'ABCDEFGHIJKLMNOP')" jwt="ey""J$(printf 'abcdefghij').$(printf 'abcdefghij').$(printf 'abcdefghij')"
  local hook="hooks.slack.""com/services/T0/B0/$(printf 'abcdefghij')"
  for v in "GITHUB_""TOKEN=$(printf 'abcdefgh1234')" "Token: $(printf 'abcdefgh1234')" "PASSWORD=$(printf 'abcdefghij')" \
           "sk_li""ve_$(printf 'abcdefgh12345678')" "token $(printf 'abcdefghijklmnopqrst')" "AWS_SECRET_ACCESS_""KEY=$(printf 'abcdefgh1234')" "npm""_$(printf 'a1B2c3D4e5%.0s' 1 2 3)" \
           "glp""at-$(printf 'a1B2c3D4e5%.0s' 1 2)" "https://user:$(printf 'pw123456')@example.com/x" \
           "Authorization: Bas""ic $(printf 'dXNlcjpwYXNzd29yZDEyMw==')" "$aws" "-----BEGIN RSA PRIVATE"" KEY-----" "$jwt" "https://$hook" "api_key=$(printf 'abcdef0123456789')" "password: $(printf 'hunter2hunter2hunter2')"; do
    T_ERR="$v" render
    [ "$status" -eq 6 ]
  done
}

@test "render: ordinary logs and 40-hex commit shas are not flagged" {
  T_ERR='make: *** [all] Error 2 at 0123456789abcdef0123456789abcdef01234567' render
  [ "$status" -eq 0 ]
  T_ERR='disk-usage-threshold-exceeded-now' render
  [ "$status" -eq 0 ]
  T_ROOT='the token cache was cold; secret rotation is unrelated' render
  [ "$status" -eq 0 ]
}

# ---- contract --------------------------------------------------------------

@test "works from a skills root whose path contains a space" {
  local root; root="$(space_skills_root)"
  run bash "$root/labrun-rca/scripts/labrun.sh" parse "$URL"
  [ "$status" -eq 0 ]
  run bash "$root/labrun-rca/scripts/labrun.sh" render-reply --workflow w --run-id 12345678901 --run-url "$RUN" --error e --root-cause r --classification Transient --confidence Confirmed --impact i --action a
  [ "$status" -eq 0 ]
}

@test "labrun.sh never calls gh, curl or any network/post tool" {
  # only comment lines may mention them
  run grep -nE '(^|[;&|(]) *(gh|git|curl|wget|ssh) |\b(curl|wget|ssh|git push|slack_send_message)\b' <(grep -vE '^[[:space:]]*#' "$LAB")
  [ "$status" -eq 1 ]
}

@test "SKILL.md calls the script for input, extract-run, render-reply and the guards" {
  for s in input extract-run render-reply repo-of repo-allowed channel-guard alert-kind thread-state; do
    grep -q "<skills-root>/labrun-rca/scripts/labrun.sh $s" "$REPO_ROOT/labrun-rca/SKILL.md"
  done
}

# ---- job input forms (T20261113-143109) -------------------------------------

@test "input: permalink, channel+ts pair and bare run id all resolve" {
  lab input "$URL"
  [ "$output" = $'channel_id=C000EXAMPLE\nmessage_ts=1600000000.000000' ]
  lab input C000EXAMPLE 1600000000.000123
  [ "$status" -eq 0 ]
  [ "$output" = $'channel_id=C000EXAMPLE\nmessage_ts=1600000000.000123' ]
  lab input 12345678901
  [ "$output" = "run_id=12345678901" ]
}

@test "input: malformed forms exit 2 with nothing on stdout" {
  for args in "" "C000EXAMPLE" "c000example 1600000000.000123" "C000EXAMPLE 16000.1" "123" "a b c"; do
    run bash -c 'bash "$1" input $2 2>/dev/null' _ "$LAB" "$args"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "extract-run: a Block Kit message with the run link only in a button resolves" {
  cat > "$BATS_TEST_TMPDIR/blocks.json" <<JSON
{"text":"Release Example failed","blocks":[{"type":"actions","elements":[{"type":"button","text":{"type":"plain_text","text":"View run"},"url":"https:\/\/github.com\/example-org\/example-repo\/actions\/runs\/12345678901"}]}]}
JSON
  lab extract-run "$BATS_TEST_TMPDIR/blocks.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'run_id=12345678901\nrun_url='"$RUN" ]
}

# ---- repo and channel guards -------------------------------------------------

@test "repo-of: owner/repo from a run url; anything else exits 2" {
  lab repo-of "$RUN"
  [ "$output" = "repo=example-org/example-repo" ]
  lab repo-of https://example.com/x
  [ "$status" -eq 2 ]
}

@test "repo-allowed: default owner Synx-Data-Labs; env widens; other repo exits 7" {
  run env -u LABRUN_SERVED_OWNERS bash "$LAB" repo-allowed Synx-Data-Labs/synxdb-build-pipeline
  [ "$status" -eq 0 ]
  run env -u LABRUN_SERVED_OWNERS bash "$LAB" repo-allowed example-org/example-repo
  [ "$status" -eq 7 ]
  run env LABRUN_SERVED_OWNERS="example-org other/one" bash "$LAB" repo-allowed example-org/example-repo
  [ "$status" -eq 0 ]
  run env LABRUN_SERVED_OWNERS="other/one" bash "$LAB" repo-allowed other/two
  [ "$status" -eq 7 ]
  run env LABRUN_SERVED_OWNERS="other/one" bash "$LAB" repo-allowed other/one
  [ "$status" -eq 0 ]
}

@test "channel-guard: only the alerts channel id passes; unset env is a usage error" {
  run env SLACK_AUTOMATION_ALERTS_CHANNEL_ID=C000ALERTS bash "$LAB" channel-guard C000ALERTS
  [ "$status" -eq 0 ]
  run env SLACK_AUTOMATION_ALERTS_CHANNEL_ID=C000ALERTS bash "$LAB" channel-guard C000OTHER
  [ "$status" -eq 8 ]
  run env -u SLACK_AUTOMATION_ALERTS_CHANNEL_ID bash "$LAB" channel-guard C000ALERTS
  [ "$status" -eq 2 ]
}

# ---- alert-kind: stay silent on non-failures --------------------------------

@test "alert-kind: a failure text on the default branch is a failure alert" {
  run bash -c 'echo "Release Example failed on main" | bash "$1" alert-kind --branch main' _ "$LAB"
  [ "$status" -eq 0 ]
  [ "$output" = "failure" ]
}

@test "alert-kind: success, recovered and other-branch alerts exit 9 (no reply)" {
  for t in "Release Example succeeded on main" "Release Example recovered: run is green" "Release Example failure resolved"; do
    run bash -c 'echo "$2" | bash "$1" alert-kind --branch main' _ "$LAB" "$t"
    [ "$status" -eq 9 ]
    [ "$output" = "not a failure alert" ]
  done
  run bash -c 'echo "Release Example failed" | bash "$1" alert-kind --branch feature/x' _ "$LAB"
  [ "$status" -eq 9 ]
  [ "$output" = "not a failure alert: branch feature/x is not main" ]
  run bash -c 'echo "Release Example failed" | bash "$1" alert-kind --branch develop --default-branch develop' _ "$LAB"
  [ "$status" -eq 0 ]
}

# ---- thread-state: RCA done, ack-only, stale ack ----------------------------

thread() { # thread <now> <live-job> <<< replies "ts<TAB>text"
  run bash "$LAB" thread-state --now "$1" --live-job "$2"
}

@test "thread-state: no replies or only human chatter -> continue" {
  thread 1600010000 no <<< ""
  [ "$status" -eq 0 ]; [ "$output" = "continue" ]
  printf '1600000100.000000\tlooking into it\n' > "$BATS_TEST_TMPDIR/r.txt"
  run bash -c 'bash "$1" thread-state --now 1600010000 --live-job no < "$2"' _ "$LAB" "$BATS_TEST_TMPDIR/r.txt"
  [ "$output" = "continue" ]
}

@test "thread-state: a reply starting *RCA means stop (exit 10)" {
  printf '1600000100.000000\t*RCA — Release Example run 1*\n' > "$BATS_TEST_TMPDIR/r.txt"
  run bash -c 'bash "$1" thread-state --now 1600000200 --live-job no < "$2"' _ "$LAB" "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 10 ]; [ "$output" = "done" ]
}

@test "thread-state: ack-only thread waits under 60 min or with a live job, continues after" {
  printf '1600000000.000000\t🔍 Running RCA on Release run 1 — will reply with findings.\n' > "$BATS_TEST_TMPDIR/r.txt"
  run bash -c 'bash "$1" thread-state --now 1600001000 --live-job no < "$2"' _ "$LAB" "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 11 ]; [ "$output" = "wait" ]
  run bash -c 'bash "$1" thread-state --now 1600009999 --live-job yes < "$2"' _ "$LAB" "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 11 ]; [ "$output" = "wait" ]
  run bash -c 'bash "$1" thread-state --now 1600003601 --live-job no < "$2"' _ "$LAB" "$BATS_TEST_TMPDIR/r.txt"
  [ "$status" -eq 0 ]; [ "$output" = "continue" ]
}

@test "SKILL.md states the headless-cron path and the channel guard" {
  grep -q '_slack/webapi.sh' "$REPO_ROOT/labrun-rca/SKILL.md"
  grep -qi 'channel-guard' "$REPO_ROOT/labrun-rca/SKILL.md"
  grep -q 'not a failure alert' "$REPO_ROOT/labrun-rca/SKILL.md"
}

@test "alert-kind: failure words inside job names or excerpts do not mute a real failure" {
  for t in "Release failed: unsuccessful upload" "CI failed: unresolved symbol foo" "Job recovery-test failed" \
           "Build failed: 3 tests passed, 2 failed" "Release failed on job green-field" "Release timed out" "Run cancelled"; do
    run bash -c 'echo "$2" | bash "$1" alert-kind --branch main' _ "$LAB" "$t"
    [ "$status" -eq 0 ]
    [ "$output" = "failure" ]
  done
  run bash -c 'echo "Release Example failure" | bash "$1" alert-kind' _ "$LAB"
  [ "$status" -eq 0 ]
}

@test "thread-state: unterminated last line, multi-line replies and bad ts" {
  run bash -c 'printf "1600000000.000000\t*RCA done" | bash "$1" thread-state --now 1600000100' _ "$LAB"
  [ "$status" -eq 10 ]
  run bash -c 'printf "1600000000.000000\t🔍 Running RCA on x\n*RCA quoted by a human on a continuation line\n" | bash "$1" thread-state --now 1600000100' _ "$LAB"
  [ "$status" -eq 11 ]
  run bash -c 'printf "abc\t🔍 Running RCA\n\tfoo\n" | bash "$1" thread-state --now 1600000100' _ "$LAB"
  [ "$status" -eq 0 ]; [ "$output" = "continue" ]
}

@test "repo-allowed: case-insensitive, no glob expansion; repo-of accepts a job suffix but not a longer id" {
  run env LABRUN_SERVED_OWNERS=synx-data-labs bash "$LAB" repo-allowed Synx-Data-Labs/x
  [ "$status" -eq 0 ]
  run env LABRUN_SERVED_OWNERS='*' bash "$LAB" repo-allowed other/x
  [ "$status" -eq 7 ]
  lab repo-of "$RUN/job/1"
  [ "$output" = "repo=example-org/example-repo" ]
  lab repo-of "${RUN}9x"
  [ "$status" -eq 2 ]
}
