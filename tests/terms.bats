#!/usr/bin/env bats
# Tests for agent-pairing/scripts/terms.sh (the ccxp-agent's wtf.json store, "wtf" = where to find).

load test_helper
TERMS="$REPO_ROOT/agent-pairing/scripts/terms.sh"

setup() {
  export CCXP_WTF_FILE="$BATS_TEST_TMPDIR/profile/wtf.json"
  unset CLAUDE_CONFIG_DIR
  cd "$BATS_TEST_TMPDIR"   # not inside a git repo unless a test says so
}

t() { bash "$TERMS" "$@"; }

@test "add records a definition; file is 600 JSON with the full schema" {
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ "$output" = "noted: rca = root cause analysis" ]
  [ "$(stat -c %a "$CCXP_WTF_FILE" 2>/dev/null || stat -f %Lp "$CCXP_WTF_FILE")" = "600" ]
  d=$(jq -c '.terms.rca.defs[0]' "$CCXP_WTF_FILE")
  [ "$(jq -r .text <<<"$d")" = "root cause analysis" ]
  [ "$(jq -r .scope <<<"$d")" = "global" ]
  [ "$(jq -r .origin <<<"$d")" = "captured" ]
  [ "$(jq -r .pinned <<<"$d")" = "false" ]
  [ "$(jq -r .context <<<"$d")" = "null" ]
  [ "$(jq -r .default <<<"$d")" = "false" ]
  [ "$(jq -r .hits <<<"$d")" = "1" ]
  [[ "$(jq -r .added_at <<<"$d")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  [ "$(jq .version "$CCXP_WTF_FILE")" = "1" ]
}

@test "add is idempotent on the same term+text and honours the profile dir" {
  t add RCA "root cause analysis"
  t add RCA "Root Cause Analysis"
  [ "$(jq '.terms.rca.defs | length' "$CCXP_WTF_FILE")" = "1" ]
  unset CCXP_WTF_FILE
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  t add CC "Claude Code"
  [ -f "$CLAUDE_CONFIG_DIR/wtf.json" ]
  [ "$(t path)" = "$CLAUDE_CONFIG_DIR/wtf.json" ]
}

@test "one definition resolves to itself; lookup is case-insensitive for any length" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  [ "$(t lookup RCA | jq -r .text)" = "root cause analysis" ]
  [ "$(t lookup RCA | jq -r .reason)" = "single" ]
  [ "$(t lookup RCA | jq -r .status)" = "resolved" ]
  [ "$(t lookup rca | jq -r .text)" = "root cause analysis" ]
  [ "$(t lookup cc | jq -r .text)" = "Claude Code" ]
  [ "$(t lookup CC | jq -r '.texts | join("|")')" = "Claude Code" ]
  [ "$(t lookup NOPE | jq -r .status)" = "unknown" ]
}

@test "WTF with two meanings is never ambiguous: all meanings are returned, the most-used leads" {
  t add WTF "what the f**k"
  run t add WTF "want to find"
  [ "$output" = "noted: wtf = want to find (also: what the f**k)" ]
  run t lookup WTF
  [ "$(jq -r .status <<<"$output")" = "resolved" ]
  [ "$(jq -r .reason <<<"$output")" = "several" ]
  [ "$(jq -c '.texts | sort' <<<"$output")" = '["want to find","what the f**k"]' ]
  [ "$(jq -r .text <<<"$output")" = "what the f**k" ]   # equal hits: first added leads
  t choose WTF "want to find"
  run t lookup WTF
  [ "$(jq -r .status <<<"$output")" = "resolved" ]
  [ "$(jq -r .reason <<<"$output")" = "most-used" ]
  [ "$(jq -r .text <<<"$output")" = "want to find" ]
  [ "$(jq -c .texts <<<"$output")" = '["want to find","what the f**k"]' ]
}

@test "choose --default pins the meaning at once; a later --default moves it" {
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t choose WTF "what the f**k" --default
  [ "$output" = "chose: wtf = what the f**k" ]
  run t lookup WTF
  [ "$(jq -r .text <<<"$output")" = "what the f**k" ]
  [ "$(jq -r .reason <<<"$output")" = "default" ]
  t choose WTF "want to find" --default
  [ "$(t lookup WTF | jq -r .text)" = "want to find" ]
  [ "$(jq '[.terms.wtf.defs[] | select(.default)] | length' "$CCXP_WTF_FILE")" = "1" ]
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
  # nothing matches and there is no default: the untagged meaning leads, the tagged one still listed
  [ "$(t lookup SDK | jq -r .status)" = "resolved" ]
  [ "$(t lookup SDK | jq -r .text)" = "software dev kit" ]
  [ "$(t lookup SDK | jq -c .texts)" = '["software dev kit","synx data kernel"]' ]
  # with a context match the order is: context tag > default > untagged
  [ "$(t lookup CC --context email | jq -c .texts)" = '["carbon copy","Claude Code"]' ]
}

@test "remove deletes one meaning or the whole term; unknown is exit 1" {
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t remove WTF "what the f**k"
  [ "$output" = "removed: wtf = what the f**k" ]
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
  [ "${lines[0]}" = "cc = Claude Code (default; hits 1)" ]
  [ "${lines[1]}" = "wtf = what the f**k (hits 1)" ]
  [ "${lines[2]}" = "wtf = want to find (ctx: search; hits 1)" ]
  [ "$(t list --json | jq '.terms | length')" = "2" ]
}

@test "writes keep the previous version as .bak and leave no temp files" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  [ "$(jq '.terms | keys' -c "$CCXP_WTF_FILE.bak")" = '["rca"]' ]
  [ "$(jq '.terms | keys' -c "$CCXP_WTF_FILE")" = '["cc","rca"]' ]
  [ "$(ls "$(dirname "$CCXP_WTF_FILE")" | sort | tr '\n' ' ')" = "wtf.json wtf.json.bak " ]
}

@test "an unreadable file is moved aside, never overwritten in place" {
  mkdir -p "$(dirname "$CCXP_WTF_FILE")"
  echo '{{broken' > "$CCXP_WTF_FILE"
  run t lookup RCA
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ "$(cat "$CCXP_WTF_FILE".corrupt-*)" = '{{broken' ]
  [ "$(t lookup RCA | jq -r .text)" = "root cause analysis" ]
}

@test "validation: bad terms, empty or long text, bad context and scope are exit 2 and write nothing" {
  run t add "R C" "x y"; [ "$status" -eq 2 ]
  run t add A "x y"; [ "$status" -eq 2 ]
  run t add "waytoolongterm1" "x y"; [ "$status" -eq 2 ]
  run t add "r_c" "x y"; [ "$status" -eq 2 ]
  run t add RCA ""; [ "$status" -eq 2 ]
  run t add RCA "$(printf 'x%.0s' $(seq 1 121))"; [ "$status" -eq 2 ]
  run t add RCA "ok" --context "two words"; [ "$status" -eq 2 ]
  run t add RCA "ok" --scope galaxy; [ "$status" -eq 2 ]
  run t add RCA "ok" --origin glossary; [ "$status" -eq 2 ]
  run t add RCA "ok" --bogus; [ "$status" -eq 2 ]
  run t bogus; [ "$status" -eq 2 ]
  [ ! -e "$CCXP_WTF_FILE" ]
}

@test "text is flattened to one line with control characters removed" {
  t add RCA $'root\tcause\n analysis\x01  '
  [ "$(jq -r '.terms.rca.defs[0].text' "$CCXP_WTF_FILE")" = "root cause analysis" ]
}

@test "limits: 8 definitions per term is exit 3 and keeps the file intact" {
  for i in 1 2 3 4 5 6 7 8; do t add XX "meaning $i"; done
  run t add XX "meaning 9"
  [ "$status" -eq 3 ]
  [ "$(jq '.terms.xx.defs | length' "$CCXP_WTF_FILE")" = "8" ]
}

@test "origin asked and --pin are stored; origin defaults to captured" {
  t add RCA "root cause analysis" --origin asked --pin
  [ "$(jq -r '.terms.rca.defs[0] | "\(.origin) \(.pinned)"' "$CCXP_WTF_FILE")" = "asked true" ]
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
  [ "$(jq -r '[.terms.cc.defs[] | "\(.text)|\(.context)|\(.default)|\(.pinned)|\(.origin)|\(.hits)"] | join(";")' "$CCXP_WTF_FILE")" \
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
  [ ! -e "$CCXP_WTF_FILE" ]
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
  [ "$(jq -r '.terms.rca.defs | "\(length) \(.[0].hits) \(.[0].origin)"' "$CCXP_WTF_FILE")" = "1 2 captured" ]
}

# --- detect ----------------------------------------------------------------

dt() { t detect "$1" | jq -c '[.[] | "\(.kind):\(.term)=\(.text)"]'; }

@test "detect: the four explicit patterns, each captured with the expansion as typed" {
  [ "$(dt 'let us do a root cause analysis (RCA) of this')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'RCA (root cause analysis) first please')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'RCA = root cause analysis')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'RCA means root cause analysis')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'RCA stands for root cause analysis, ok?')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'the root cause analysis aka RCA')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'WTF = want to find')" = '["explicit:wtf=want to find"]' ]
  [ "$(dt 'WTF means what the f**k')" = '["explicit:wtf=what the f**k"]' ]
  [ "$(dt 'CC = Claude Code')" = '["explicit:cc=Claude Code"]' ]
}

@test "detect: stopwords in the expansion, trailing chatter, quotes and a capitalized sentence" {
  [ "$(dt 'Department of Defense (DOD) said')" = '["explicit:dod=Department of Defense"]' ]
  [ "$(dt 'CDC means Center for Disease Control so be careful')" = '["explicit:cdc=Center for Disease Control"]' ]
  [ "$(dt 'RCA means root cause analysis so please run it')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt '"RCA" means "root cause analysis"')" = '["explicit:rca=root cause analysis"]' ]
  [ "$(dt 'Root Cause Analysis (RCA).')" = '["explicit:rca=Root Cause Analysis"]' ]
  [ "$(dt 'RCA 的全称是 root cause analysis')" = '["explicit:rca=root cause analysis"]' ]
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
  [ "$(dt 'ENV = production')" = '["ask:env=production"]' ]
  [ "$(dt 'TS means timestamp')" = '["ask:ts=timestamp"]' ]
  [ "$(dt 'we met the Kitchen Support Operations (KSO) team')" = '["explicit:kso=Kitchen Support Operations"]' ]
  [ "$(dt 'we met the Kitchen Support Operations team (KSO)')" = '["ask:kso=Kitchen Support Operations team"]' ]
  [ "$(dt 'the Rapid Cash Flow Analysis (RCA)')" = '["ask:rca=Rapid Cash Flow Analysis"]' ]
}

@test "detect: code spans, code fences and quoted lines are ignored" {
  [ "$(dt 'run `RCA = root cause analysis` now')" = '[]' ]
  [ "$(dt $'see:\n```\nRCA = root cause analysis\n```\nthanks')" = '[]' ]
  [ "$(dt $'> RCA = root cause analysis\nplease reply')" = '[]' ]
}

@test "detect: a long pasted message is never auto-captured, only asked about" {
  long="RCA = root cause analysis. $(printf 'filler text %.0s' $(seq 1 200))"
  [ "$(dt "$long")" = '["ask:rca=root cause analysis"]' ]
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
  [ "$(jq -r '.[0].term' <<<"$output")" = "rca" ]
}

# --- expand ----------------------------------------------------------------

@test "expand: finds known terms in a message, incl. plural, hyphenated and case-insensitive forms" {
  t add RCA "root cause analysis"
  t add CC "Claude Code"
  run t expand 'please do an RCA and ping CC; two RCAs, an RCA-style doc, also rca and cc'
  [ "$(jq -c '[.[].term] | sort' <<<"$output")" = '["cc","rca"]' ]
  [ "$(jq -r '.[] | select(.term == "rca") | .text' <<<"$output")" = "root cause analysis" ]
  run t expand 'nothing to see, only prose with USA and PDF'
  [ "$output" = "[]" ]
}

@test "expand: skips code and uses topic words as context; several meanings are all listed" {
  t add CC "Claude Code" --default
  t add CC "carbon copy" --context email
  t add WTF "what the f**k"
  t add WTF "want to find"
  run t expand 'draft the email and CC bob, `CC` in code is ignored; WTF is this'
  [ "$(jq -r '.[] | select(.term == "cc") | .text' <<<"$output")" = "carbon copy" ]
  [ "$(jq -r '.[] | select(.term == "cc") | .reason' <<<"$output")" = "context" ]
  [ "$(jq -c '.[] | select(.term == "cc") | .texts' <<<"$output")" = '["carbon copy","Claude Code"]' ]
  [ "$(jq -r '.[] | select(.term == "wtf") | .status' <<<"$output")" = "resolved" ]
  [ "$(jq -c '.[] | select(.term == "wtf") | .texts | sort' <<<"$output")" = '["want to find","what the f**k"]' ]
  run t expand 'use `CC` only'
  [ "$output" = "[]" ]
  run t expand --context email -
  [ "$output" = "[]" ]
  run bash -c "printf 'CC them' | bash '$TERMS' expand -"
  [ "$(jq -r '.[0].text' <<<"$output")" = "Claude Code" ]
}

@test "expand: lowercase storage, any-case input (CC, Qbo) finds the term; output terms are lowercase" {
  t add qbo "quickbooks online"
  t add CC "Claude Code"
  run t expand 'sync Qbo with cc, then QBO again and Cc'
  [ "$(jq -c '[.[].term] | sort' <<<"$output")" = '["cc","qbo"]' ]
  [ "$(jq -r '.[] | select(.term == "qbo") | .text' <<<"$output")" = "quickbooks online" ]
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE")" = '["cc","qbo"]' ]
  [ "$(t lookup Qbo | jq -r .term)" = "qbo" ]
}

@test "expand: several meanings come back together without any ambiguity" {
  t add CC "Claude Code"
  t add CC "concurrency control"
  run t expand 'what does cc do here'
  [ "$(jq 'length' <<<"$output")" = "1" ]
  [ "$(jq -r '.[0].status' <<<"$output")" = "resolved" ]
  [ "$(jq -c '.[0].texts' <<<"$output")" = '["Claude Code","concurrency control"]' ]
  [ "$(jq -r '.[0].text' <<<"$output")" = "Claude Code" ]
  ! grep -q ambiguous <<<"$output"
}

# --- wtf.json location, precedence, migration, case, .bak --------------------------

@test "wtf.json is the default store and path prints it" {
  unset CCXP_WTF_FILE CCXP_TERMS_FILE
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  [ "$(t path)" = "$CLAUDE_CONFIG_DIR/wtf.json" ]
  t add RCA "root cause analysis"
  [ -f "$CLAUDE_CONFIG_DIR/wtf.json" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/terms.json" ]
  unset CLAUDE_CONFIG_DIR
  HOME="$BATS_TEST_TMPDIR/home" run t path
  [ "$output" = "$BATS_TEST_TMPDIR/home/.claude/wtf.json" ]
}

@test "CCXP_WTF_FILE wins over the legacy CCXP_TERMS_FILE alias, which still works alone" {
  export CCXP_TERMS_FILE="$BATS_TEST_TMPDIR/legacy/alias.json"
  [ "$(t path)" = "$CCXP_WTF_FILE" ]
  t add RCA "root cause analysis"
  [ -f "$CCXP_WTF_FILE" ]
  [ ! -e "$CCXP_TERMS_FILE" ]
  unset CCXP_WTF_FILE
  [ "$(t path)" = "$CCXP_TERMS_FILE" ]
  t add CC "Claude Code"
  [ "$(jq -c '.terms | keys' "$CCXP_TERMS_FILE")" = '["cc"]' ]
}

legacy() {  # legacy <dir> : a pre-wtf terms.json with an uppercase key
  mkdir -p "$1"
  printf '{"version":1,"terms":{"RCA":{"defs":[{"text":"root cause analysis","scope":"global","hits":3,"context":null,"default":false,"pinned":false,"added_at":"2026-01-01","last_hit":"","origin":"captured"}]}}}\n' > "$1/terms.json"
}

@test "migration: a missing wtf.json is created from terms.json (keys lowercased), terms.json becomes .migrated" {
  d="$(dirname "$CCXP_WTF_FILE")"
  legacy "$d"
  run t lookup RCA
  [ "$(jq -r .text <<<"$output")" = "root cause analysis" ]
  [ -f "$d/wtf.json" ]
  [ ! -e "$d/terms.json" ]
  [ -f "$d/terms.json.migrated" ]
  [ "$(jq -c '.terms | keys' "$d/wtf.json")" = '["rca"]' ]
  [ "$(jq -r '.terms.rca.defs[0].hits' "$d/wtf.json")" = "3" ]
  # from now on only wtf.json is read: a new terms.json is ignored
  printf '{"version":1,"terms":{"ZZ":{"defs":[{"text":"ignored","scope":"global","hits":0,"context":null,"default":false,"pinned":false,"added_at":"2026-01-01","last_hit":"","origin":"captured"}]}}}\n' > "$d/terms.json"
  [ "$(t lookup ZZ | jq -r .status)" = "unknown" ]
  [ "$(cat "$d/terms.json" | jq -c '.terms | keys')" = '["ZZ"]' ]
}

@test "migration also happens on the first write and lowercases the keys" {
  d="$(dirname "$CCXP_WTF_FILE")"
  mkdir -p "$d"
  printf '{"version":1,"terms":{"CC":{"defs":[{"text":"Claude Code","scope":"global","hits":0,"context":null,"default":false,"pinned":false,"added_at":"2026-01-01","last_hit":"","origin":"captured"}]},"Cc":{"defs":[{"text":"carbon copy","scope":"global","hits":0,"context":null,"default":false,"pinned":false,"added_at":"2026-01-01","last_hit":"","origin":"captured"}]}}}\n' > "$d/terms.json"
  t add RCA "root cause analysis"
  [ -f "$d/terms.json.migrated" ] && [ ! -e "$d/terms.json" ]
  [ "$(jq -c '.terms | keys' "$d/wtf.json")" = '["cc","rca"]' ]
  [ "$(jq '.terms.cc.defs | length' "$d/wtf.json")" -ge 1 ]
}

@test "migration: wtf.json wins when both exist, terms.json is left untouched" {
  d="$(dirname "$CCXP_WTF_FILE")"
  legacy "$d"
  t add CC "Claude Code"      # first write migrates
  mv "$d/terms.json.migrated" "$d/terms.json"   # put the legacy file back next to an existing wtf.json
  before=$(shasum "$d/terms.json")
  [ "$(t lookup CC | jq -r .text)" = "Claude Code" ]
  [ "$(t lookup RCA | jq -r .text)" = "root cause analysis" ]
  t add XY "x y z"
  [ "$(shasum "$d/terms.json")" = "$before" ]
  [ ! -e "$d/terms.json.migrated" ]
  [ "$(jq -c '.terms | keys' "$d/wtf.json")" = '["cc","rca","xy"]' ]
}

@test "migration: a corrupt terms.json is not migrated and not renamed" {
  d="$(dirname "$CCXP_WTF_FILE")"
  mkdir -p "$d"; echo '{{broken' > "$d/terms.json"
  run t lookup RCA
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ -f "$d/terms.json" ] && [ ! -e "$d/terms.json.migrated" ]
}

@test "terms are stored lowercase whatever the input case; add RCA, Rca and rca are one term" {
  run t add RCA "root cause analysis"
  [ "$output" = "noted: rca = root cause analysis" ]
  t add Rca "Root Cause Analysis"
  t add rca "root cause analysis"
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE")" = '["rca"]' ]
  [ "$(jq '.terms.rca.defs | length' "$CCXP_WTF_FILE")" = "1" ]
  run t add cc "Claude Code"      # lowercase is a valid term now
  [ "$status" -eq 0 ]
  [ "$(t lookup CC | jq -r .text)" = "Claude Code" ]
  run t remove CC
  [ "$status" -eq 0 ]
  [ "$(t lookup cc | jq -r .status)" = "unknown" ]
}

@test ".bak holds the version before the latest write and none exists after the first write" {
  t add RCA "root cause analysis"
  [ ! -e "$CCXP_WTF_FILE.bak" ]
  t add CC "Claude Code"
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE.bak")" = '["rca"]' ]
  t remove CC
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE.bak")" = '["cc","rca"]' ]
  [ "$(jq -c '.terms | keys' "$CCXP_WTF_FILE")" = '["rca"]' ]
  [ ! -e "$(dirname "$CCXP_WTF_FILE")/terms.json.bak" ]
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
  [ "$output" = "noted: ltv = loan to value {repo:alpha}" ]
  [ "$(jq -r '.terms.ltv.defs[0].scope' "$CCXP_WTF_FILE")" = "repo:alpha" ]
  [ "$(t lookup LTV --cwd "$BATS_TEST_TMPDIR/alpha" | jq -r .text)" = "loan to value" ]
  [ "$(t lookup LTV | jq -r .status)" = "unknown" ]
  [ "$(t list)" = "ltv = loan to value (repo:alpha; hits 1)" ]
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

@test "scope: the repo's glossary file beats wtf.json, repo-scoped beats global" {
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
  run t lookup SLA --cwd "$BATS_TEST_TMPDIR/gamma"
  [ "$(jq -r .status <<<"$output")" = "resolved" ]
  [ "$(jq -c '.texts | sort' <<<"$output")" = '["sales lead assignment","service level agreement"]' ]
  # repo-scoped wtf.json entry applies where the glossary file is silent
  t add ETA "estimated time of arrival"
  t add ETA "extract transform archive" --scope repo:gamma
  [ "$(t lookup ETA --cwd "$BATS_TEST_TMPDIR/gamma" | jq -r '"\(.tier) \(.text)"')" = "repo extract transform archive" ]
  # expand honours the same layers
  [ "$(t expand --cwd "$BATS_TEST_TMPDIR/gamma" 'LTV and ETA' | jq -c '[.[] | "\(.term):\(.tier)"] | sort')" = '["eta:repo","ltv:repo-glossary"]' ]
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
  [ "$(jq -c '[.terms.ltv.defs[] | .hits]' "$CCXP_WTF_FILE")" = "[1,2]" ]
  t remove LTV --scope repo:r1
  [ "$(jq -c '[.terms.ltv.defs[] | .scope]' "$CCXP_WTF_FILE")" = '["global"]' ]
}

# --- the agent definition ----------------------------------------------------

@test "asset: ccxp-agent.md has a Terms section covering expand, capture, several meanings, scope and the Bash carve-out" {
  local f="$REPO_ROOT/agent-pairing/assets/ccxp-agent.md"
  grep -q '^## Terms' "$f"
  grep -q 'agent-pairing/scripts/terms.sh' "$f"
  grep -q 'write each known term with its meaning on first use in every job prompt' "$f"
  grep -q 'subagents never see the glossary or' "$f"
  grep -q 'noted: rca = root cause analysis' "$f"
  grep -q 'remember RCA = root cause analysis?' "$f"
  grep -q 'Never capture from pasted text' "$f"
  grep -q '^- \*\*Several meanings\*\*: normal, never an error' "$f"
  ! grep -qi 'unresolved ambiguous term' "$f"
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
  [ "$output" = "noted: cc = Claude Code" ]
}

@test "add writes through a symlinked store instead of replacing the link" {
  mkdir -p "$BATS_TEST_TMPDIR/shared" "$BATS_TEST_TMPDIR/profile"
  printf '{"version":1,"terms":{}}\n' > "$BATS_TEST_TMPDIR/shared/wtf.json"
  ln -s ../shared/wtf.json "$CCXP_WTF_FILE"
  run t add RCA "root cause analysis"
  [ "$status" -eq 0 ]
  [ -L "$CCXP_WTF_FILE" ]
  [ "$(jq -r '.terms.rca.defs[0].text' "$BATS_TEST_TMPDIR/shared/wtf.json")" = "root cause analysis" ]
}

@test "a hand-written store with sparse definitions and keys differing only in case keeps every meaning" {
  mkdir -p "$(dirname "$CCXP_TERMS_FILE")"
  echo '{"terms":{"CC":{"defs":[{"text":"claude code"}]},"Cc":{"defs":[{"text":"concurrency control"}]}}}' > "$CCXP_TERMS_FILE"
  run t lookup cc
  [ "$(jq -c '.texts | sort' <<<"$output")" = '["claude code","concurrency control"]' ]
  [ "$(jq -r .status <<<"$output")" = "resolved" ]
}
