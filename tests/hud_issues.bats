#!/usr/bin/env bats
# Tests for the customer-issue statistics of the ccxp-hud data helper (hud/scripts/hud-issues.sh).
# A fake `gh` on PATH answers from a fixture and logs its argv and GH_CONFIG_DIR; nothing here talks to the
# network or touches the developer's real state.

load test_helper
ISSUES="$REPO_ROOT/hud/scripts/hud-issues.sh"
DATA="$REPO_ROOT/hud/scripts/hud-data.sh"
# 2026-11-05 12:00:00 UTC
NOW=1793880000

setup() {
  export HUD_BEHIND_STATE_DIR="$BATS_TEST_TMPDIR/hud-behind" # the behind fetch never touches ~/.claude
  export HUD_ISSUES_STATE_DIR="$BATS_TEST_TMPDIR/hud-issues" HUD_QUEUE_STATE_DIR="$BATS_TEST_TMPDIR/hud-queue" HUD_ISSUES_SYNC=1 HUD_HWM_NOW="$NOW"
  unset HUD_ISSUES_TTL HUD_ISSUES_NOW HUD_ISSUES_DELIVERED_LABEL
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_FIXTURE="$BATS_TEST_TMPDIR/issues.json"
  cat > "$BATS_TEST_TMPDIR/fakebin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s | GH_CONFIG_DIR=%s\n' "$*" "${GH_CONFIG_DIR:-}" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
cat "$GH_FIXTURE"
GH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
}

# $1 state OPEN|CLOSED $2 createdAt $3 closedAt ("" = null) $4.. labels
_issue() {
  local st="$1" c="$2" x="$3" labels="" l; shift 3
  for l in "$@"; do labels="$labels${labels:+,}{\"name\":\"$l\"}"; done
  printf '{"state":"%s","createdAt":"%s","closedAt":%s,"labels":[%s]}' "$st" "$c" "$([ -n "$x" ] && printf '"%s"' "$x" || printf null)" "$labels"
}
_json() { bash -c "source '$ISSUES'; hud-issues-json $*"; }

# 3 open (one delivered), 2 closed; opened 2026-11-04 (7d window), 2026-10-20 (30d), 2026-08-01 (180d)
_fixture() {
  cat > "$GH_FIXTURE" <<JSON
[$(_issue OPEN 2026-11-04T01:00:00Z "" status:new type:bug),
 $(_issue OPEN 2026-10-20T01:00:00Z "" status:delivered),
 $(_issue OPEN 2026-08-01T01:00:00Z "" status:in-progress),
 $(_issue CLOSED 2026-08-02T01:00:00Z 2026-08-03T01:00:00Z status:wontfix),
 $(_issue CLOSED 2026-10-25T01:00:00Z 2026-11-01T01:00:00Z status:delivered)]
JSON
}

@test "count: open total and the open ones without the delivered label" {
  _fixture
  run bash -c "source '$ISSUES'; sl-issues-count status:delivered < '$GH_FIXTURE'"
  [ "$output" = '{"open":3,"undelivered":2}' ]
}

@test "count: a custom delivered label is honoured; bad input prints nothing" {
  _fixture
  run bash -c "source '$ISSUES'; sl-issues-count status:new < '$GH_FIXTURE'"
  [ "$output" = '{"open":3,"undelivered":2}' ]
  run bash -c "source '$ISSUES'; echo 'nope' | sl-issues-count status:delivered"
  [ -z "$output" ]
}

@test "series: +1 at createdAt, -1 at closedAt, oldest first, in epoch seconds" {
  cat > "$GH_FIXTURE" <<JSON
[$(_issue CLOSED 2026-11-01T00:00:00Z 2026-11-03T00:00:00Z), $(_issue OPEN 2026-11-02T00:00:00Z "")]
JSON
  run bash -c "source '$ISSUES'; sl-issues-series < '$GH_FIXTURE' | cut -f2 | tr '\n' ' '"
  [ "$output" = "1 2 1 " ]
}

@test "json: off for an invalid repo slug, gh is never called" {
  _fixture
  run _json "'not a slug'"
  [ "$output" = "null" ]
  [ ! -e "$GH_LOG" ]
}

@test "json: counts plus the 180/30/7 day maxima from the created/closed history" {
  _fixture
  run _json acme/support
  [ "$status" -eq 0 ]
  # open count over time: 08-01 1, 08-02 2, 08-03 1, 10-20 2, 10-25 3, 11-01 2, 11-04 3 ; now (11-05) 3
  [ "$output" = '{"open":3,"undelivered":2,"hwm":{"d180":3,"d30":3,"d7":3}}' ]
  grep -q -- "issue list --repo acme/support --state all" "$GH_LOG"
}

@test "json: a past peak counts in its window only; the value at the window start counts" {
  # peak of 3 open on 10-26..10-28 (before the 7d window starts on 10-29), 1 open now
  cat > "$GH_FIXTURE" <<JSON
[$(_issue OPEN 2026-08-01T00:00:00Z ""),
 $(_issue CLOSED 2026-10-26T00:00:00Z 2026-10-28T00:00:00Z),
 $(_issue CLOSED 2026-10-26T01:00:00Z 2026-10-28T01:00:00Z)]
JSON
  run _json acme/support
  [ "$output" = '{"open":1,"undelivered":1,"hwm":{"d180":3,"d30":3,"d7":1}}' ]
}

@test "json: one gh call, then the cache answers until the TTL passes" {
  _fixture
  _json acme/support >/dev/null
  _json acme/support >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 1 ]
  HUD_ISSUES_NOW=$((NOW + 901)) _json acme/support >/dev/null
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" = 2 ]
}

@test "json: gh failure is silent: null with no cache, the old answer with one" {
  GH_FAIL=1 run _json acme/support
  [ "$output" = "null" ]
  [ -z "$(echo "$output" | grep -i error)" ]
  _fixture
  HUD_ISSUES_NOW=$((NOW + 5000)) run _json acme/support
  [[ "$output" == '{"open":3,"undelivered":2'* ]]
  GH_FAIL=1 HUD_ISSUES_NOW=$((NOW + 10000)) run _json acme/support
  [[ "$output" == '{"open":3,"undelivered":2'* ]]
}

@test "json: ghConfigDir reaches gh as GH_CONFIG_DIR; a missing dir falls back to the default" {
  _fixture
  mkdir -p "$BATS_TEST_TMPDIR/ghcfg"
  _json acme/support "'$BATS_TEST_TMPDIR/ghcfg'" >/dev/null
  grep -q "GH_CONFIG_DIR=$BATS_TEST_TMPDIR/ghcfg" "$GH_LOG"
  HUD_ISSUES_NOW=$((NOW + 2000)) _json acme/support "'$BATS_TEST_TMPDIR/missing'" >/dev/null
  tail -n 1 "$GH_LOG" | grep -q "GH_CONFIG_DIR=$"
}

@test "json: the refresh is detached when HUD_ISSUES_SYNC is unset; the call returns at once with null" {
  _fixture
  unset HUD_ISSUES_SYNC
  run _json acme/support
  [ "$output" = "null" ]
}

@test "hud-data.sh: no issues config means no lookup and issues:null" {
  _fixture
  run bash -c "echo '{\"cwd\":\"$BATS_TEST_TMPDIR\"}' | HUD_NIGHTLY_OFF=1 bash '$DATA'"
  [ "$(jq -c .issues <<<"$output")" = "null" ]
  ! grep -q "issue list" "$GH_LOG" 2>/dev/null
}

@test "hud-data.sh: stdin issues.repo adds the issues object next to the other keys" {
  _fixture
  run bash -c "echo '{\"cwd\":\"$BATS_TEST_TMPDIR\",\"issues\":{\"repo\":\"acme/support\"}}' | bash '$DATA'"
  [ "$(jq -c '.issues | {open, undelivered}' <<<"$output")" = '{"open":3,"undelivered":2}' ]
  [ "$(jq -r '.repo | type' <<<"$output")" = "string" ]
}

@test "issues and the queue share the window logic but not their series" {
  _fixture
  _json acme/support >/dev/null
  ls "$HUD_QUEUE_STATE_DIR"/hist-* "$HUD_QUEUE_STATE_DIR"/samples-* >/dev/null
  [ "$(ls "$HUD_QUEUE_STATE_DIR" | grep -c '^hist-')" = 1 ]
}
