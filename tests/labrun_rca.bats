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

@test "SKILL.md calls the script for parse, extract-run and render-reply" {
  for s in parse extract-run render-reply; do
    grep -q "<skills-root>/labrun-rca/scripts/labrun.sh $s" "$REPO_ROOT/labrun-rca/SKILL.md"
  done
}
