#!/usr/bin/env bats
# The "backed by code" contract (skill-conventions section 9): every
# non-exempt skill ships scripts, each script is named by a test, cited script
# paths exist, and the invocation conventions hold. The lint is
# `skill_score.py --coverage`; today's gaps are baselined in
# dev/quality/skill-coverage-baseline.txt and may only shrink.

load test_helper

SCORE="$REPO_ROOT/skill-conventions/scripts/skill_score.py"

setup() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/tests" "$FX/dev/quality"
  : > "$FX/dev/quality/script-exemptions.txt"
}

# mkskill <name> <description> [body-extra]; the note sits under the H1.
mkskill() {
  mkdir -p "$FX/$1"
  {
    printf -- '---\nname: %s\ndescription: %s\n---\n\n# %s\n\n' "$1" "$2" "$1"
    printf '> `<skills-root>` = this skill'"'"'s base directory minus its last component.\n\n'
    printf '## Workflow\n\n%s\n' "${3:-}"
  } > "$FX/$1/SKILL.md"
}
mkscript() { mkdir -p "$FX/$1/scripts"; printf '#!/usr/bin/env bash\n' > "$FX/$1/scripts/$2"; }
covered() { printf '# runs %s\n' "$1" > "$FX/tests/$2.bats"; }
lint() { python3 "$SCORE" --repo "$FX" --coverage "$@"; }
USEWHEN="Use when the user explicitly asks to exercise the contract fixture"

@test "the real repo is at or inside its coverage baseline" {
  run python3 "$SCORE" --coverage --coverage-check "$REPO_ROOT/dev/quality/skill-coverage-baseline.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no new ones"* ]]
}

@test "baseline entries are tab-separated skill<TAB>finding lines" {
  run grep -vE '^#|^[a-z0-9-]+'$'\t''[a-z-]+(:.+)?$' "$REPO_ROOT/dev/quality/skill-coverage-baseline.txt"
  [ -z "$output" ]
}

@test "compliant skill: scripts, a test naming them, valid refs -> no findings" {
  mkskill good "$USEWHEN" 'Run `<skills-root>/good/scripts/run.sh`.'
  mkscript good run.sh
  covered run.sh good
  run lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 finding"* ]]
}

@test "no scripts is a finding" {
  mkskill bare "$USEWHEN"
  run lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"bare: no-scripts"* ]]
}

@test "a script that no test names is a finding" {
  mkskill half "$USEWHEN"
  mkscript half tested.sh; mkscript half lonely.sh
  covered tested.sh half
  run lint
  [[ "$output" == *"half: untested-script:lonely.sh"* ]]
  [[ "$output" != *"untested-script:tested.sh"* ]]
}

@test "a cited <skills-root> script that does not exist is a finding" {
  mkskill ghost "$USEWHEN" 'Run `bash <skills-root>/ghost/scripts/gone.sh`.'
  mkscript ghost real.sh; covered real.sh ghost
  run lint
  [[ "$output" == *"ghost: missing-script:ghost/scripts/gone.sh"* ]]
}

@test "placeholder paths in prose (X/Y.sh, <skill>/...) are not findings" {
  mkskill ph "$USEWHEN" 'Use `bash <skills-root>/<skill>/scripts/x.sh` or X/Y.sh.'
  mkscript ph real.sh; covered real.sh ph
  run lint
  [ "$status" -eq 0 ]
}

@test "repo-relative script invocation is a finding" {
  mkskill rel "$USEWHEN" 'Run `bash rel/scripts/go.sh` from the repo root.'
  mkscript rel go.sh; covered go.sh rel
  run lint
  [[ "$output" == *"rel: repo-relative-script:rel/scripts/go.sh"* ]]
}

@test "description must start with 'Use when'; disable-model-invocation is flagged" {
  mkskill desc "Does a thing"
  mkscript desc a.sh; covered a.sh desc
  sed -i.bak 's/^description:/disable-model-invocation: true\ndescription:/' "$FX/desc/SKILL.md"
  run lint
  [[ "$output" == *"desc: desc-use-when"* ]]
  [[ "$output" == *"desc: disable-model-invocation"* ]]
}

@test "the <skills-root> note inside a code fence does not count" {
  mkskill fenced "$USEWHEN"
  mkscript fenced a.sh; covered a.sh fenced
  printf -- '---\nname: fenced\ndescription: %s\n---\n\n# fenced\n\n```bash\n# <skills-root> = base dir\n```\n\n## Workflow\n\nRun `<skills-root>/fenced/scripts/a.sh`.\n' "$USEWHEN" > "$FX/fenced/SKILL.md"
  run lint
  [[ "$output" == *"fenced: skills-root-note"* ]]
}

@test "an exempt skill needs no scripts, but frontmatter/refs are still checked" {
  mkskill ref "$USEWHEN" 'See [gone](missing.md).'
  printf 'ref\treference\tpure reference skill\n' > "$FX/dev/quality/script-exemptions.txt"
  run lint
  [[ "$output" != *"ref: no-scripts"* ]]
  [[ "$output" == *"ref: broken-ref:missing.md"* ]]
}

@test "exemption without a reason, with a bad class, or for a missing dir fails" {
  mkskill e1 "$USEWHEN"
  printf 'e1\treference\t\ne1x\tbogus\twhy\nnodir\tmod\tgone\n' > "$FX/dev/quality/script-exemptions.txt"
  run lint
  [[ "$output" == *"e1: exemption-no-reason"* ]]
  [[ "$output" == *"e1x: exemption-bad-class"* ]]
  [[ "$output" == *"nodir: exemption-stale"* ]]
}

@test "ratchet: a new gap fails; a fixed-but-still-baselined gap fails; equal passes" {
  mkskill r1 "$USEWHEN"
  run lint --coverage-write "$FX/base.txt"
  [ "$status" -eq 0 ]
  run lint --coverage-check "$FX/base.txt"
  [ "$status" -eq 0 ]
  mkskill r2 "$USEWHEN"                       # new debt
  run lint --coverage-check "$FX/base.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"new coverage gap: r2: no-scripts"* ]]
  rm -rf "$FX/r2"
  mkscript r1 s.sh; covered s.sh r1           # debt paid, baseline not shrunk
  run lint --coverage-check "$FX/base.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"remove it: r1: no-scripts"* ]]
}
