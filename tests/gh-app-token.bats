#!/usr/bin/env bats
# Tests for _gh/gh-app-token.sh — GitHub App installation-token minter
# (T20260923-343482). curl/openssl are stubbed via the GH_APP_TOKEN_* seams.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/_gh/gh-app-token.sh"
  cd "$BATS_TEST_TMPDIR"
  LOG="$BATS_TEST_TMPDIR/curl.log"
  : >"$LOG"
  printf 'FAKEPEM\n' >key.pem

  # openssl stub: `dgst -sha256 -sign <key>` -> fixed bytes
  cat >openssl <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'SIGBYTES'
EOF
  # curl stub: logs argv, replies per URL; STUB_MODE tweaks failures
  cat >curl <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
url="${@: -1}"
case "$url" in
  */installation)
    [[ "${STUB_MODE:-}" == "lookup404" ]] && { printf '{"message":"Not Found"}\n404'; exit 0; }
    printf '{"id":4242}\n200' ;;
  */access_tokens)
    [[ "${STUB_MODE:-}" == "notoken" ]] && { printf '{}\n201'; exit 0; }
    printf '{"token":"ghs_faketoken"}\n201' ;;
esac
EOF
  chmod +x openssl curl
  export CURL_LOG="$LOG" GH_APP_TOKEN_CURL="$PWD/curl" GH_APP_TOKEN_OPENSSL="$PWD/openssl"
  export GH_APP_TOKEN_NOW=1700000000
  unset GH_APP_ID GH_APP_PRIVATE_KEY GH_APP_PRIVATE_KEY_FILE GH_APP_REPO
}

b64d() { printf '%s' "$1" | tr '_-' '/+' | base64 -d 2>/dev/null; }

@test "mints a token: stdout is the token alone" {
  run --separate-stderr bash "$SCRIPT" --app-id 99 --key-file key.pem --repo acme/widgets
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_faketoken" ]
}

@test "JWT header and claims have the expected shape" {
  bash "$SCRIPT" --app-id 99 --key-file key.pem --repo acme/widgets >/dev/null
  jwt="$(grep -o 'Bearer [^ ]*' "$LOG" | head -1 | cut -d' ' -f2)"
  IFS=. read -r h c s <<<"$jwt"
  [ "$(b64d "$h")" = '{"alg":"RS256","typ":"JWT"}' ]
  [ "$(b64d "$c" | jq -c .)" = '{"iat":1699999940,"exp":1700000540,"iss":"99"}' ]
  [ "$s" = "$(printf 'SIGBYTES' | base64 | tr -d '\n=' | tr '+/' '-_')" ]
}

@test "installation lookup then token exchange scoped to the repo name" {
  bash "$SCRIPT" --app-id 99 --key-file key.pem --repo acme/widgets >/dev/null
  grep -q -- '-X GET .*/repos/acme/widgets/installation$' "$LOG"
  grep -q -- '-X POST .*-d {"repositories":\["widgets"\]} .*/app/installations/4242/access_tokens$' "$LOG"
}

@test "inputs fall back to env, private key by contents" {
  GH_APP_ID=99 GH_APP_REPO=acme/widgets GH_APP_PRIVATE_KEY=PEMTEXT \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_faketoken" ]
}

@test "missing app id fails non-zero with empty stdout" {
  run --separate-stderr bash "$SCRIPT" --key-file key.pem --repo acme/widgets
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"missing app id"* ]]
}

@test "missing or malformed repo fails" {
  run bash "$SCRIPT" --app-id 99 --key-file key.pem
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --app-id 99 --key-file key.pem --repo noslash
  [ "$status" -ne 0 ]
}

@test "missing private key fails" {
  run --separate-stderr bash "$SCRIPT" --app-id 99 --repo acme/widgets
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"missing private key"* ]]
}

@test "unreadable key file fails" {
  run bash "$SCRIPT" --app-id 99 --key-file nope.pem --repo acme/widgets
  [ "$status" -ne 0 ]
}

@test "installation lookup HTTP error exits non-zero with the API message" {
  STUB_MODE=lookup404 run --separate-stderr bash "$SCRIPT" --app-id 99 --key-file key.pem --repo acme/widgets
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"404"* && "$stderr" == *"Not Found"* ]]
}

@test "token-less response exits non-zero" {
  STUB_MODE=notoken run --separate-stderr bash "$SCRIPT" --app-id 99 --key-file key.pem --repo acme/widgets
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no token"* ]]
}

@test "header documents usage and stays company-neutral" {
  head -40 "$SCRIPT" | grep -q 'Usage:'
  ! grep -qiE 'drata|synx|1password|\bop (read|inject)' "$SCRIPT"
}
