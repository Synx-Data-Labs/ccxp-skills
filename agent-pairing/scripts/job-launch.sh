#!/usr/bin/env bash
# job-launch.sh -- start a detached `claude --bg` job with safe defaults.
#   job-launch.sh <job-number> "<title>" <prompt-file> [options]
# Options: --cwd DIR (default $PWD; must be a trusted, non-git dir, see
#   bg-jobs.md) --add-dir DIR (repeatable) --allow RULE (repeatable extra
#   permission allow rule) --env NAME (repeatable; value read from this
#   shell's env, written only to the 0600 settings file, never to argv/stdout)
#   --model M --plugin-dir DIR (repeatable) --agent NAME (default claude)
# Prompt file may hold an authorization section (see bg-jobs.md):
#   ## Authorization
#   > "<the user's words, quoted>"
#   allow: push | pr-create | pr-merge | workflow-run
# Prints: JOB <n> name=<jN-slug> id=<id> dir=<job dir>
set -euo pipefail

# token -> allow rule; the same rules are denied by default.
function grant-rule() {
  case "$1" in
    push) echo 'Bash(git push *)' ;;
    pr-create) echo 'Bash(gh pr create *)' ;;
    pr-merge) echo 'Bash(gh pr merge *)' ;;
    workflow-run) echo 'Bash(gh workflow run *)' ;;
    *) return 1 ;;
  esac
}

DEFAULT_DENY=('Bash(git push *)' 'Bash(gh pr create *)' 'Bash(gh pr merge *)'
  'Bash(gh workflow run *)' 'Bash(gh release *)' 'Bash(gh repo delete *)')
DEFAULT_ALLOW=(Read Grep Glob Edit Write 'Bash(git status *)' 'Bash(git diff *)'
  'Bash(git log *)' 'Bash(git show *)' 'Bash(git add *)' 'Bash(git commit *)'
  'Bash(git -C * status *)' 'Bash(git -C * log *)' 'Bash(git -C * diff *)'
  'Bash(gh pr view *)' 'Bash(gh pr checks *)' 'Bash(gh run view *)'
  'Bash(gh run list *)' 'Bash(ls *)')

function die() { echo "job-launch: $*" >&2; exit 2; }

function slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  s="${s:0:30}"; s="${s%-}"
  printf '%s' "${s:-job}"
}

# Prints one allow rule per authorization token; fails when the section has
# `allow:` lines but no quoted (`>`) line, or an unknown token.
function parse-authorization() {
  local file="$1" in_sec=0 quoted=0 line tokens=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+Authorization ]]; then in_sec=1; continue; fi
    if (( in_sec )) && [[ "$line" =~ ^## ]]; then in_sec=0; fi
    (( in_sec )) || continue
    [[ "$line" =~ ^\>[[:space:]]*[^[:space:]] ]] && quoted=1
    if [[ "$line" =~ ^allow:[[:space:]]*([a-z-]+)[[:space:]]*$ ]]; then
      tokens+=("${BASH_REMATCH[1]}")
    fi
  done < "$file"
  (( ${#tokens[@]} == 0 )) && return 0
  (( quoted )) || { echo "authorization section has allow: lines but no quoted '>' user text" >&2; return 1; }
  local t
  for t in "${tokens[@]}"; do
    grant-rule "$t" || { echo "unknown authorization token: $t" >&2; return 1; }
  done
}

function build-settings() {
  local out="$1" jobdir="$2"; shift 2
  local -a allow=() deny=() envnames=()
  local a
  while (( $# )); do
    case "$1" in
      --allow) allow+=("$2"); shift 2 ;;
      --envname) envnames+=("$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  allow=("${DEFAULT_ALLOW[@]}" "${allow[@]}")
  for a in "${DEFAULT_DENY[@]}"; do
    local granted=0 g
    for g in "${allow[@]}"; do [[ "$g" == "$a" ]] && granted=1; done
    (( granted )) || deny+=("$a")
  done
  local envjson='{}' n
  for n in ${envnames[@]+"${envnames[@]}"}; do
    [[ -n "${!n:-}" ]] || die "--env $n: not set in this shell"
    # value comes from the environment (env[$n]), never from argv
    envjson="$(printf '%s' "$envjson" | jq --arg n "$n" '. + {($n): env[$n]}')"
  done
  (
    umask 077
    jq -n \
      --argjson allow "$(printf '%s\n' "${allow[@]}" | jq -R . | jq -s .)" \
      --argjson deny "$(printf '%s\n' ${deny[@]+"${deny[@]}"} | jq -R 'select(length>0)' | jq -s .)" \
      --argjson env "$envjson" \
      --arg stop "date +%s > '$jobdir/last-stop'" \
      '{crossSessionInbound:"accept", env:$env,
        permissions:{allow:$allow, deny:$deny},
        hooks:{Stop:[{hooks:[{type:"command", command:$stop}]}]}}' > "$out"
  )
  chmod 600 "$out"
}

function launch() {
  (( $# >= 3 )) || die "usage: job-launch.sh <job-number> \"<title>\" <prompt-file> [options]"
  local num="$1" title="$2" pfile="$3"; shift 3
  [[ "$num" =~ ^[0-9]+$ ]] || die "job number must be an integer"
  [[ -s "$pfile" ]] || die "prompt file missing or empty: $pfile"
  command -v jq >/dev/null || die "jq is required"
  local cwd="$PWD" model="" agent="claude" st_args=() adddirs=() plugdirs=()
  while (( $# )); do
    case "$1" in
      --cwd) cwd="$2"; shift 2 ;;
      --add-dir) adddirs+=("$2"); shift 2 ;;
      --allow) st_args+=(--allow "$2"); shift 2 ;;
      --env) st_args+=(--envname "$2"); shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --plugin-dir) plugdirs+=("$2"); shift 2 ;;
      --agent) agent="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -d "$cwd" ]] || die "--cwd not a directory: $cwd"
  local name
  name="j${num}-$(slugify "$title")"
  local base="${CCXP_JOBS_DIR:-${TMPDIR:-/tmp}/ccxp-jobs}"
  local jobdir="$base/$name"
  mkdir -p "$base"; chmod 700 "$base" 2>/dev/null || true
  mkdir -p "$jobdir"; chmod 700 "$jobdir"
  cp "$pfile" "$jobdir/prompt.md"

  local grants
  grants="$(parse-authorization "$pfile")" || die "bad authorization section"
  while IFS= read -r g; do [[ -n "$g" ]] && st_args+=(--allow "$g"); done <<< "$grants"
  build-settings "$jobdir/settings.json" "$jobdir" ${st_args[@]+"${st_args[@]}"}

  local -a cmd=(claude --bg --name "$name" --agent "$agent" --permission-mode dontAsk
    --settings "$jobdir/settings.json")
  [[ -n "$model" ]] && cmd+=(--model "$model")
  local d
  for d in ${plugdirs[@]+"${plugdirs[@]}"}; do cmd+=(--plugin-dir "$d"); done
  for d in ${adddirs[@]+"${adddirs[@]}"}; do cmd+=(--add-dir "$d"); done
  # variadic flags above would swallow the prompt: it goes last, after `--`
  cmd+=(-- "$(cat "$pfile")")

  local out id
  out="$(cd "$cwd" && "${cmd[@]}" 2>&1)" || true
  if grep -q 'Workspace not trusted' <<< "$out"; then
    echo "$out" >&2
    echo "job-launch: $cwd is not a trusted workspace. A git root needs its own trust; use a trusted non-git --cwd plus --add-dir <clone> (see agent-pairing/bg-jobs.md)." >&2
    return 3
  fi
  id="$(sed -nE 's/^backgrounded[^0-9a-f]*([0-9a-f]{8}).*/\1/p' <<< "$out" | head -1)"
  [[ -n "$id" ]] || { echo "$out" >&2; die "could not parse job id from claude output"; }
  jq -n --arg n "$num" --arg name "$name" --arg id "$id" --arg cwd "$cwd" \
    '{number:($n|tonumber), name:$name, id:$id, cwd:$cwd}' > "$jobdir/job.json"
  echo "JOB $num name=$name id=$id dir=$jobdir"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  launch "$@"
fi
