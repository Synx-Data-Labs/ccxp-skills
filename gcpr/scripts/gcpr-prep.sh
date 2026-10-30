#!/usr/bin/env bash
# gcpr-prep.sh — the mechanical prep for /gcpr (and its alias /land): assess the
# tree, lint the changed docs, name the branch, flip a task to Review, check for
# secrets, build the PR body. It never commits, pushes or opens a PR: those stay
# with the skill (via _gh/git.sh and _gh/gh.sh). Judgment (commit grouping,
# message wording, checklist content) stays with the agent and arrives as input.
#
# Usage:
#   gcpr-prep.sh assess [--base main]
#       Prints STATE=, BRANCH=, BASE=, AHEAD=, PR= lines. STATE is one of
#         dirty              uncommitted changes (go group + commit, steps 2-4)
#         clean-main         on the base branch, nothing to do
#         clean-no-commits   feature branch, no commits ahead of base
#         ahead-no-pr        commits ahead, no PR: jump to push + create PR
#         ahead-pr:<n>       commits ahead and PR <n> exists: hand off to /address-pr
#         unknown            could not decide (gh failure): treat as a stop
#       Exit 0 = there is something to do, 3 = nothing to do, 2 = usage/git
#       problem, 4 = the PR lookup failed.
#   gcpr-prep.sh changed md|tasks|refs
#       Changed, non-deleted paths (renames resolved to the new path): all .md
#       (md), dev/TODO|PARKING .md (tasks), dev/TODO|JOURNAL .md (refs).
#   gcpr-prep.sh lint
#       The step 1.5 bundle (lint-docs, lint_paragraphs, lint_refs --fix) over the
#       changed files. Check-then-continue: always exit 0 once it ran. Prints
#       one LINT line with the counts.
#   gcpr-prep.sh branch-name <feat|fix|docs|chore|refactor|test|ci> <text...>
#   gcpr-prep.sh branch-name --check <name> [--base main]
#       First form prints <type>/<slug>; second validates an explicit name
#       (exit 0 ok, 1 invalid or the base branch itself).
#   gcpr-prep.sh review-flip T<id> [--dry-run]
#       Flip dev/TODO/T<id>-*.md from `status: In Progress` to `Review` (step
#       6.5, before the commit). Exit 0 flipped, 3 nothing to flip (no file, or
#       another status), 2 usage/ambiguous.
#   gcpr-prep.sh secrets-check [--base B]
#       Fails closed on the changed files (and, with --base, on the files changed
#       in B...HEAD). Prints BLOCK <path>:<line> <rule> lines (never the matched
#       text) and SECRETS=clean|blocked. Exit 0 clean, 1 blocked, 2 could not run
#       (also a block). Binary files other than known media, symlinks and
#       unreadable files are blocked as unscannable.
#   gcpr-prep.sh body --summary-file F [--pre F] [--post F] [--task-url U] [--footer TEXT]
#       Prints the PR body skeleton: Summary (+ `Task:` line), Test plan with both
#       ### Pre-merge and ### Post-merge (an empty or absent file becomes N/A).
#       Exit 2 on an empty summary or a non-http(s) task URL.
#
# Env: GCPR_GH overrides the gh wrapper (default: the sibling _gh/gh.sh).
set -uo pipefail

GP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GP_ROOT="$(cd "$GP_DIR/../.." && pwd)"

_gp_die() { echo "gcpr-prep: $*" >&2; exit 2; }

# _gp_changed_all [--for-scan] — changed paths from the working tree (NUL-safe
# parse of porcelain v1 -z), one per line; renames -> new path. By default any
# entry with a delete on either side is skipped (nothing to lint). --for-scan
# keeps entries whose index side still exists (e.g. staged then deleted in the
# worktree, "AD"), so a staged secret is not missed.
_gp_changed_all() {
  local rec xy path skip_next=0 scan=0
  [ "${1:-}" = "--for-scan" ] && scan=1
  while IFS= read -r -d '' rec; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    xy="${rec:0:2}"; path="${rec:3}"
    case "$xy" in *R*|*C*) skip_next=1 ;; esac
    if [ "$scan" = 1 ]; then
      case "$xy" in "D "|" D") continue ;; esac
    else
      case "$xy" in *D*) continue ;; esac
    fi
    printf '%s\n' "$path"
  done < <(git status --porcelain -z --untracked-files=all)
}

_gp_resolve_base() {
  local base="$1"
  if git rev-parse --verify -q "refs/heads/$base" >/dev/null; then printf '%s' "$base"
  elif git rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null; then printf 'origin/%s' "$base"
  else return 1; fi
}

gp_assess() {
  local base=main
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || _gp_die "--base needs a value"; base="$2"; shift 2 ;;
      *) _gp_die "assess: unknown argument: $1" ;;
    esac
  done
  git rev-parse --git-dir >/dev/null 2>&1 || _gp_die "not a git repository"
  local branch dirty ref ahead pr gh_cmd
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || _gp_die "cannot read HEAD (no commits yet?)"
  [ "$branch" != HEAD ] || _gp_die "detached HEAD: check out a branch first"
  dirty="$(git status --porcelain --untracked-files=all)" || _gp_die "git status failed"
  dirty="$(printf '%s' "$dirty" | grep -c '^' || true)"
  ref="$(_gp_resolve_base "$base")" || _gp_die "base branch '$base' not found (local or origin)"
  ahead="$(git rev-list --count "$ref..HEAD")" || _gp_die "git rev-list failed"
  printf 'BRANCH=%s\nBASE=%s\nAHEAD=%s\n' "$branch" "$base" "$ahead"
  if [ "$dirty" -gt 0 ]; then
    printf 'DIRTY=%s\nSTATE=dirty\n' "$dirty"; return 0
  fi
  if [ "$branch" = "$base" ] && [ "$ahead" -eq 0 ]; then echo "STATE=clean-main"; return 3; fi
  if [ "$ahead" -eq 0 ]; then echo "STATE=clean-no-commits"; return 3; fi
  gh_cmd="${GCPR_GH:-bash $GP_ROOT/_gh/gh.sh}"
  # shellcheck disable=SC2086  # the wrapper may be a multi-word command
  if ! pr="$($gh_cmd pr list --head "$branch" --state all --json number --jq '.[].number' 2>/dev/null)"; then
    echo "STATE=unknown"; echo "gcpr-prep: PR lookup failed; do not guess, stop and report" >&2; return 4
  fi
  pr="$(printf '%s\n' "$pr" | head -n1)"
  case "$pr" in ''|*[!0-9]*)
    if [ -n "$pr" ]; then echo "STATE=unknown"; echo "gcpr-prep: unexpected PR lookup output; stop and report" >&2; return 4; fi ;;
  esac
  if [ -n "$pr" ]; then printf 'PR=%s\nSTATE=ahead-pr:%s\n' "$pr" "$pr"
  else echo "STATE=ahead-no-pr"; fi
  return 0
}

gp_changed() {
  [ $# -eq 1 ] || _gp_die "changed: need md|tasks|refs"
  git rev-parse --git-dir >/dev/null 2>&1 || _gp_die "not a git repository"
  case "$1" in
    md)    _gp_changed_all | grep -E '\.md$' || true ;;
    tasks) _gp_changed_all | grep -E '^dev/(TODO|PARKING)/.*\.md$' || true ;;
    refs)  _gp_changed_all | grep -E '^dev/(TODO|JOURNAL)/.*\.md$' || true ;;
    *) _gp_die "changed: unknown kind: $1" ;;
  esac
}

gp_lint() {
  local md tasks refs n_md=0 n_t=0 n_r=0 f
  local -a a
  md="$(gp_changed md)"; tasks="$(gp_changed tasks)"; refs="$(gp_changed refs)"
  if [ -n "$md" ]; then
    a=(); while IFS= read -r f; do a+=("$f"); done <<<"$md"; n_md=${#a[@]}
    bash "$GP_ROOT/_docs/lint-docs.sh" "${a[@]}" \
      || echo "::warning::lint-docs: markdown issues remain; CI Markdown Lint will gate" >&2
  fi
  if [ -n "$tasks" ]; then
    a=(); while IFS= read -r f; do a+=("$f"); done <<<"$tasks"; n_t=${#a[@]}
    python3 "$GP_ROOT/repo-conventions/scripts/lint_paragraphs.py" --changed "${a[@]}" || true
  fi
  if [ -n "$refs" ]; then
    a=(); while IFS= read -r f; do a+=("$f"); done <<<"$refs"; n_r=${#a[@]}
    python3 "$GP_ROOT/repo-conventions/scripts/lint_refs.py" --fix --changed "${a[@]}" || true
  fi
  printf 'LINT md=%s tasks=%s refs=%s\n' "$n_md" "$n_t" "$n_r"
}

gp_branch_name() {
  if [ "${1:-}" = "--check" ]; then
    [ $# -ge 2 ] || _gp_die "branch-name --check needs a name"
    local name="$2" base=main
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --base) [ $# -ge 2 ] || _gp_die "--base needs a value"; base="$2"; shift 2 ;;
        *) _gp_die "branch-name: unknown argument: $1" ;;
      esac
    done
    [ "$name" != "$base" ] && [ "$name" != main ] && [ "$name" != master ] || return 1
    git check-ref-format --branch "$name" >/dev/null 2>&1 || return 1
    case "$name" in -*) return 1 ;; esac
    return 0
  fi
  [ $# -ge 2 ] || _gp_die "branch-name: need <type> <text...>"
  local type="$1" slug; shift
  case "$type" in feat|fix|docs|chore|refactor|test|ci) ;; *) _gp_die "branch-name: unknown type: $type" ;; esac
  slug="$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')"
  [ -n "$slug" ] || _gp_die "branch-name: text has no usable characters"
  printf '%s/%s\n' "$type" "$slug"
}

gp_review_flip() {
  local id="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      T[0-9]*-[0-9]*) id="$1"; shift ;;
      *) _gp_die "review-flip: unknown argument: $1" ;;
    esac
  done
  printf '%s' "$id" | grep -qE '^T[0-9]{8}-[0-9]{6}$' || _gp_die "review-flip: need a task id like T20000101-000001"
  local -a files=()
  local f
  for f in dev/TODO/"$id"-*.md; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -le 1 ] || _gp_die "review-flip: ambiguous, ${#files[@]} files match $id"
  [ "${#files[@]}" -eq 1 ] || { echo "NOOP no-task-file"; return 3; }
  f="${files[0]}"
  local cur
  cur="$(awk '{l=$0; sub(/\r$/,"",l)} NR==1 && l!="---"{exit} NR>1 && l=="---"{exit} /^status:/{sub(/^status:[ \t]*/,""); sub(/[ \t\r]+$/,""); gsub(/^["\x27]|["\x27]$/,""); print; exit}' "$f")"
  if [ "$cur" != "In Progress" ]; then echo "NOOP status=${cur:-none}"; return 3; fi
  if [ "$dry" = 1 ]; then echo "WOULD-FLIP $f"; return 0; fi
  local tmp="$f.gcpr-tmp.$$"
  awk 'BEGIN{fm=0;done=0}
       {l=$0; sub(/\r$/,"",l)}
       NR==1 && l=="---"{fm=1; print; next}
       fm==1 && l=="---"{fm=2}
       fm==1 && !done && /^status:[ \t]*["\x27]?In Progress["\x27]?[ \t\r]*$/{cr=($0 ~ /\r$/) ? "\r" : ""; print "status: Review" cr; done=1; next}
       {print}' "$f" > "$tmp" && cat "$tmp" > "$f"
  local rc=$?
  rm -f "$tmp" 2>/dev/null || true
  [ "$rc" -eq 0 ] || _gp_die "review-flip: could not rewrite $f"
  echo "FLIPPED $f"
}

# --- secrets-check ---------------------------------------------------------

_gp_name_rule() {
  local base; base="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  case "/$1" in */.docker/config.json) echo "credential-file"; return 0 ;; esac
  case "$base" in
    .env.tpl|.env.example|.env.sample|.env.template|.env.dist) return 1 ;;
    .env|.env.*) echo "env-file" ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.tfstate|*.tfstate.*) echo "key-or-state-file" ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519) echo "ssh-private-key" ;;
    .netrc|.pgpass|.htpasswd|.npmrc|.pypirc|.git-credentials|.dockercfg) echo "credential-file" ;;
    credentials|credentials.*|secret.*|secrets.*|service-account*.json) echo "credential-file" ;;
    *) return 1 ;;
  esac
}

_gp_media_ext() {
  case "$(basename "$1" | tr '[:upper:]' '[:lower:]')" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.woff|*.woff2|*.ttf|*.otf|*.mp4|*.mov) return 0 ;;
  esac
  return 1
}

# Content rules: "<rule><TAB><ERE>". The assigned-secret rule is post-filtered.
_GP_RULES=(
  $'private-key\t-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----'
  $'github-token\t(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'
  $'aws-access-key\t(AKIA|ASIA)[0-9A-Z]{16}'
  $'slack-token\txox[abprs]-[A-Za-z0-9-]{10,}'
  $'slack-webhook\thooks\\.slack\\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+'
  $'api-key\t(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
  $'bearer-token\t[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  $'google-api-key\tAIza[0-9A-Za-z_-]{35}'
  $'jwt\teyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}'
  $'url-credentials\t[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@$<{]{4,}@'
)
_GP_ASSIGNED='(pass(word)?|passwd|secret|token|api[_-]?key|private[_-]?key|auth)[A-Za-z0-9_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=_.-]{20,}'
# short passwords: 8+ chars that are not a placeholder/identifier (must hold a digit or symbol)
_GP_PASSWORD='(pass(word)?|passwd|pwd)[A-Za-z0-9_]*["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'$<{(]{8,}'

_GP_HITS=0
_GP_OUT=""
_gp_hit() { printf 'BLOCK %s %s\n' "$1" "$2"; _GP_HITS=$((_GP_HITS + 1)); }

# _gp_grep <label> <rule> <grep-flags> <ERE> <file>: sets _GP_OUT to "line:match"
# rows (no subshell, so hits count); a grep error (exit > 1) is a hit, never silently "no match".
_gp_grep() {
  local label="$1" rule="$2" flags="$3" re="$4" file="$5" rc
  _GP_OUT="$(LC_ALL=C grep "$flags" -- "$re" "$file" 2>/dev/null)"; rc=$?
  if [ "$rc" -gt 1 ]; then _GP_OUT=""; _gp_hit "$label" "unscannable-grep-error:$rule"; fi
}

# _gp_scan_file <file-to-read> <label>
_gp_scan_file() {
  local file="$1" label="$2" entry rule re ln frag val
  if [ -L "$file" ]; then _gp_hit "$label" "unscannable-symlink"; return; fi
  [ -r "$file" ] || { _gp_hit "$label" "unscannable-unreadable"; return; }
  if [ -s "$file" ] && ! LC_ALL=C grep -Iq '' "$file" 2>/dev/null; then
    _gp_media_ext "${label%% (*}" || _gp_hit "$label" "unscannable-binary"
    return
  fi
  for entry in "${_GP_RULES[@]}"; do
    rule="${entry%%$'\t'*}"; re="${entry#*$'\t'}"
    _gp_grep "$label" "$rule" -nE "$re" "$file"
    while IFS= read -r ln; do
      [ -n "$ln" ] && _gp_hit "$label:${ln%%:*}" "$rule"
    done <<<"$_GP_OUT"
  done
  # assigned secrets: the long rule needs a digit in the value; the password rule
  # needs a digit or a symbol (plain identifiers and prose do not block)
  for entry in "assigned-secret"$'\t'"$_GP_ASSIGNED"$'\t''[0-9]' "assigned-password"$'\t'"$_GP_PASSWORD"$'\t''[0-9!@#%^&*+=?]'; do
    rule="${entry%%$'\t'*}"; re="${entry#*$'\t'}"; frag="${re#*$'\t'}"; re="${re%%$'\t'*}"
    _gp_grep "$label" "$rule" -noiE "$re" "$file"
    while IFS=: read -r ln val; do
      [ -n "$ln" ] || continue
      val="$(printf '%s' "$val" | sed -E 's/^[^:=]*[:=][[:space:]]*["'"'"']?//')"
      if printf '%s' "$val" | grep -q "$frag"; then _gp_hit "$label:$ln" "$rule"; fi
    done <<<"$_GP_OUT"
  done
}

gp_secrets_check() {
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || _gp_die "--base needs a value"; base="$2"; shift 2 ;;
      *) _gp_die "secrets-check: unknown argument: $1" ;;
    esac
  done
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "SECRETS=blocked reason=not-a-git-repo"; return 2
  fi
  local -a paths=()
  local p rule ref n=0 tmp c blob seenblob=$'\n'
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(_gp_changed_all --for-scan)
  local -a commits=()
  if [ -n "$base" ]; then
    ref="$(_gp_resolve_base "$base")" || { echo "SECRETS=blocked reason=base-not-found"; return 2; }
    while IFS= read -r c; do [ -n "$c" ] && commits+=("$c"); done < <(git rev-list "$ref..HEAD")
    # every path any commit on the branch touched, so add-then-remove is still seen
    for c in ${commits[@]+"${commits[@]}"}; do
      while IFS= read -r -d '' p; do paths+=("$p"); done \
        < <(git diff-tree --no-commit-id --name-only -r -m -z --diff-filter=ACMRT "$c")
    done
  fi
  tmp="$(mktemp 2>/dev/null)" || { echo "SECRETS=blocked reason=no-tempfile"; return 2; }
  local seen=$'\n'
  for p in ${paths[@]+"${paths[@]}"}; do
    case "$seen" in *$'\n'"$p"$'\n'*) continue ;; esac
    seen+="$p"$'\n'
    n=$((n + 1))
    if rule="$(_gp_name_rule "$p")"; then _gp_hit "$p" "$rule"; fi
    if [ -e "$p" ] || [ -L "$p" ]; then
      _gp_scan_file "$p" "$p"
    fi
    # staged and committed versions can differ from the working tree
    if git cat-file -e ":$p" 2>/dev/null; then
      if git show ":$p" > "$tmp" 2>/dev/null; then _gp_scan_file "$tmp" "$p (index)"
      else _gp_hit "$p (index)" "unscannable-unreadable"; fi
    fi
    for c in ${commits[@]+"${commits[@]}"}; do
      blob="$(git rev-parse -q --verify "$c:$p" 2>/dev/null)" || continue
      case "$seenblob" in *$'\n'"$blob"$'\n'*) continue ;; esac
      seenblob+="$blob"$'\n'
      if git show "$c:$p" > "$tmp" 2>/dev/null; then _gp_scan_file "$tmp" "$p (${c:0:8})"
      else _gp_hit "$p (${c:0:8})" "unscannable-unreadable"; fi
    done
  done
  rm -f "$tmp" 2>/dev/null || true
  if [ "$_GP_HITS" -gt 0 ]; then
    printf 'SECRETS=blocked count=%s files=%s\n' "$_GP_HITS" "$n"
    echo "gcpr-prep: do not stage the blocked paths; fix or leave them out, then re-run" >&2
    return 1
  fi
  printf 'SECRETS=clean files=%s\n' "$n"
}

# --- body ------------------------------------------------------------------

_gp_section() {  # <file> -> its content, or N/A when absent or blank
  if [ -n "${1:-}" ] && [ -f "$1" ] && grep -q '[^[:space:]]' "$1"; then
    sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$1"
  else
    echo "N/A"
  fi
}

gp_body() {
  local summary="" pre="" post="" task="" footer="Generated with [Claude Code](https://claude.com/claude-code)"
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || _gp_die "body: $1 needs a value"
    case "$1" in
      --summary-file) summary="$2" ;;
      --pre) pre="$2" ;;
      --post) post="$2" ;;
      --task-url) task="$2" ;;
      --footer) footer="$2" ;;
      *) _gp_die "body: unknown argument: $1" ;;
    esac
    shift 2
  done
  if ! { [ -f "$summary" ] && grep -q '[^[:space:]]' "$summary"; }; then
    _gp_die "body: --summary-file is required and must not be empty"
  fi
  if [ -n "$task" ]; then
    case "$task" in http://*|https://*) ;; *) _gp_die "body: --task-url must be an http(s) URL" ;; esac
    case "$task" in *[[:space:]]*) _gp_die "body: --task-url must not contain whitespace" ;; esac
  fi
  printf '## Summary\n'
  if [ -n "$task" ]; then printf 'Task: %s\n\n' "$task"; fi
  _gp_section "$summary"
  printf '\n## Test plan\n\n### Pre-merge\n'
  _gp_section "$pre"
  printf '\n### Post-merge\n'
  _gp_section "$post"
  printf '\n%s\n' "$footer"
}

main() {
  local verb="${1:-}"
  [ $# -gt 0 ] && shift
  # paths from git are repo-root-relative; run every verb from the root so a
  # subdirectory cwd cannot make file checks miss (or misplace) anything
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then cd "$top" || _gp_die "cannot enter $top"; fi
  case "$verb" in
    assess) gp_assess "$@" ;;
    changed) gp_changed "$@" ;;
    lint) gp_lint "$@" ;;
    branch-name) gp_branch_name "$@" ;;
    review-flip) gp_review_flip "$@" ;;
    secrets-check) gp_secrets_check "$@" ;;
    body) gp_body "$@" ;;
    *) _gp_die "usage: gcpr-prep.sh assess|changed|lint|branch-name|review-flip|secrets-check|body (see the header)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
