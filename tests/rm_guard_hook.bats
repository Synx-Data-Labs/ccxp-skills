#!/usr/bin/env bats
# hooks/rm-guard.sh (+ rm-guard.py) -- PreToolUse(Bash) hook that denies plain
# file deletion and points the agent at agent-pairing/scripts/trash.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_ROOT/hooks/rm-guard.sh"
  unset CCXP_ALLOW_RM
  TMPDIR_TEST_DIR="$REPO_ROOT/.rm-guard-test-$$"
  # A cwd outside any temp dir, so relative targets count as "not temp".
  CWD=/nonexistent-home/proj
}

teardown() { rm -rf "$TMPDIR_TEST_DIR"; }

# run_hook <command> [cwd]: feed a Bash tool call to the hook.
run_hook() {
  jq -n --arg c "$1" --arg d "${2:-$CWD}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | "$HOOK"
}

decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output"; }

assert_blocked() {
  run run_hook "$1" "${2:-}"
  [ "$status" -eq 0 ] || { echo "exit $status for: $1"; return 1; }
  [ "$(decision)" = deny ] || { echo "expected deny: $1 (output: $output)"; return 1; }
}

assert_allowed() {
  run run_hook "$1" "${2:-}"
  [ "$status" -eq 0 ] || { echo "exit $status for: $1"; return 1; }
  [ -z "$output" ] || { echo "expected silence: $1 (output: $output)"; return 1; }
}

# -- blocked ---------------------------------------------------------------

@test "blocked: plain rm in its forms" {
  assert_blocked 'rm foo.txt'
  assert_blocked 'rm -rf build'
  assert_blocked 'rm -r -f -- build'
  assert_blocked '/bin/rm -rf x'
  assert_blocked '/usr/bin/rm x'
  assert_blocked 'command rm x'
  assert_blocked 'sudo rm -rf /var/x'
  assert_blocked 'sudo -u root rm x'
  assert_blocked 'env FOO=1 rm x'
  assert_blocked 'FOO=1 rm x'
  assert_blocked 'nohup rm -rf x &'
  assert_blocked 'time rm x'
  assert_blocked 'timeout 5 rm x'
  assert_blocked '\rm x'
  assert_blocked '"rm" x'
  assert_blocked 'r""m x'
  assert_blocked 'unlink foo'
  assert_blocked 'rm -rf "$HOME/x"'
  assert_blocked 'rm -rf ~/x'
}

@test "blocked: rm behind separators, groups and substitutions" {
  assert_blocked 'true; rm a'
  assert_blocked 'make && rm -rf out'
  assert_blocked 'false || rm a'
  assert_blocked 'ls | rm a'
  assert_blocked 'cd x && rm -rf y'
  assert_blocked '(rm x)'
  assert_blocked '{ rm x; }'
  assert_blocked 'if true; then rm x; fi'
  assert_blocked 'while true; do rm x; done'
  assert_blocked 'echo $(rm a)'
  assert_blocked 'echo "$(rm a)"'
  assert_blocked 'echo `rm a`'
  assert_blocked 'diff <(rm a) b'
  assert_blocked 'x=$(rm a)'
  assert_blocked 'ls || rm x'
}

@test "blocked: shells, eval, trap and heredocs that run rm" {
  assert_blocked 'bash -c "rm -rf x"'
  assert_blocked "sh -c 'echo hi; rm x'"
  assert_blocked 'bash -lc "rm x"'
  assert_blocked 'zsh -c "rm x"'
  assert_blocked 'bash -c "rm -rf $UNKNOWN_VAR"'
  assert_blocked "eval 'rm x'"
  assert_blocked "trap 'rm -rf \"\$d\"' EXIT"
  assert_blocked 'echo "rm x" | bash'
  assert_blocked "bash <<'EOF'
rm -rf x
EOF"
  assert_blocked "sudo bash -c 'rm -rf /opt/x'"
}

@test "blocked: find -delete, find -exec rm, xargs rm" {
  assert_blocked 'find . -name "*.o" -delete'
  assert_blocked 'find ~/proj -name x -exec rm {} \;'
  assert_blocked 'find . -type f -exec rm -f {} +'
  assert_blocked 'find . -exec sudo rm {} \;'
  assert_blocked "find . -exec sh -c 'rm \"\$1\"' _ {} \\;"
  assert_blocked 'ls | xargs rm'
  assert_blocked 'ls | xargs -0 -n1 rm -f'
  assert_blocked 'ls | xargs -I {} rm {}'
  assert_blocked 'find /tmp/x -name y | xargs rm'   # stdin targets cannot be proven temp
  assert_blocked 'ls | xargs -I{} rm {}'            # attached option, no space
  assert_blocked 'ls | xargs -0 -I{} /bin/rm {}'
  assert_blocked "git commit -m \"\$(cat <<'EOF'
fix: don't touch x
EOF
)\" && rm -rf ~/x"                                  # apostrophe in a heredoc body inside \$( )
}

@test "blocked: targets that are not provably temp" {
  assert_blocked 'rm -rf $UNKNOWN'
  assert_blocked 'rm -rf "$(cat list)"'
  assert_blocked 'for f in a b; do rm "$f"; done'
  assert_blocked 'rm -rf /tmp/../etc'
  assert_blocked 'rm -rf /tmp'                 # the temp root itself is not a target
  assert_blocked 'rm -rf /tmp/'
  assert_blocked 'rm -rf /tmp/{a,../etc}'      # brace expansion escapes the prefix
  assert_blocked 'rm -rf /tmp/.*'              # .* can match ..
  assert_blocked 'rm /tmp/ok /etc/bad'         # one bad target blocks the call
  assert_blocked 'rm x; rm /tmp/y'
  assert_blocked 'x=$(echo /tmp); rm $x/y'
  assert_blocked 'cd /tmp/x || cd ~/p; rm foo' /tmp
  assert_blocked 'cd /tmp/x && (cd /etc; rm y)' /tmp
  assert_blocked 'rm foo' /Users
}

@test "blocked: a symlink inside /tmp does not launder a target" {
  ln -s /etc "$BATS_TEST_TMPDIR/escape"
  assert_blocked "rm -rf $BATS_TEST_TMPDIR/escape/"
  assert_blocked "rm $BATS_TEST_TMPDIR/escape/../x" /Users
}

# -- allowed ---------------------------------------------------------------

@test "allowed: other tools whose name contains rm / delete" {
  assert_allowed 'git rm foo'
  assert_allowed 'git rm -rf dir'
  assert_allowed 'docker rm c1'
  assert_allowed 'docker rm -f $(docker ps -aq)'
  assert_allowed 'kubectl delete pod x'
  assert_allowed 'npm rm lodash'
  assert_allowed 'pnpm remove x'
  assert_allowed 'rmdir emptydir'
  assert_allowed 'git branch -d topic'
}

@test "allowed: the word rm as data" {
  assert_allowed 'echo rm -rf x'
  assert_allowed 'echo "rm -rf /"'
  assert_allowed 'printf "%s\n" "do not rm this"'
  assert_allowed 'grep rm file'
  assert_allowed 'grep -rn "rm -rf" .'
  assert_allowed "git commit -m 'rm the old file; rm -rf x'"
  assert_allowed 'git commit -m "$(cat <<EOF
fix: rm old stuff
rm -rf x
EOF
)"'
  assert_allowed 'cat <<EOF
rm -rf x
EOF'
  assert_allowed 'echo hi > /tmp/rm'
  assert_allowed 'ls | grep rm'
  assert_allowed 'command -v rm'
  assert_allowed 'which rm'
  assert_allowed 'ssh host rm x'
  assert_allowed 'bash script.sh'
  assert_allowed '# rm -rf x'
  assert_allowed 'alias rm=trash'
}

@test "allowed: rm with no target, plain commands" {
  assert_allowed 'rm'
  assert_allowed 'rm -rf'
  assert_allowed 'git status && git push'
  assert_allowed 'echo $(date)'
  assert_allowed 'cd /tmp/x && (cd /etc; ls) && rm y'
}

@test "allowed: every target under /tmp, /private/tmp or TMPDIR" {
  assert_allowed 'rm -rf /tmp/foo'
  assert_allowed 'rm -f /private/tmp/foo/bar'
  assert_allowed 'rm -rf /tmp/*'
  assert_allowed 'rm -rf "/tmp/x y"'
  assert_allowed 'rm -rf /tmp/a /tmp/b'
  assert_allowed 'unlink /tmp/f'
  assert_allowed 'sudo rm -rf /tmp/x'
  assert_allowed 'bash -c "rm -rf /tmp/x"'
  assert_allowed 'find /tmp/x -name "*.o" -delete'
  assert_allowed 'find /tmp/x -exec rm {} \;'
  assert_allowed 'find /tmp/x -exec rm -f {} +'
  assert_allowed 'rm foo' /tmp/work
  assert_allowed 'rm -rf sub' /private/tmp/work
  assert_allowed 'find . -delete' /tmp/work
}

@test "allowed: temp paths held in variables, cd, TMPDIR and mktemp" {
  assert_allowed 'TARGET="/tmp/T1-x-target"
rm -rf "$TARGET"'
  assert_allowed 'TARGET=/tmp/T1; rm -rf "$TARGET" && git clone a "$TARGET"'
  assert_allowed 'export D=/tmp/x; rm -rf $D'
  assert_allowed 'cd /tmp/work && rm -rf sub'
  assert_allowed 'cd /tmp/work && rm -f a b'
  assert_allowed 'd=$(mktemp -d); rm -rf "$d"'
  assert_allowed 'd="$(mktemp -d)"; rm -rf "$d/sub"'
  assert_allowed 'd=$(mktemp -d /tmp/x.XXXXXX); rm -rf "$d"'
  assert_allowed 'tmp=$(mktemp); trap '"'"'rm -f "$tmp"'"'"' EXIT'
  assert_allowed "d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT"
}

@test "TMPDIR is honored (a dir outside /tmp)" {
  local d="$TMPDIR_TEST_DIR"
  mkdir -p "$d"
  case "$(cd -P "$d" && pwd -P)" in /tmp/*|/private/tmp/*) skip "checkout lives under /tmp; cannot build a non-temp TMPDIR" ;; esac
  TMPDIR="$d" assert_allowed 'rm -rf $TMPDIR/x'
  TMPDIR="$d" assert_allowed 'rm -rf "${TMPDIR:-/tmp}/taskid-remote.$$"'
  TMPDIR="$d" assert_allowed "rm -rf $d/y"
  TMPDIR="$d" assert_blocked 'rm -rf $TMPDIR'
  assert_blocked "rm -rf $d/y"
}

@test "a TMPDIR of / or HOME or above does not disable the guard" {
  TMPDIR=/ assert_blocked 'rm -rf /etc/x'
  TMPDIR=/ assert_blocked 'rm -rf /Users/x/y'
  HOME=/nonexistent-home/me TMPDIR=/nonexistent-home assert_blocked 'rm -rf /nonexistent-home/me/x'
  HOME=/nonexistent-home/me TMPDIR=/nonexistent-home/me assert_blocked 'rm -rf /nonexistent-home/me/x'
}

# -- decision output --------------------------------------------------------

@test "deny output: JSON permissionDecision with the trash.sh path and an exit 0" {
  run run_hook 'rm -rf build'
  [ "$status" -eq 0 ]
  [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" = PreToolUse ]
  [ "$(decision)" = deny ]
  reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")"
  [[ "$reason" == *"$REPO_ROOT/agent-pairing/scripts/trash.sh"* ]]
  [[ "$reason" == *"list what you moved"* ]]
  [[ "$reason" == *"/tmp"* ]]
  [[ "$reason" == *"CCXP_ALLOW_RM=1"* ]]
  [[ "$reason" == *"rm -rf build"* ]]
  [ -f "$REPO_ROOT/agent-pairing/scripts/trash.sh" ]
}

@test "deny output: trash.sh missing -> falls back to mv into ~/.Trash" {
  d="$BATS_TEST_TMPDIR/plug"; mkdir -p "$d/hooks"
  cp "$REPO_ROOT"/hooks/rm-guard.* "$d/hooks/"
  run bash -c "jq -n '{tool_name:\"Bash\",tool_input:{command:\"rm x\"},cwd:\"/nonexistent-home\"}' | '$d/hooks/rm-guard.sh'"
  [ "$status" -eq 0 ]
  [ "$(decision)" = deny ]
  [[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")" == *"~/.Trash"* ]]
}

@test "a deny blocks nothing but still names every offender once (first three)" {
  run run_hook 'rm a; rm b; rm c; rm d'
  reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")"
  [[ "$reason" == *"rm a"* && "$reason" == *"rm c"* && "$reason" != *"rm d"* ]]
}

# -- escape hatch and fail-open ----------------------------------------------

@test "escape hatch: CCXP_ALLOW_RM=1 lets rm through" {
  CCXP_ALLOW_RM=1 run run_hook 'rm -rf build'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "escape hatch: only the exact value 1 counts" {
  CCXP_ALLOW_RM=0 assert_blocked 'rm -rf build'
  CCXP_ALLOW_RM=yes assert_blocked 'rm -rf build'
}

@test "escape hatch: an inline CCXP_ALLOW_RM=1 in the command does not count" {
  assert_blocked 'CCXP_ALLOW_RM=1 rm -rf build'
}

@test "non-Bash tool_name and empty command: no opinion" {
  run bash -c "echo '{\"tool_name\":\"Edit\",\"tool_input\":{\"command\":\"rm x\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  assert_allowed ''
  assert_allowed '   '
}

@test "fail open: unparsable command is allowed and logged on stderr" {
  for bad in 'rm "unterminated' "rm 'unterminated" 'rm $(unterminated'; do
    BAD="$bad" run bash -c "jq -n --arg c \"\$BAD\" '{tool_name:\"Bash\",tool_input:{command:\$c},cwd:\"/x\"}' | '$HOOK' 2>$BATS_TEST_TMPDIR/err"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q '^rm-guard: could not analyze' "$BATS_TEST_TMPDIR/err"
  done
}

@test "fail open: invalid JSON on stdin" {
  run bash -c "echo 'not json' | '$HOOK' 2>$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '^rm-guard:' "$BATS_TEST_TMPDIR/err"
}

@test "fail open: analyzer crash (non-zero exit) is allowed and logged" {
  d="$BATS_TEST_TMPDIR/broken"; mkdir -p "$d"
  cp "$HOOK" "$d/rm-guard.sh"
  printf 'import sys\nsys.exit(3)\n' > "$d/rm-guard.py"
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm x\"}}' | '$d/rm-guard.sh' 2>$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '^rm-guard: analyzer exited 3' "$BATS_TEST_TMPDIR/err"
}

@test "fail open: no python3 on PATH" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for t in dirname cat; do ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm x\"}}' | PATH='$BATS_TEST_TMPDIR/bin' '$BASH' '$HOOK' 2>$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'python3 not found' "$BATS_TEST_TMPDIR/err"
}

# -- registration -------------------------------------------------------------

@test "hooks.json registers rm-guard.sh on the Bash matcher; scripts are executable" {
  run jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | .[]' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = '"${CLAUDE_PLUGIN_ROOT}/hooks/rm-guard.sh"' ]
  [ -x "$REPO_ROOT/hooks/rm-guard.sh" ]
}

@test "hooks.json: the Bash command runs the hook from a root with a space" {
  d="$BATS_TEST_TMPDIR/plug in"; mkdir -p "$d/hooks"
  cp "$REPO_ROOT"/hooks/rm-guard.* "$d/hooks/"
  cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$REPO_ROOT/hooks/hooks.json")"
  run env CLAUDE_PLUGIN_ROOT="$d" sh -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\"},\"cwd\":\"/nonexistent-home\"}' | $cmd"
  [ "$status" -eq 0 ]
  [ "$(decision)" = deny ]
}

# -- the plugin's own docs/skills ---------------------------------------------

@test "audit: drive's cross-repo clone snippet passes (explicit rm -rf of a /tmp clone)" {
  assert_allowed 'TARGET="/tmp/T20260101-000000-slug-target"
rm -rf "$TARGET"          # idempotent: kill any leftover from a prior crashed run'
  assert_allowed 'rm -rf /tmp/T20260101-000000-slug-target'
}

@test "audit: autopilot's dispatch clone lives under /tmp, so removing it passes" {
  grep -q "/tmp/autopilot-clone-" "$REPO_ROOT/autopilot/scripts/autopilot-state.sh"
  assert_allowed 'rm -rf /tmp/autopilot-clone-myrepo-abc123'
}
