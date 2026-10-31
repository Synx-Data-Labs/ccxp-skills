#!/usr/bin/env bats
# verify-site/scripts: match-testplan.sh, report.sh, check-routes.sh,
# check-lighthouse.sh (skip + threshold paths), preview-up.sh / preview-down.sh,
# ensure-deps.sh and the verify.sh orchestrator. Offline: a fake `curl` serves
# fixture pages, a fake `npm` stands in for the build and the preview server,
# a fake `node` stands in for the Playwright check scripts, a fake `gh` records
# the PR edit. No real site, no network, no browser is ever launched. Scratch
# files go to VERIFY_SITE_TMP under the test's own tmp dir, never /tmp.

load test_helper

SCR="$REPO_ROOT/verify-site/scripts"

setup() {
  export VERIFY_SITE_TMP="$BATS_TEST_TMPDIR/vs"
  export FAKE_CURL_DIR="$BATS_TEST_TMPDIR/site"
  export FAKE_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  mkdir -p "$VERIFY_SITE_TMP" "$FAKE_CURL_DIR"
  : > "$FAKE_CURL_LOG"
  BODY="$BATS_TEST_TMPDIR/body.md"
  RES="$BATS_TEST_TMPDIR/results.ndjson"
  OUT="$BATS_TEST_TMPDIR/updated.md"
}

teardown() {
  # never leak a preview process, whatever the test did
  if [ -f "$VERIFY_SITE_TMP/verify-site.env" ]; then
    # shellcheck disable=SC1091
    pid="$(. "$VERIFY_SITE_TMP/verify-site.env" 2>/dev/null; echo "${PREVIEW_PID:-}")"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
  return 0
}

# ---- fakes -----------------------------------------------------------------

# fake_curl: serves $FAKE_CURL_DIR. URL path "/" -> ROOT, "/a/b/" -> a__b__ .
# A page exists when its file does; <key>.code overrides the status. Honors
# -o FILE, -w '%{http_code}', -f. FAKE_CURL_DOWN=1 simulates a refused connect.
fake_curl() {
  _fakebin_dir
  cat > "$FAKEBIN/curl" <<'SHIM'
#!/usr/bin/env bash
out="" fmt="" fail=0 url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -*f*) fail=1 ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$FAKE_CURL_LOG"
if [ -n "${FAKE_CURL_DOWN:-}" ]; then
  [ -n "$fmt" ] && printf '000'
  exit 7
fi
path="/${url#*://*/}"; path="${path%%\?*}"
key="${path#/}"; key="${key//\//__}"; [ -z "$key" ] && key=ROOT
code=404; [ -f "$FAKE_CURL_DIR/$key" ] && code=200
[ -f "$FAKE_CURL_DIR/$key.code" ] && code="$(cat "$FAKE_CURL_DIR/$key.code")"
if [ -n "$out" ] && [ "$code" = 200 ]; then
  if [ "$out" = /dev/null ]; then :; else cat "$FAKE_CURL_DIR/$key" > "$out"; fi
fi
[ -n "$fmt" ] && printf '%s' "$code"
if [ "$fail" = 1 ] && [ "$code" -ge 400 ]; then exit 22; fi
exit 0
SHIM
  chmod +x "$FAKEBIN/curl"
}

# fake_npm: logs argv to $FAKE_NPM_LOG; `run build` exits $FAKE_NPM_BUILD_RC
# (default 0); `run preview`/`run start` become a 30 s sleep (the "server").
fake_npm() {
  _fakebin_dir
  export FAKE_NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  cat > "$FAKEBIN/npm" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_NPM_LOG"
case "$*" in
  "run build"*) exit "${FAKE_NPM_BUILD_RC:-0}" ;;
  "run preview"*|"run start"*) exec sleep 30 ;;
  install*) exit "${FAKE_NPM_INSTALL_RC:-0}" ;;
esac
exit 0
SHIM
  chmod +x "$FAKEBIN/npm"
}

# fake_node: stands in for the Playwright scripts. Emits one passing record for
# the check named by the script file (a11y / responsive) and logs the call.
fake_node() {
  _fakebin_dir
  export FAKE_NODE_LOG="$BATS_TEST_TMPDIR/node.log"
  cat > "$FAKEBIN/node" <<'SHIM'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_NODE_LOG"
case "$1" in
  *a11y*) echo '{"check":"a11y","route":"/","status":"pass","detail":"no violations"}' ;;
  *responsive*) echo '{"check":"responsive","route":"/","status":"pass","detail":"ok"}' ;;
esac
exit 0
SHIM
  chmod +x "$FAKEBIN/node"
}

# site_project: a project dir that looks like an Astro site; prints its path.
site_project() {
  local d="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$d"; : > "$d/astro.config.mjs"
  printf '%s\n' "$d"
}

# env_file [url]: the env file preview-up.sh would have written.
env_file() {
  printf 'PREVIEW_PID=1\nURL=%s\nLOG_FILE=/dev/null\n' "${1:-http://127.0.0.1:4321}" \
    > "$VERIFY_SITE_TMP/verify-site.env"
}

res() {  # res <check> <status> [route]
  printf '{"check":"%s","route":"%s","status":"%s","detail":"d"}\n' "$1" "${3:-/}" "$2" >> "$RES"
}

match() { run bash "$SCR/match-testplan.sh" "$BODY" "$RES" "$OUT"; }

# ---- match-testplan.sh -----------------------------------------------------

@test "match: ticks an item only when its check family passed; leaves the rest" {
  printf '%s\n' '## Test plan' '- [ ] Every route returns 200' '- [ ] Lighthouse perf >= 85' \
    '- [ ] Mobile 375px has no horizontal overflow' '- [ ] a11y: axe reports nothing' \
    '- [ ] Copy reads well' > "$BODY"
  res routes pass; res lighthouse fail; res responsive pass; res a11y pass
  match
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  grep -qF -- '- [x] Every route returns 200' "$OUT"
  grep -qF -- '- [ ] Lighthouse perf >= 85' "$OUT"
  grep -qF -- '- [x] Mobile 375px' "$OUT"
  grep -qF -- '- [x] a11y: axe' "$OUT"
  grep -qF -- '- [ ] Copy reads well' "$OUT"
  grep -qF '## Test plan' "$OUT"
}

@test "match: one failing route fails the whole family" {
  printf '%s\n' '- [ ] All routes return 200' > "$BODY"
  res routes pass /; res routes fail /blog/; res routes pass /about/
  match
  [ "$output" = 0 ]
  grep -qF -- '- [ ] All routes return 200' "$OUT"
}

@test "match: a family with no results, or only skips, never ticks" {
  printf '%s\n' '- [ ] Lighthouse >= 85' '- [ ] a11y clean' '- [ ] Every route returns 200' > "$BODY"
  res lighthouse skip; res a11y skip
  match
  [ "$output" = 0 ]
  [ "$(grep -c -- '- \[ \]' "$OUT")" = 3 ]
}

@test "match: an unknown status counts as a failure, not a pass" {
  printf '%s\n' '- [ ] Every route returns 200' > "$BODY"
  res routes pass; res routes error
  match
  [ "$output" = 0 ]
}

@test "match: an unparseable results line fails closed, ticking nothing" {
  printf '%s\n' '- [ ] Every route returns 200' > "$BODY"
  res routes pass
  echo 'this is not json' >> "$RES"
  match
  [ "${lines[-1]}" = 0 ]
  if grep -q '\[x\]' "$OUT"; then return 1; fi
}

@test "match: a final fail record without a trailing newline is not dropped" {
  printf '%s\n' '- [ ] Every route returns 200' > "$BODY"
  res routes pass
  printf '%s' '{"check":"routes","status":"fail"}' >> "$RES"
  match
  [ "${lines[-1]}" = 0 ]
  if grep -q '\[x\]' "$OUT"; then return 1; fi
}

@test "match: the build item ticks when the script runs at all" {
  printf '%s\n' '- [ ] `npm run build` exits 0' '- [ ] Build green' > "$BODY"
  : > "$RES"
  match
  [ "$output" = 2 ]
}

@test "match: already-ticked items stay ticked, never unticked, never counted" {
  printf '%s\n' '- [x] Every route returns 200' '- [X] Lighthouse ok' '- [ ] a11y clean' > "$BODY"
  res routes fail; res lighthouse fail; res a11y pass
  match
  [ "$output" = 1 ]
  grep -qF -- '- [x] Every route returns 200' "$OUT"
  grep -qF -- '- [X] Lighthouse ok' "$OUT"
  grep -qF -- '- [x] a11y clean' "$OUT"
}

@test "match: keywords are whole words and case-insensitive (BSD and GNU awk alike)" {
  printf '%s\n' '- [ ] LIGHTHOUSE scores' '- [ ] Perf over 90' '- [ ] SEO-friendly titles' \
    '- [ ] A11Y pass' '- [ ] Check subroutes copy' '- [ ] The performer list' '- [ ] See rack 2000' \
    '  - [ ] Indented route check' '* [ ] Not a dash bullet route' > "$BODY"
  res lighthouse pass; res a11y pass; res routes pass
  match
  grep -qF -- '- [x] LIGHTHOUSE scores' "$OUT"
  grep -qF -- '- [x] Perf over 90' "$OUT"
  grep -qF -- '- [x] SEO-friendly' "$OUT"
  grep -qF -- '- [x] A11Y pass' "$OUT"
  grep -qF -- '- [ ] Check subroutes copy' "$OUT"
  grep -qF -- '- [ ] See rack 2000' "$OUT"
  grep -qF -- '  - [x] Indented route check' "$OUT"
  grep -qF -- '* [ ] Not a dash bullet route' "$OUT"
}

@test "match: text other than the checkbox is preserved byte for byte" {
  printf '%s\n' '# Title' '' 'Some prose with [ ] brackets.' '- [ ] Every route returns 200 [ ] again' '```' 'code' '```' > "$BODY"
  res routes pass
  match
  [ "$output" = 1 ]
  diff <(sed 's/\[x\]/[ ]/' "$OUT") "$BODY"
}

@test "match: writes only to the output file and VERIFY_SITE_TMP stays untouched" {
  printf '%s\n' '- [ ] Every route returns 200' > "$BODY"; res routes pass
  match
  [ -z "$(ls -A "$VERIFY_SITE_TMP")" ]
}

@test "match: missing arguments or results file exit non-zero" {
  run bash "$SCR/match-testplan.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' '- [ ] Every route returns 200' > "$BODY"
  run bash "$SCR/match-testplan.sh" "$BODY" "$BATS_TEST_TMPDIR/nope" "$OUT"
  [ "$status" -ne 0 ]
}

# ---- report.sh -------------------------------------------------------------

@test "report: per-family counts, failing routes, and the human-only items" {
  res routes pass /; res routes fail /blog/; res routes skip /x/
  res a11y pass
  printf '{"check":"responsive","route":"/m","status":"fail","detail":"overflow at 375"}\n' >> "$RES"
  printf '%s\n' '- [ ] Copy reads well' '- [x] Routes load' > "$OUT"
  run bash "$SCR/report.sh" "$RES" "$BODY" "$OUT" 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"# verify-site report"* ]]
  [[ "$output" == *"**Items auto-ticked**: 3"* ]]
  [[ "$output" == *"### routes — 1 pass, 1 fail, 1 skip"* ]]
  [[ "$output" == *'`/blog/`: d'* ]]
  [[ "$output" == *"### a11y — 1 pass, 0 fail, 0 skip"* ]]
  [[ "$output" == *"### lighthouse — 0 pass, 0 fail, 0 skip"* ]]
  [[ "$output" == *'`/m`: overflow at 375'* ]]
  [[ "$output" == *"  - [ ] Copy reads well"* ]]
  [[ "$output" != *"Routes load"* ]]
}

@test "report: says none when nothing is left for a human" {
  : > "$RES"; printf '%s\n' '- [x] done' > "$OUT"
  run bash "$SCR/report.sh" "$RES" "$BODY" "$OUT" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"_(none)_"* ]]
}

@test "report: a missing results file exits non-zero" {
  run bash "$SCR/report.sh" "$BATS_TEST_TMPDIR/nope" "$BODY" "$OUT" 0
  [ "$status" -ne 0 ]
}

# ---- check-routes.sh -------------------------------------------------------

routes() { run bash -c "printf '%s\n' \"\$@\" | bash '$SCR/check-routes.sh'" _ "$@"; }

@test "routes: 200 passes, anything else fails with the code; exit 1 on any failure" {
  fake_curl; env_file http://127.0.0.1:4321
  : > "$FAKE_CURL_DIR/ROOT"; : > "$FAKE_CURL_DIR/blog__"; : > "$FAKE_CURL_DIR/moved"
  echo 301 > "$FAKE_CURL_DIR/moved.code"
  routes / /blog/ /moved /missing/
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq -rs 'map(.status) | join(",")')" = "pass,pass,fail,fail" ]
  [ "$(printf '%s\n' "$output" | jq -rs '.[2].detail')" = 'HTTP 301' ]
  [ "$(printf '%s\n' "$output" | jq -rs '.[3].detail')" = 'HTTP 404' ]
  [ "$(printf '%s\n' "$output" | jq -rs 'map(.check) | unique | join(",")')" = routes ]
}

@test "routes: all passing exits 0; leading slash added; blank lines skipped" {
  fake_curl; env_file http://127.0.0.1:4321
  : > "$FAKE_CURL_DIR/ROOT"; : > "$FAKE_CURL_DIR/blog__"
  routes "" / blog/ ""
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [ "$(printf '%s\n' "$output" | jq -rs '.[1].route')" = "/blog/" ]
  grep -qx 'http://127.0.0.1:4321/blog/' "$FAKE_CURL_LOG"
}

@test "routes: an unreachable server is a failure, never a pass" {
  fake_curl; env_file; export FAKE_CURL_DOWN=1
  routes /
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq -r '.status')" = fail ]
}

@test "routes: only ever requests the preview URL from the env file" {
  fake_curl; env_file http://127.0.0.1:4321
  : > "$FAKE_CURL_DIR/ROOT"
  routes / /a/
  run grep -vE '^http://127\.0\.0\.1:4321/' "$FAKE_CURL_LOG"
  [ "$status" -eq 1 ]
}

@test "routes: no env file means no run (cannot guess a URL)" {
  fake_curl
  routes /
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_CURL_LOG" ]
}

# ---- check-lighthouse.sh / check-a11y.sh / check-responsive.sh -------------

@test "lighthouse: not installed is a skip record (and match then never ticks it)" {
  local root; root="$(space_skills_root)"
  env_file
  run bash -c "echo / | bash '$root/verify-site/scripts/check-lighthouse.sh'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = skip ]
}

@test "lighthouse: scores are compared with the thresholds (fake lighthouse binary)" {
  local root; root="$(space_skills_root)"
  mkdir -p "$root/verify-site/node_modules/.bin"
  cat > "$root/verify-site/node_modules/.bin/lighthouse" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in --output-path=*) o="${a#--output-path=}";; esac; done
echo "$1" >> "$FAKE_LH_LOG"
case "$1" in
  *bad*) echo "boom" >&2; exit 1 ;;
  *slow*) echo '{"categories":{"performance":{"score":0.5},"accessibility":{"score":1},"best-practices":{"score":1},"seo":{"score":1}}}' > "$o" ;;
  *) echo '{"categories":{"performance":{"score":0.95},"accessibility":{"score":0.96},"best-practices":{"score":1},"seo":{"score":0.9}}}' > "$o" ;;
esac
SHIM
  chmod +x "$root/verify-site/node_modules/.bin/lighthouse"
  export FAKE_LH_LOG="$BATS_TEST_TMPDIR/lh.log"
  env_file http://127.0.0.1:4321
  run bash -c "printf '%s\n' / slow/ bad/ | bash '$root/verify-site/scripts/check-lighthouse.sh'"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | jq -rs 'map(.status) | join(",")')" = "pass,fail,fail" ]
  [[ "$output" == *"perf 50<80"* ]]
  [[ "$output" == *"lighthouse failed: boom"* ]]
  [ "$(printf '%s\n' "$output" | jq -rs '.[0].scores.performance')" = 95 ]
  [ -z "$(ls "$VERIFY_SITE_TMP" | grep -E '^lh-' || true)" ]
  if grep -vE '^http://127\.0\.0\.1:4321/' "$FAKE_LH_LOG"; then return 1; fi
}

@test "a11y and responsive: empty stdin is a skip record, no browser started" {
  env_file
  for c in a11y responsive; do
    run bash -c "bash '$SCR/check-$c.sh' < /dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.status')" = skip ]
    [ "$(printf '%s' "$output" | jq -r '.check')" = "$c" ]
  done
}

# ---- preview-up.sh / preview-down.sh ---------------------------------------

@test "preview-up: no framework and no config exits 2 and writes no env file" {
  fake_curl; fake_npm
  local d="$BATS_TEST_TMPDIR/empty"; mkdir -p "$d"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not auto-detect framework"* ]]
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
  [ ! -s "$FAKE_NPM_LOG" ]
}

@test "preview-up/down: detects Astro, builds, serves, records pid and url, then stops" {
  fake_curl; fake_npm
  : > "$FAKE_CURL_DIR/ROOT"
  local d; d="$(site_project)"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preview up"* ]]
  assert_calls "$FAKE_NPM_LOG" '^run build$'
  assert_calls "$FAKE_NPM_LOG" '^run preview -- --host 127\.0\.0\.1 --port 4321$'
  grep -qx 'URL=http://127.0.0.1:4321' "$VERIFY_SITE_TMP/verify-site.env"
  pid="$(sed -n 's/^PREVIEW_PID=//p' "$VERIFY_SITE_TMP/verify-site.env")"
  kill -0 "$pid"
  run bash "$SCR/preview-down.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]
  if kill -0 "$pid" 2>/dev/null; then return 1; fi
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
}

@test "preview-up: Next and Vite defaults use their own ports" {
  fake_curl; fake_npm
  : > "$FAKE_CURL_DIR/ROOT"
  local d="$BATS_TEST_TMPDIR/next"; mkdir -p "$d"; : > "$d/next.config.js"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 0 ]
  grep -qx 'URL=http://127.0.0.1:3000' "$VERIFY_SITE_TMP/verify-site.env"
  assert_calls "$FAKE_NPM_LOG" '^run start -- -p 3000$'
  bash "$SCR/preview-down.sh"
  d="$BATS_TEST_TMPDIR/vite"; mkdir -p "$d"; : > "$d/vite.config.ts"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 0 ]
  grep -qx 'URL=http://127.0.0.1:4173' "$VERIFY_SITE_TMP/verify-site.env"
  bash "$SCR/preview-down.sh"
}

@test "preview-up: .verify-site.json overrides the detected commands and url" {
  fake_curl; fake_npm
  : > "$FAKE_CURL_DIR/ROOT"
  local d; d="$(site_project)"
  printf '{"preview":{"build":"echo custom-build","start":"exec sleep 30","url":"http://127.0.0.1:5999"}}\n' > "$d/.verify-site.json"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom-build"* ]]
  grep -qx 'URL=http://127.0.0.1:5999' "$VERIFY_SITE_TMP/verify-site.env"
  [ ! -s "$FAKE_NPM_LOG" ]
  bash "$SCR/preview-down.sh"
}

@test "preview-up: a server process that dies exits 3, cleans the env file, prints the log" {
  fake_curl
  local d; d="$(site_project)"
  printf '{"preview":{"build":"true","start":"echo boom-from-server; exit 1","url":"http://127.0.0.1:5999"}}\n' > "$d/.verify-site.json"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 3 ]
  [[ "$output" == *"preview process died"* ]]
  [[ "$output" == *"boom-from-server"* ]]
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
}

@test "preview-up: a second run stops the previous preview first" {
  fake_curl; fake_npm
  : > "$FAKE_CURL_DIR/ROOT"
  local d; d="$(site_project)"
  bash -c "cd '$d' && bash '$SCR/preview-up.sh'" >/dev/null
  first="$(sed -n 's/^PREVIEW_PID=//p' "$VERIFY_SITE_TMP/verify-site.env")"
  run bash -c "cd '$d' && bash '$SCR/preview-up.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Previous preview (pid $first) still running"* ]]
  if kill -0 "$first" 2>/dev/null; then return 1; fi
  bash "$SCR/preview-down.sh"
}

@test "preview-down: nothing to stop exits 0; a stale env file is removed" {
  run bash "$SCR/preview-down.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to stop"* ]]
  printf 'PREVIEW_PID=999999\nURL=http://127.0.0.1:1\n' > "$VERIFY_SITE_TMP/verify-site.env"
  run bash "$SCR/preview-down.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
}

# ---- ensure-deps.sh --------------------------------------------------------

@test "ensure-deps: skips when playwright and lighthouse are already installed" {
  fake_npm
  local root; root="$(space_skills_root)"
  mkdir -p "$root/verify-site/node_modules/playwright" "$root/verify-site/node_modules/lighthouse"
  run bash "$root/verify-site/scripts/ensure-deps.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$FAKE_NPM_LOG" ]
}

@test "ensure-deps: installs into the skill dir, honoring NPM_REGISTRY, then fetches chromium" {
  fake_npm
  local root; root="$(space_skills_root)"
  mkdir -p "$root/verify-site/node_modules/.bin"
  printf '#!/usr/bin/env bash\necho "pw $*" >> "$FAKE_NPM_LOG"\n' > "$root/verify-site/node_modules/.bin/playwright"
  chmod +x "$root/verify-site/node_modules/.bin/playwright"
  NPM_REGISTRY=https://registry.example.invalid run bash "$root/verify-site/scripts/ensure-deps.sh"
  [ "$status" -eq 0 ]
  assert_calls "$FAKE_NPM_LOG" '^install --no-audit --no-fund --registry https://registry\.example\.invalid$'
  assert_calls "$FAKE_NPM_LOG" '^pw install chromium$'
  [[ "$output" == *"deps ready"* ]]
}

@test "ensure-deps: a failed npm install exits non-zero without claiming success" {
  fake_npm; export FAKE_NPM_INSTALL_RC=1
  local root; root="$(space_skills_root)"
  run bash "$root/verify-site/scripts/ensure-deps.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"deps ready"* ]]
}

# ---- verify.sh -------------------------------------------------------------

@test "verify.sh: PR number is required and must be numeric" {
  run bash "$SCR/verify.sh"
  [ "$status" -ne 0 ]
  run bash "$SCR/verify.sh" 12abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be numeric"* ]]
}

@test "verify.sh: an unresolvable repo exits 2 before building anything" {
  fake_npm
  local root; root="$(space_skills_root)"
  mkdir -p "$BATS_TEST_TMPDIR/gh"; fake_gh "$BATS_TEST_TMPDIR/gh"
  run bash "$root/verify-site/scripts/verify.sh" 7
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_NPM_LOG" ]
}

# e2e_setup: fake gh/curl/npm/node, a skills root with a space, a site project
e2e_setup() {
  fake_curl; fake_npm; fake_node
  ROOT="$(space_skills_root)"
  mkdir -p "$ROOT/verify-site/node_modules/playwright" "$ROOT/verify-site/node_modules/lighthouse"
  GHFX="$BATS_TEST_TMPDIR/ghfx"; mkdir -p "$GHFX"
  fake_gh "$GHFX"
  echo example-org/example-repo > "$GHFX/repo_view_json_nameWithOwner_jq_nameWithOwner.txt"
  printf '%s\n' '## Test plan' '- [ ] Every route returns 200' '- [ ] npm run build is green' \
    '- [ ] Lighthouse perf >= 85' '- [ ] Mobile 375px stacks' '- [ ] Copy review' \
    > "$GHFX/pr_view_7_repo_example_org_example_repo_json_body_jq_body.txt"
  : > "$GHFX/pr_edit_7_repo_example_org_example_repo_body_file.txt"
  : > "$FAKE_CURL_DIR/ROOT"; : > "$FAKE_CURL_DIR/blog__"
  printf '<urlset><loc>https://prod.example/</loc>\n<loc>https://prod.example/blog/</loc></urlset>' > "$FAKE_CURL_DIR/sitemap.xml"
  PROJ="$(site_project)"
}

@test "verify.sh end to end (all fakes): ticks what passed, edits the PR once, tears down" {
  e2e_setup
  run bash -c "cd '$PROJ' && bash '$ROOT/verify-site/scripts/verify.sh' 7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Discovered 2 routes"* ]]
  [[ "$output" == *"Ticked 3 item(s)."* ]]
  assert_calls "$FAKE_GH_LOG" '^pr edit 7 --repo example-org/example-repo --body-file '
  [ "$(grep -c '^pr edit' "$FAKE_GH_LOG")" = 1 ]
  [[ "$output" == *"- [ ] Lighthouse perf >= 85"* ]]
  [[ "$output" == *"- [ ] Copy review"* ]]
  [[ "$output" == *"### lighthouse — 0 pass, 0 fail, 1 skip"* ]]
  [ "$(wc -l < "$VERIFY_SITE_TMP/verify-site-results.ndjson" | tr -d ' ')" -ge 4 ]
  # torn down unconditionally
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
  # nothing was posted anywhere but the one PR edit
  refute_calls "$FAKE_GH_LOG" '^(pr (comment|review|merge)|api|issue)'
}

@test "verify.sh end to end: a failing route leaves its item unticked, still tears down" {
  e2e_setup
  rm "$FAKE_CURL_DIR/blog__"
  run bash -c "cd '$PROJ' && bash '$ROOT/verify-site/scripts/verify.sh' 7"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ticked 2 item(s)."* ]]
  [[ "$output" == *'`/blog/`: HTTP 404'* ]]
  [[ "$output" == *"- [ ] Every route returns 200"* ]]
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
}

@test "verify.sh end to end: a build failure stops before any check and tears down" {
  e2e_setup
  export FAKE_NPM_BUILD_RC=1
  run bash -c "cd '$PROJ' && bash '$ROOT/verify-site/scripts/verify.sh' 7"
  # the build error is swallowed by `| tail -5` in preview-up.sh today; the
  # run must at minimum never edit the PR or leave a server behind
  refute_calls "$FAKE_GH_LOG" '^pr edit'
  [ ! -f "$VERIFY_SITE_TMP/verify-site.env" ]
}

# ---- contract --------------------------------------------------------------

@test "no verify-site script posts, pushes or calls gh/git directly outside verify.sh" {
  run grep -nE '(^|[;&|(]) *(gh|git|ssh) |git push|slack' <(cat "$SCR"/check-*.sh "$SCR"/match-testplan.sh "$SCR"/report.sh "$SCR"/preview-*.sh | grep -vE '^[[:space:]]*#')
  [ "$status" -eq 1 ]
}

@test "scripts keep scratch files under VERIFY_SITE_TMP: no bare /tmp in code lines" {
  run grep -nE '(^|[^{}_A-Za-z"])/tmp/' <(cat "$SCR"/*.sh | grep -vE '^[[:space:]]*#')
  [ "$status" -eq 1 ]
}

@test "SKILL.md names only scripts that exist, and does not name check-links.sh" {
  local s
  for s in $(grep -oE '[a-z0-9-]+\.sh' "$REPO_ROOT/verify-site/SKILL.md" | sort -u); do
    [ -f "$SCR/$s" ] || [ -f "$REPO_ROOT/_gh/$s" ] || { echo "SKILL.md names missing script: $s" >&2; return 1; }
  done
  if grep -q 'check-links' "$REPO_ROOT/verify-site/SKILL.md"; then return 1; fi
}
