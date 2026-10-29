#!/usr/bin/env bats
# Tests for agent-pairing/scripts/terms.sh (the ccxp-agent's terms.json store).

load test_helper
TERMS="$REPO_ROOT/agent-pairing/scripts/terms.sh"

setup() {
  export CCXP_TERMS_FILE="$BATS_TEST_TMPDIR/profile/terms.json"
  unset CLAUDE_CONFIG_DIR
  cd "$BATS_TEST_TMPDIR"   # not inside a git repo unless a test says so
}

t() { bash "$TERMS" "$@"; }

@test "add records a definition; file is 600 JSON with the full schema" {
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ "$output" = "noted: RCA = root cause analysis" ]
  [ "$(stat -c %a "$CCXP_TERMS_FILE" 2>/dev/null || stat -f %Lp "$CCXP_TERMS_FILE")" = "600" ]
  d=$(jq -c '.terms.RCA.defs[0]' "$CCXP_TERMS_FILE")
  [ "$(jq -r .text <<<"$d")" = "root cause analysis" ]
  [ "$(jq -r .scope <<<"$d")" = "global" ]
  [ "$(jq -r .origin <<<"$d")" = "captured" ]
  [ "$(jq -r .pinned <<<"$d")" = "false" ]
  [ "$(jq -r .context <<<"$d")" = "null" ]
  [ "$(jq -r .default <<<"$d")" = "false" ]
  [ "$(jq -r .hits <<<"$d")" = "1" ]
  [[ "$(jq -r .added_at <<<"$d")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  [ "$(jq .version "$CCXP_TERMS_FILE")" = "1" ]
}

@test "add is idempotent on the same term+text and honours the profile dir" {
  t add RCA "root cause analysis"
  t add RCA "Root Cause Analysis"
  [ "$(jq '.terms.RCA.defs | length' "$CCXP_TERMS_FILE")" = "1" ]
  unset CCXP_TERMS_FILE
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  t add CC "Claude Code"
  [ -f "$CLAUDE_CONFIG_DIR/terms.json" ]
  [ "$(t path)" = "$CLAUDE_CONFIG_DIR/terms.json" ]
}

@test "one definition resolves to itself (case-insensitive fallback only for 3+ chars)" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  [ "$(t lookup RCA | jq -r .text)" = "root cause analysis" ]
  [ "$(t lookup RCA | jq -r .reason)" = "single" ]
  [ "$(t lookup rca | jq -r .text)" = "root cause analysis" ]
  [ "$(t lookup cc | jq -r .status)" = "unknown" ]
  [ "$(t lookup NOPE | jq -r .status)" = "unknown" ]
}

@test "WTF with two meanings and no default is ambiguous; the owner's answers make the most-used one win" {
  t add WTF "what the f**k"
  run t add WTF "want to find"
  [ "$output" = "noted: WTF = want to find (also: what the f**k)" ]
  run t lookup WTF
  [ "$(jq -r .status <<<"$output")" = "ambiguous" ]
  [ "$(jq -c '[.candidates[].text] | sort' <<<"$output")" = '["want to find","what the f**k"]' ]
  t choose WTF "want to find"
  [ "$(t lookup WTF | jq -r .status)" = "ambiguous" ]   # 2 vs 1: not yet a clear leader
  t choose WTF "want to find"
  run t lookup WTF
  [ "$(jq -r .status <<<"$output")" = "resolved" ]
  [ "$(jq -r .text <<<"$output")" = "want to find" ]
  [ "$(jq -r .reason <<<"$output")" = "most-used" ]
}

@test "choose --default pins the meaning at once; a later --default moves it" {
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t choose WTF "what the f**k" --default
  [ "$output" = "chose: WTF = what the f**k" ]
  run t lookup WTF
  [ "$(jq -r .text <<<"$output")" = "what the f**k" ]
  [ "$(jq -r .reason <<<"$output")" = "default" ]
  t choose WTF "want to find" --default
  [ "$(t lookup WTF | jq -r .text)" = "want to find" ]
  [ "$(jq '[.terms.WTF.defs[] | select(.default)] | length' "$CCXP_TERMS_FILE")" = "1" ]
  run t choose WTF "nonexistent"
  [ "$status" -eq 1 ]
}

@test "a context tag that matches the repo or topic decides; otherwise the general meaning" {
  t add CC "Claude Code" --default
  t add CC "carbon copy" --context email
  [ "$(t lookup CC | jq -r .text)" = "Claude Code" ]
  run t lookup CC --context email
  [ "$(jq -r .text <<<"$output")" = "carbon copy" ]
  [ "$(jq -r .reason <<<"$output")" = "context" ]
  [ "$(t lookup CC --context other,EMAIL | jq -r .text)" = "carbon copy" ]
  # an owner/repo slug also matches its repo part
  t add SDK "software dev kit"
  t add SDK "synx data kernel" --context pointer
  [ "$(t lookup SDK --context Org/Pointer | jq -r .text)" = "synx data kernel" ]
  # untagged meaning wins over a tagged one when nothing matches and there is no default
  [ "$(t lookup SDK | jq -r .reason)" = "general" ]
  [ "$(t lookup SDK | jq -r .text)" = "software dev kit" ]
}

@test "remove deletes one meaning or the whole term; unknown is exit 1" {
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t remove WTF "what the f**k"
  [ "$output" = "removed: WTF = what the f**k" ]
  [ "$(t lookup WTF | jq -r .text)" = "want to find" ]
  run t remove WTF
  [ "$status" -eq 0 ]
  [ "$(t lookup WTF | jq -r .status)" = "unknown" ]
  run t remove WTF
  [ "$status" -eq 1 ]
  run t remove RCA "never added"
  [ "$status" -eq 1 ]
}

@test "list prints one line per definition; --json dumps the store" {
  t add WTF "what the f**k"
  t add WTF "want to find" --context search
  t add CC "Claude Code" --default
  run t list
  [ "${lines[0]}" = "CC = Claude Code (default; hits 1)" ]
  [ "${lines[1]}" = "WTF = what the f**k (hits 1)" ]
  [ "${lines[2]}" = "WTF = want to find (ctx: search; hits 1)" ]
  [ "$(t list --json | jq '.terms | length')" = "2" ]
}

@test "writes keep the previous version as .bak and leave no temp files" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  [ "$(jq '.terms | keys' -c "$CCXP_TERMS_FILE.bak")" = '["RCA"]' ]
  [ "$(jq '.terms | keys' -c "$CCXP_TERMS_FILE")" = '["CC","RCA"]' ]
  [ "$(ls "$(dirname "$CCXP_TERMS_FILE")" | wc -l | tr -d ' ')" = "2" ]
}

@test "an unreadable file is moved aside, never overwritten in place" {
  mkdir -p "$(dirname "$CCXP_TERMS_FILE")"
  echo '{{broken' > "$CCXP_TERMS_FILE"
  run t lookup RCA
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ "$(cat "$CCXP_TERMS_FILE".corrupt-*)" = '{{broken' ]
  [ "$(t lookup RCA | jq -r .text)" = "root cause analysis" ]
}

@test "validation: bad terms, empty or long text, bad context and scope are exit 2 and write nothing" {
  run t add rca "x y"; [ "$status" -eq 2 ]
  run t add "R C" "x y"; [ "$status" -eq 2 ]
  run t add A "x y"; [ "$status" -eq 2 ]
  run t add RCA ""; [ "$status" -eq 2 ]
  run t add RCA "$(printf 'x%.0s' $(seq 1 121))"; [ "$status" -eq 2 ]
  run t add RCA "ok" --context "two words"; [ "$status" -eq 2 ]
  run t add RCA "ok" --scope galaxy; [ "$status" -eq 2 ]
  run t add RCA "ok" --origin glossary; [ "$status" -eq 2 ]
  run t add RCA "ok" --bogus; [ "$status" -eq 2 ]
  run t bogus; [ "$status" -eq 2 ]
  [ ! -e "$CCXP_TERMS_FILE" ]
}

@test "text is flattened to one line with control characters removed" {
  t add RCA $'root\tcause\n analysis\x01  '
  [ "$(jq -r '.terms.RCA.defs[0].text' "$CCXP_TERMS_FILE")" = "root cause analysis" ]
}

@test "limits: 8 definitions per term is exit 3 and keeps the file intact" {
  for i in 1 2 3 4 5 6 7 8; do t add XX "meaning $i"; done
  run t add XX "meaning 9"
  [ "$status" -eq 3 ]
  [ "$(jq '.terms.XX.defs | length' "$CCXP_TERMS_FILE")" = "8" ]
}

@test "origin asked and --pin are stored; origin defaults to captured" {
  t add RCA "root cause analysis" --origin asked --pin
  [ "$(jq -r '.terms.RCA.defs[0] | "\(.origin) \(.pinned)"' "$CCXP_TERMS_FILE")" = "asked true" ]
}

# --- import-glossary -------------------------------------------------------

glossary() {
  cat > "$BATS_TEST_TMPDIR/glossary.md" <<'EOF'
# Owner's personal shorthand

Some prose that mentions CC = something inline, which is not a term line.

- CC = Claude Code
- CC = carbon copy (email)
- RCA = root cause analysis
- lower = not a term
- WTF = want to find
EOF
}

@test "import-glossary: one-way, idempotent, pinned, origin glossary, glossary file untouched" {
  glossary
  before=$(shasum "$BATS_TEST_TMPDIR/glossary.md")
  run t import-glossary "$BATS_TEST_TMPDIR/glossary.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "imported 4 of 4 glossary lines"* ]]
  [ "$(shasum "$BATS_TEST_TMPDIR/glossary.md")" = "$before" ]
  [ "$(jq -r '[.terms.CC.defs[] | "\(.text)|\(.context)|\(.default)|\(.pinned)|\(.origin)|\(.hits)"] | join(";")' "$CCXP_TERMS_FILE")" \
    = "Claude Code|null|true|true|glossary|0;carbon copy|email|false|true|glossary|0" ]
  [ "$(t lookup CC | jq -r .text)" = "Claude Code" ]
  [ "$(t lookup CC --context email | jq -r .text)" = "carbon copy" ]
  run t import-glossary "$BATS_TEST_TMPDIR/glossary.md"
  [[ "$output" == "imported 0 of 4 glossary lines"* ]]
}

@test "import-glossary --dry-run writes nothing; default path is <profile>/rules/glossary.md" {
  glossary
  run t import-glossary "$BATS_TEST_TMPDIR/glossary.md" --dry-run
  [[ "$output" == "would import 4 of 4"* ]]
  [ ! -e "$CCXP_TERMS_FILE" ]
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  mkdir -p "$CLAUDE_CONFIG_DIR/rules"
  cp "$BATS_TEST_TMPDIR/glossary.md" "$CLAUDE_CONFIG_DIR/rules/glossary.md"
  run t import-glossary
  [[ "$output" == "imported 4 of 4"* ]]
  run t import-glossary "$BATS_TEST_TMPDIR/missing.md"
  [ "$status" -eq 1 ]
}

@test "import-glossary keeps an existing captured definition and its counters" {
  glossary
  t add RCA "root cause analysis"
  t choose RCA "root cause analysis"
  run t import-glossary "$BATS_TEST_TMPDIR/glossary.md"
  [[ "$output" == "imported 3 of 4"* ]]
  [ "$(jq -r '.terms.RCA.defs | "\(length) \(.[0].hits) \(.[0].origin)"' "$CCXP_TERMS_FILE")" = "1 2 captured" ]
}

# --- detect ----------------------------------------------------------------

dt() { t detect "$1" | jq -c '[.[] | "\(.kind):\(.term)=\(.text)"]'; }

@test "detect: the four explicit patterns, each captured with the expansion as typed" {
  [ "$(dt 'let us do a root cause analysis (RCA) of this')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'RCA (root cause analysis) first please')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'RCA = root cause analysis')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'RCA means root cause analysis')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'RCA stands for root cause analysis, ok?')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'the root cause analysis aka RCA')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'WTF = want to find')" = '["explicit:WTF=want to find"]' ]
  [ "$(dt 'WTF means what the f**k')" = '["explicit:WTF=what the f**k"]' ]
  [ "$(dt 'CC = Claude Code')" = '["explicit:CC=Claude Code"]' ]
}

@test "detect: stopwords in the expansion, trailing chatter, quotes and a capitalized sentence" {
  [ "$(dt 'Department of Defense (DOD) said')" = '["explicit:DOD=Department of Defense"]' ]
  [ "$(dt 'CDC means Center for Disease Control so be careful')" = '["explicit:CDC=Center for Disease Control"]' ]
  [ "$(dt 'RCA means root cause analysis so please run it')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt '"RCA" means "root cause analysis"')" = '["explicit:RCA=root cause analysis"]' ]
  [ "$(dt 'Root Cause Analysis (RCA).')" = '["explicit:RCA=Root Cause Analysis"]' ]
  [ "$(dt 'RCA 的全称是 root cause analysis')" = '["explicit:RCA=root cause analysis"]' ]
}

@test "detect: ordinary parentheticals, units, tickers and product names are not captured" {
  [ "$(dt 'the file is 5 MB (MB) big')" = '[]' ]
  [ "$(dt 'Apple Inc. (AAPL) rose')" = '[]' ]
  [ "$(dt 'PostgreSQL (PG) is fine')" = '[]' ]
  [ "$(dt 'we use Kubernetes (K8S)')" = '[]' ]
  [ "$(dt 'see the notes (see below) and (a)')" = '[]' ]
  [ "$(dt 'It costs 5 dollars (USD)')" = '[]' ]
  [ "$(dt 'PORT = 8080')" = '[]' ]
  [ "$(dt 'x = 5 and MAX_RETRIES = 3')" = '[]' ]
  [ "$(dt 'I am OK with this')" = '[]' ]
  [ "$(dt 'Stop the JOB and WAIT')" = '[]' ]
}

@test "detect: a statement whose letters do not match the initials is an ask, not a capture" {
  [ "$(dt 'ENV = production')" = '["ask:ENV=production"]' ]
  [ "$(dt 'TS means timestamp')" = '["ask:TS=timestamp"]' ]
  [ "$(dt 'we met the Kitchen Support Operations (KSO) team')" = '["explicit:KSO=Kitchen Support Operations"]' ]
  [ "$(dt 'we met the Kitchen Support Operations team (KSO)')" = '["ask:KSO=Kitchen Support Operations team"]' ]
  [ "$(dt 'the Rapid Cash Flow Analysis (RCA)')" = '["ask:RCA=Rapid Cash Flow Analysis"]' ]
}

@test "detect: code spans, code fences and quoted lines are ignored" {
  [ "$(dt 'run `RCA = root cause analysis` now')" = '[]' ]
  [ "$(dt $'see:\n```\nRCA = root cause analysis\n```\nthanks')" = '[]' ]
  [ "$(dt $'> RCA = root cause analysis\nplease reply')" = '[]' ]
}

@test "detect: a long pasted message is never auto-captured, only asked about" {
  long="RCA = root cause analysis. $(printf 'filler text %.0s' $(seq 1 200))"
  [ "$(dt "$long")" = '["ask:RCA=root cause analysis"]' ]
}

@test "detect: known same meaning is silent; a second meaning is additional; at most 3 candidates" {
  t add RCA "root cause analysis"
  [ "$(dt 'RCA = root cause analysis')" = '[]' ]
  [ "$(t detect 'RCA means random cat appears' | jq -r '.[0].known')" = "additional" ]
  t add WTF "what the f**k"
  [ "$(t detect 'WTF = want to find' | jq -r '.[0].known')" = "additional" ]
  [ "$(t detect 'ABC = a b c, DEF = d e f, GHI = g h i, JKL = j k l' | jq length)" = "3" ]
}

@test "detect: reads stdin with -" {
  run bash -c "printf 'RCA = root cause analysis' | bash '$TERMS' detect -"
  [ "$(jq -r '.[0].term' <<<"$output")" = "RCA" ]
}

# --- expand ----------------------------------------------------------------

@test "expand: finds known terms in a message, incl. plural, hyphenated and case-insensitive forms" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  run t expand 'please do an RCA and ping CC; two RCAs, an RCA-style doc, also rca and cc'
  [ "$(jq -c '[.[].term] | sort' <<<"$output")" = '["CC","RCA"]' ]
  [ "$(jq -r '.[] | select(.term == "RCA") | .text' <<<"$output")" = "root cause analysis" ]
  run t expand 'nothing to see, only prose with USA and PDF'
  [ "$output" = "[]" ]
}

@test "expand: skips code and uses topic words as context; ambiguity is reported" {
  t add CC "Claude Code" --default
  t add CC "carbon copy" --context email
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t expand 'draft the email and CC bob, `CC` in code is ignored; WTF is this'
  [ "$(jq -r '.[] | select(.term == "CC") | .text' <<<"$output")" = "carbon copy" ]
  [ "$(jq -r '.[] | select(.term == "WTF") | .status' <<<"$output")" = "ambiguous" ]
  run t expand 'use `CC` only'
  [ "$output" = "[]" ]
  run t expand --context email -
  [ "$output" = "[]" ]
  run bash -c "printf 'CC them' | bash '$TERMS' expand -"
  [ "$(jq -r '.[0].text' <<<"$output")" = "Claude Code" ]
}

# --- scope: repo glossary > repo-scoped > global ----------------------------

mkrepo() {  # mkrepo <dir> : a git repo whose name is the dir's basename
  mkdir -p "$1"; git init -q "$1"
}

@test "scope: the same term can mean different things in two repos" {
  t add LTV "lifetime value" --scope global
  t add LTV "loan to value" --scope repo:mortgage
  t add LTV "lock-time validation" --scope repo:chain
  [ "$(t lookup LTV --repo mortgage | jq -r .text)" = "loan to value" ]
  [ "$(t lookup LTV --repo mortgage | jq -r .tier)" = "repo" ]
  [ "$(t lookup LTV --repo chain | jq -r .text)" = "lock-time validation" ]
  [ "$(t lookup LTV --repo elsewhere | jq -r .text)" = "lifetime value" ]
  [ "$(t lookup LTV | jq -r .text)" = "lifetime value" ]
  [ "$(t lookup LTV | jq -r .tier)" = "global" ]
  # another repo's meaning is invisible even when it is the only one
  t add ZZZ "only in mortgage" --scope repo:mortgage
  [ "$(t lookup ZZZ --repo chain | jq -r .status)" = "unknown" ]
  [ "$(t lookup ZZZ --repo mortgage | jq -r .text)" = "only in mortgage" ]
}

@test "scope: --scope repo derives the repo name from the git toplevel; list shows the scope" {
  mkrepo "$BATS_TEST_TMPDIR/alpha"
  run t add LTV "loan to value" --scope repo --cwd "$BATS_TEST_TMPDIR/alpha"
  [ "$output" = "noted: LTV = loan to value {repo:alpha}" ]
  [ "$(jq -r '.terms.LTV.defs[0].scope' "$CCXP_TERMS_FILE")" = "repo:alpha" ]
  [ "$(t lookup LTV --cwd "$BATS_TEST_TMPDIR/alpha" | jq -r .text)" = "loan to value" ]
  [ "$(t lookup LTV | jq -r .status)" = "unknown" ]
  [ "$(t list)" = "LTV = loan to value (repo:alpha; hits 1)" ]
  run t add LTV "x" --scope repo
  [ "$status" -eq 2 ]   # not in a git repo, no --repo
}

@test "scope: a git worktree resolves to the main repo's name" {
  mkrepo "$BATS_TEST_TMPDIR/beta"
  git -C "$BATS_TEST_TMPDIR/beta" -c user.email=t@e.x -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
  git -C "$BATS_TEST_TMPDIR/beta" worktree add -q "$BATS_TEST_TMPDIR/wt-feature" -b feature
  t add LTV "loan to value" --scope repo --cwd "$BATS_TEST_TMPDIR/beta"
  [ "$(t lookup LTV --cwd "$BATS_TEST_TMPDIR/wt-feature" | jq -r .text)" = "loan to value" ]
}

@test "scope: the repo's glossary file beats terms.json, repo-scoped beats global" {
  mkrepo "$BATS_TEST_TMPDIR/gamma"
  mkdir -p "$BATS_TEST_TMPDIR/gamma/.claude/rules"
  cat > "$BATS_TEST_TMPDIR/gamma/.claude/rules/glossary.md" <<'EOF'
# Repo glossary
- LTV = loan to value
- SLA = service level agreement (support)
- SLA = sales lead assignment (crm)
EOF
  t add LTV "lifetime value"
  t add LTV "lock-time validation" --scope repo:gamma
  run t lookup LTV --cwd "$BATS_TEST_TMPDIR/gamma"
  [ "$(jq -r .text <<<"$output")" = "loan to value" ]
  [ "$(jq -r .tier <<<"$output")" = "repo-glossary" ]
  [ "$(t lookup LTV | jq -r .text)" = "lifetime value" ]   # outside the repo
  # a term only in the glossary file; context tags choose between its lines
  [ "$(t lookup SLA --cwd "$BATS_TEST_TMPDIR/gamma" --context support | jq -r .text)" = "service level agreement" ]
  [ "$(t lookup SLA --cwd "$BATS_TEST_TMPDIR/gamma" --context crm | jq -r .text)" = "sales lead assignment" ]
  [ "$(t lookup SLA --cwd "$BATS_TEST_TMPDIR/gamma" | jq -r .status)" = "ambiguous" ]
  # repo-scoped terms.json entry applies where the glossary file is silent
  t add ETA "estimated time of arrival"
  t add ETA "extract transform archive" --scope repo:gamma
  [ "$(t lookup ETA --cwd "$BATS_TEST_TMPDIR/gamma" | jq -r '"\(.tier) \(.text)"')" = "repo extract transform archive" ]
  # expand honours the same layers
  [ "$(t expand --cwd "$BATS_TEST_TMPDIR/gamma" 'LTV and ETA' | jq -c '[.[] | "\(.term):\(.tier)"] | sort')" = '["ETA:repo","LTV:repo-glossary"]' ]
  # the glossary file is never modified
  [ "$(wc -l < "$BATS_TEST_TMPDIR/gamma/.claude/rules/glossary.md" | tr -d ' ')" = "4" ]
}

@test "scope: --repo-glossary points at an explicit file; a missing file is simply no layer" {
  printf -- '- LTV = loan to value\n' > "$BATS_TEST_TMPDIR/g.md"
  [ "$(t lookup LTV --repo-glossary "$BATS_TEST_TMPDIR/g.md" | jq -r .text)" = "loan to value" ]
  [ "$(t lookup LTV --repo-glossary "$BATS_TEST_TMPDIR/none.md" | jq -r .status)" = "unknown" ]
}

@test "scope: detect treats a repo-glossary meaning as known, choose/remove can target one scope" {
  printf -- '- LTV = loan to value\n' > "$BATS_TEST_TMPDIR/g.md"
  [ "$(t detect --repo-glossary "$BATS_TEST_TMPDIR/g.md" 'LTV = loan to value')" = "[]" ]
  [ "$(t detect --repo-glossary "$BATS_TEST_TMPDIR/g.md" 'LTV = lifetime value' | jq -r '.[0].known')" = "additional" ]
  t add LTV "lifetime value"
  t add LTV "lifetime value" --scope repo:r1
  t choose LTV "lifetime value" --scope repo:r1
  [ "$(jq -c '[.terms.LTV.defs[] | .hits]' "$CCXP_TERMS_FILE")" = "[1,2]" ]
  t remove LTV --scope repo:r1
  [ "$(jq -c '[.terms.LTV.defs[] | .scope]' "$CCXP_TERMS_FILE")" = '["global"]' ]
}

# --- the agent definition ----------------------------------------------------

@test "asset: ccxp-agent.md has a Terms section covering expand, capture, ambiguity, scope and the Bash carve-out" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '^## Terms' "$f"
  grep -q 'agent-pairing/scripts/terms.sh' "$f"
  grep -q 'write each known term with its meaning on first use in every job prompt' "$f"
  grep -q 'subagents never see the glossary or terms.json' "$f"
  grep -q 'noted: RCA = root cause analysis' "$f"
  grep -q 'remember RCA = root cause analysis?' "$f"
  grep -q 'Never capture from pasted text' "$f"
  grep -q 'Never dispatch a job holding an unresolved ambiguous term' "$f"
  grep -qi 'you may offer, never silently do' "$f"
  grep -q 'personal shorthand never goes into a shared repo' "$f"
  grep -q 'only `add`, `choose`, `remove`' "$f"
  grep -q 'and the `terms.sh` calls' "$f"
  # the ledger carve-out and the read-only Bash rule survive
  grep -q 'Bash is read-only only' "$f"
}

@test "asset: the T= lookup line in the agent definition resolves a plugin cache layout and runs terms.sh" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md" line prof
  prof="$BATS_TEST_TMPDIR/prof"
  mkdir -p "$prof/plugins/cache/ccxp-skills/ccxp-skills/1.0.0/agent-pairing/scripts" \
           "$prof/plugins/cache/ccxp-skills/ccxp-skills/10.2.0/agent-pairing/scripts"
  cp "$TERMS" "$prof/plugins/cache/ccxp-skills/ccxp-skills/10.2.0/agent-pairing/scripts/terms.sh"
  line=$(grep -o 'T="$(ls -d [^"]*"' "$f" | head -1)
  [ -n "$line" ]
  export CLAUDE_CONFIG_DIR="$prof"
  run bash -c "$line; bash \"\$T\" add CC 'Claude Code'"
  [ "$output" = "noted: CC = Claude Code" ]
}

@test "add writes through a symlinked store instead of replacing the link" {
  mkdir -p "$BATS_TEST_TMPDIR/shared" "$BATS_TEST_TMPDIR/profile"
  printf '{"version":1,"terms":{}}\n' > "$BATS_TEST_TMPDIR/shared/terms.json"
  ln -s ../shared/terms.json "$CCXP_TERMS_FILE"
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ -L "$CCXP_TERMS_FILE" ]
  [ "$(jq -r '.terms.RCA.defs[0].text' "$BATS_TEST_TMPDIR/shared/terms.json")" = "root cause analysis" ]
}
