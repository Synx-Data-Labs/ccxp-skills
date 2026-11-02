#!/usr/bin/env bash
# repos.sh — repo registry for multi-repo awareness (T20261031-139856).
#
# A "repo" here is a folder that is a git repo (.git dir or file) AND has a
# dev/TODO/ directory (--all: any git repo). `scan` finds them and writes the
# registry; `list` reads it; `paths` prints candidate repo roots for other libs.
#
#   repos.sh scan [path] [--depth N] [--all] [--roots a:b]
#   repos.sh list [--json] [--fresh]
#   repos.sh paths
#
# Files (both honour CLAUDE_CONFIG_DIR, default ~/.claude):
#   ccxp-repos.json         registry {roots, exclude, repos}; hand-edit `aliases`
#   state/ccxp-repos.json   cache of live fields (branch, dirty, task counts)
#
# Scanned repos are only ever read (git -C ... read verbs, file reads): no
# writes into them, no claims, no network. The only writes are the two files
# above (atomic temp + mv). Bash 3.2 compatible (macOS); needs jq.
#
# Sourceable: functions only; the CLI runs solely under the guard at the bottom.

REPOS_CACHE_TTL="${REPOS_CACHE_TTL:-600}"
REPOS_DEFAULT_DEPTH=2   # 1 level of children + the owner/repo container level

function repos-die() { printf 'repos: %s\n' "$*" >&2; return "${REPOS_RC:-2}"; }

function repos-config-dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
function repos-registry-file() { printf '%s/ccxp-repos.json\n' "$(repos-config-dir)"; }
function repos-cache-file() { printf '%s/state/ccxp-repos.json\n' "$(repos-config-dir)"; }

# repos-mtime <path> — epoch mtime, GNU first then BSD; 0 when unreadable.
function repos-mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

# repos-abs <dir> — physical absolute path, or nothing + rc 1.
function repos-abs() { (CDPATH='' cd -- "$1" >/dev/null 2>&1 && pwd -P) || return 1; }

# repos-expand <path> — leading ~ to $HOME.
function repos-expand() {
  # shellcheck disable=SC2088
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# repos-short <path> — $HOME back to ~ for display.
function repos-short() {
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# repos-toplevel [dir] — git toplevel of dir (default $PWD), or nothing.
function repos-toplevel() { git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true; }

# repos-main-of <toplevel> — main worktree root for a repo or linked worktree.
function repos-main-of() {
  local top="$1" common
  common="$(CDPATH='' cd -- "$top" >/dev/null 2>&1 && CDPATH='' cd -- "$(git rev-parse --git-common-dir 2>/dev/null)" >/dev/null 2>&1 && pwd -P)" || return 1
  [ "$(basename "$common")" = ".git" ] || return 1
  dirname "$common"
}

# repos-git-kind <dir> — main | worktree | submodule | other | none
function repos-git-kind() {
  local g="$1/.git" line
  if [ -d "$g" ]; then printf 'main\n'; return 0; fi
  if [ -f "$g" ]; then
    line="$(head -n1 "$g" 2>/dev/null || true)"
    case "$line" in
      *"/.git/worktrees/"*) printf 'worktree\n' ;;
      *"/.git/modules/"*) printf 'submodule\n' ;;
      *) printf 'other\n' ;;
    esac
    return 0
  fi
  printf 'none\n'
}

# repos-qualifies <main-dir> <all> — 0 when the repo belongs in the registry.
function repos-qualifies() {
  if [ "${2:-0}" = 1 ]; then return 0; fi
  [ -d "$1/dev/TODO" ]
}

# repos-slug <dir> — owner/repo from origin, or empty.
function repos-slug() {
  local u
  u="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  u="${u%.git}"; u="${u%/}"
  [ -n "$u" ] || return 0
  printf '%s\n' "$u" | awk -F'[:/]' 'NF>=2 { print $(NF-1) "/" $NF }'
}

# --- registry file ---------------------------------------------------------

# repos-registry-read — registry JSON on stdout ('{}' when absent); rc 6 and a
# message when the file exists but is not valid JSON (never overwritten then).
function repos-registry-read() {
  local f
  f="$(repos-registry-file)"
  if [ ! -f "$f" ]; then printf '{}\n'; return 0; fi
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    REPOS_RC=6 repos-die "registry $f is not valid JSON; fix or move it (not overwritten)"
    return 6
  fi
  cat "$f"
}

# repos-write-atomic <file> — stdin to file via temp + mv.
function repos-write-atomic() {
  local f="$1" tmp
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "$(dirname "$f")/.ccxp-repos.XXXXXX")"
  cat >"$tmp" && mv "$tmp" "$f"
}

# --- walking ---------------------------------------------------------------

# repos-excluded <name> <exclude-lines> — 0 when name matches an exclude glob.
function repos-excluded() {
  local name="$1" pat
  case "$name" in node_modules|.*) return 0 ;; esac
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$name" in $pat) return 0 ;; esac
  done <<<"$2"
  return 1
}

# repos-walk <dir> <levels> <all> <exclude-lines> — appends `main\t<path>` /
# `wt\t<path>` lines to the variable REPOS_WALK_OUT, every folder it looked
# inside to REPOS_WALK_DIRS and skipped symlinks to REPOS_WALK_SKIPPED (plain
# variables, no temp files, so nothing needs cleaning up). Never descends into a git folder, a symlink or an excluded
# folder; descends into plain folders while levels remain.
function repos-walk() {
  local dir="$1" levels="$2" all="$3" excl="$4" child c kind
  REPOS_WALK_DIRS="${REPOS_WALK_DIRS}${dir}
"
  for child in "$dir"/*/; do
    [ -d "$child" ] || continue
    c="${child%/}"
    if [ -L "$c" ]; then REPOS_WALK_SKIPPED="${REPOS_WALK_SKIPPED}${c}
"; continue; fi
    repos-excluded "$(basename "$c")" "$excl" && continue
    kind="$(repos-git-kind "$c")"
    case "$kind" in
      main) if repos-qualifies "$c" "$all"; then REPOS_WALK_OUT="${REPOS_WALK_OUT}main	${c}
"; fi ;;
      worktree) REPOS_WALK_OUT="${REPOS_WALK_OUT}wt	${c}
" ;;
      none) if [ "$levels" -gt 1 ]; then repos-walk "$c" "$((levels - 1))" "$all" "$excl"; fi ;;
      *) ;;  # submodule / unknown .git file: skipped
    esac
  done
}

# repos-collect <root> <levels> <all> <exclude-lines> — walk a root, treating a
# root that is itself a repo as one result, and resolve linked worktrees to
# their main repo. Sets REPOS_COLLECTED (unique main-repo paths, one per line);
# also accumulates REPOS_WALK_DIRS / REPOS_WALK_SKIPPED (callers reset them).
function repos-collect() {
  local root="$1" levels="$2" all="$3" excl="$4" kind
  REPOS_WALK_OUT=""
  kind="$(repos-git-kind "$root")"
  case "$kind" in
    main) if repos-qualifies "$root" "$all"; then REPOS_WALK_OUT="main	${root}
"; fi ;;
    worktree) REPOS_WALK_OUT="wt	${root}
" ;;
    none) repos-walk "$root" "$levels" "$all" "$excl" ;;
    *) ;;
  esac
  local type p m out=""
  while IFS="$(printf '\t')" read -r type p; do
    [ -n "$p" ] || continue
    if [ "$type" = main ]; then out="${out}${p}
"; continue; fi
    m="$(repos-main-of "$p" || true)"
    if [ -n "$m" ] && [ "$(repos-git-kind "$m")" = main ] && repos-qualifies "$m" "$all"; then
      out="${out}${m}
"
    fi
  done <<<"$REPOS_WALK_OUT"
  REPOS_COLLECTED="$(printf '%s' "$out" | grep . | LC_ALL=C sort -u || true)"
}

# --- live fields -----------------------------------------------------------

# repos-wt-list <main> — linked worktree paths of a main repo (existing dirs).
function repos-wt-list() {
  local p
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{sub(/^worktree /,""); print}' | tail -n +2 \
    | while IFS= read -r p; do [ -d "$p" ] && printf '%s\n' "$p"; done
  return 0
}

# repos-live-fields <dir> — one TSV line: branch dirty open_tasks top_task.
function repos-live-fields() {
  local d="$1" branch dirty="false" open=0 top="" f q
  branch="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    branch="($(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo '?'))"
  fi
  if [ -n "$(GIT_NO_LAZY_FETCH=1 git -c core.fsmonitor=false --no-optional-locks -C "$d" status --porcelain -uno 2>/dev/null | head -n1)" ]; then dirty="true"; fi
  for f in "$d"/dev/TODO/T*.md; do
    [ -f "$f" ] && open=$((open + 1))
  done
  q="$d/dev/TODO/queue.md"
  if [ -f "$q" ]; then
    top="$(grep '^- \[T' "$q" 2>/dev/null | grep -v '~~' | head -n1 \
      | sed -E 's/^- \[([^]]+)\]\([^)]*\):?[[:space:]]*/\1 /; s/^- //' | tr '\t' ' ' || true)"
    top="${top:0:80}"
  fi
  printf '%s\t%s\t%s\t%s\n' "$branch" "$dirty" "$open" "$top"
}

# repos-live-record <path> <name> <slug> <aliases-json> — one repo with live fields.
function repos-live-record() {
  local p="$1" name="$2" slug="$3" aliases="$4" fields wts="" w wf
  fields="$(repos-live-fields "$p")"
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    wf="$(repos-live-fields "$w")"
    wts="${wts}${w}	$(basename "$w")	${wf}
"
  done <<<"$(repos-wt-list "$p")"
  printf '%s\t%s\n' "$p" "$fields" | jq -R -s \
    --arg name "$name" --arg slug "$slug" --argjson aliases "$aliases" --arg wts "$wts" '
    def rec: {branch:.[0], dirty:(.[1]=="true"), open_tasks:(.[2]|tonumber), top_task:(.[3] // "")};
    (split("\n")|map(select(length>0)|split("\t"))|.[0]) as $r
    | {path:$r[0], name:$name, slug:$slug, aliases:$aliases}
      + ($r[1:] | rec)
      + {worktrees: ($wts | split("\n") | map(select(length>0)|split("\t"))
          | map({path:.[0], name:.[1]} + (.[2:] | rec)))}'
}

# repos-live-json <registry-json> — array of live records for registry repos
# whose path still exists.
function repos-live-json() {
  local line p name slug aliases out="" first=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="$(printf '%s' "$line" | jq -r '.path')"
    [ -d "$p" ] || continue
    name="$(printf '%s' "$line" | jq -r '.name')"
    slug="$(printf '%s' "$line" | jq -r '.slug // ""')"
    aliases="$(printf '%s' "$line" | jq -c '.aliases // []')"
    if [ "$first" = 1 ]; then first=0; else out="${out},"; fi
    out="${out}$(repos-live-record "$p" "$name" "$slug" "$aliases" | jq -c .)"
  done <<<"$(printf '%s' "$1" | jq -c '.repos // [] | .[]')"
  printf '[%s]\n' "$out" | jq -c 'sort_by([.name, .path])'
}

# --- cache -----------------------------------------------------------------

# repos-dir-mtimes <dirs> — newline separated dirs to a JSON object dir -> mtime.
function repos-dir-mtimes() {
  local d out="" first=1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$first" = 1 ]; then first=0; else out="${out},"; fi
    out="${out}$(jq -n --arg d "$d" --argjson m "$(repos-mtime "$d")" '{($d): $m}' | jq -c .)"
  done <<<"$1"
  printf '[%s]\n' "$out" | jq -c 'add // {}'
}

# repos-cache-write <live-json> <scan-dirs-json> — write the cache.
function repos-cache-write() {
  jq -n --argjson repos "$1" --argjson dirs "$2" \
    --argjson at "$(date +%s)" --argjson rm "$(repos-mtime "$(repos-registry-file)")" \
    '{liveAt:$at, registryMtime:$rm, scanDirs:$dirs, repos:$repos}' \
    | repos-write-atomic "$(repos-cache-file)"
}

# repos-dirs-changed <scan-dirs-json> — 0 when any recorded dir mtime moved.
function repos-dirs-changed() {
  local d m
  while IFS="$(printf '\t')" read -r d m; do
    [ -n "$d" ] || continue
    [ "$(repos-mtime "$d")" = "$m" ] || return 0
  done <<<"$(printf '%s' "$1" | jq -r 'to_entries[] | .key + "\t" + (.value | tostring)')"
  return 1
}

# --- scan ------------------------------------------------------------------

function repos-scan() {
  local path="" depth="" all=0 roots_arg="${CCXP_REPO_ROOTS:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --depth) [ $# -ge 2 ] || { repos-die "scan: --depth needs a value"; return 2; }; depth="$2"; shift 2 ;;
      --depth=*) depth="${1#--depth=}"; shift ;;
      --all) all=1; shift ;;
      --roots) [ $# -ge 2 ] || { repos-die "scan: --roots needs a value"; return 2; }; roots_arg="$2"; shift 2 ;;
      --roots=*) roots_arg="${1#--roots=}"; shift ;;
      -*) repos-die "scan: unknown flag $1"; return 2 ;;
      *) if [ -n "$path" ]; then repos-die "scan: one path only"; return 2; fi; path="$1"; shift ;;
    esac
  done
  if [ -n "$depth" ]; then
    case "$depth" in ''|*[!0-9]*|0) repos-die "scan: --depth wants a positive integer"; return 2 ;; esac
  fi

  local reg
  reg="$(repos-registry-read)" || return 6

  # Root list: lines "<abs path>\t<depth>"; remember=1 when the registry keeps them.
  local roots="" remember=1 r d
  if [ -n "$roots_arg" ]; then
    remember=0
    local old_ifs="$IFS"; IFS=':'
    for r in $roots_arg; do
      IFS="$old_ifs"
      [ -n "$r" ] || continue
      d="$(repos-abs "$(repos-expand "$r")")" || { repos-die "scan: not a folder: $r"; return 2; }
      roots="${roots}${d}	${depth:-$REPOS_DEFAULT_DEPTH}
"
    done
    IFS="$old_ifs"
  elif [ -n "$path" ]; then
    d="$(repos-abs "$(repos-expand "$path")")" || { repos-die "scan: not a folder: $path"; return 2; }
    roots="${d}	${depth:-$REPOS_DEFAULT_DEPTH}
"
  else
    local rp rd top main
    while IFS="$(printf '\t')" read -r rp rd; do
      [ -n "$rp" ] || continue
      rp="$(repos-abs "$(repos-expand "$rp")" || true)"
      [ -n "$rp" ] || continue
      roots="${roots}${rp}	${depth:-$rd}
"
    done <<<"$(printf '%s' "$reg" | jq -r '.roots // [] | .[] | .path + "\t" + (.depth // 2 | tostring)')"
    # Remembered roots come first so a stored depth beats the sibling default.
    top="$(repos-toplevel)"
    if [ -n "$top" ]; then
      main="$(repos-main-of "$top" || true)"
      if [ -n "$main" ]; then roots="${roots}$(dirname "$main")	${depth:-1}
"; fi
    fi
  fi
  roots="$(printf '%s' "$roots" | awk -F'\t' 'NF && !seen[$1]++')"
  if [ -z "$roots" ]; then
    repos-die "scan: nothing to scan; run it inside a git repo or give a path"
    return 2
  fi

  local excl
  excl="$(printf '%s' "$reg" | jq -r '.exclude // [] | .[]')"

  local rpath rdepth found=""
  REPOS_WALK_DIRS=""; REPOS_WALK_SKIPPED=""
  while IFS="$(printf '\t')" read -r rpath rdepth; do
    [ -n "$rpath" ] || continue
    repos-collect "$rpath" "$rdepth" "$all" "$excl"
    found="${found}${REPOS_COLLECTED}
"
  done <<<"$roots"
  found="$(printf '%s' "$found" | grep . | LC_ALL=C sort -u || true)"

  # Old records outside every scanned root survive while their folder exists.
  local p keep old keepers=""
  old="$(printf '%s' "$reg" | jq -r '.repos // [] | .[].path' | LC_ALL=C sort -u)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    keep=1
    while IFS="$(printf '\t')" read -r rpath rdepth; do
      case "$p" in "$rpath"/*|"$rpath") keep=0 ;; esac
    done <<<"$roots"
    if [ "$keep" = 1 ] && [ -d "$p" ]; then keepers="${keepers}${p}
"; fi
  done <<<"$old"
  local new
  new="$(printf '%s\n%s\n' "$found" "$keepers" | grep . | LC_ALL=C sort -u || true)"

  # New record list as JSON with fresh name/slug per path.
  local newjson="" first=1 np
  while IFS= read -r np; do
    [ -n "$np" ] || continue
    if [ "$first" = 1 ]; then first=0; else newjson="${newjson},"; fi
    newjson="${newjson}$(jq -n -c --arg p "$np" --arg n "$(basename "$np")" --arg s "$(repos-slug "$np")" \
      '{path:$p, name:$n, slug:$s}')"
  done <<<"$new"
  newjson="[${newjson}]"

  local rootsjson newreg
  rootsjson="$(printf '%s' "$roots" | jq -R -s -c 'split("\n")|map(select(length>0)|split("\t"))|map({path:.[0], depth:(.[1]|tonumber)})')"
  newreg="$(jq -n -c --argjson old "$reg" --argjson new "$newjson" --argjson roots "$rootsjson" --argjson remember "$remember" '
    ($old.repos // [] | map({key:.path, value:(.aliases // [])}) | from_entries) as $al
    | $old
    | .exclude = (.exclude // [])
    | .roots = (if $remember == 1
        then ((.roots // []) | map(select(.path as $q | ($roots | map(.path) | index($q)) | not))) + $roots
        else (.roots // []) end)
    | .repos = ($new | map(. + {aliases: ($al[.path] // [])}) | sort_by([.name, .path]))')"

  if [ "$all" = 0 ]; then
    printf '%s\n' "$newreg" | jq . | repos-write-atomic "$(repos-registry-file)"
    repos-cache-write "$(repos-live-json "$newreg")" "$(repos-dir-mtimes "$REPOS_WALK_DIRS")" \
      || printf 'repos: warning: could not write the cache (%s)\n' "$(repos-cache-file)" >&2
  fi

  # Report: one row per repo (+ added, - removed, = unchanged), worktrees under it.
  local na=0 nr=0 nu=0 mark w
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if grep -qxF -- "$p" <<<"$old"; then
      if grep -qxF -- "$p" <<<"$new"; then mark="="; nu=$((nu + 1)); else mark="-"; nr=$((nr + 1)); fi
    else mark="+"; na=$((na + 1)); fi
    printf '%s %s\t%s\n' "$mark" "$(basename "$p")" "$(repos-short "$p")"
    if [ "$mark" != "-" ]; then
      while IFS= read -r w; do
        [ -n "$w" ] || continue
        printf '    %s (wt %s)\t%s\n' "$(basename "$p")" "$(basename "$w")" "$(repos-short "$w")"
      done <<<"$(repos-wt-list "$p")"
    fi
  done <<<"$(printf '%s\n%s\n' "$old" "$new" | grep . | LC_ALL=C sort -u || true)"
  printf '%s added, %s removed, %s unchanged (%s root(s) scanned)\n' "$na" "$nr" "$nu" "$(printf '%s\n' "$roots" | grep -c .)"
  local nsk
  nsk="$(printf '%s' "$REPOS_WALK_SKIPPED" | grep -c . || true)"
  if [ "$nsk" -gt 0 ]; then printf '%s symlink(s) skipped\n' "$nsk"; fi
  if [ "$all" = 1 ]; then printf -- '--all is display-only: registry and cache not written\n'; fi
  return 0
}

# --- list ------------------------------------------------------------------

function repos-list() {
  local json=0 fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --fresh) fresh=1; shift ;;
      *) repos-die "list: unknown argument $1"; return 2 ;;
    esac
  done
  local reg
  reg="$(repos-registry-read)" || return 6
  local total existing
  total="$(printf '%s' "$reg" | jq '.repos // [] | length')"
  existing=0
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && existing=$((existing + 1))
  done <<<"$(printf '%s' "$reg" | jq -r '.repos // [] | .[].path')"
  local stale=$((total - existing))

  local cf live dirs changed=0 reuse=0
  cf="$(repos-cache-file)"
  dirs='{}'
  if [ -f "$cf" ] && jq -e 'type == "object"' "$cf" >/dev/null 2>&1; then
    dirs="$(jq -c '.scanDirs // {}' "$cf")"
    if repos-dirs-changed "$dirs"; then changed=1; fi
    local at rm now cnt
    at="$(jq -r '.liveAt // 0' "$cf")"; rm="$(jq -r '.registryMtime // 0' "$cf")"
    now="$(date +%s)"; cnt="$(jq '.repos | length' "$cf")"
    if [ "$fresh" = 0 ] && [ "$changed" = 0 ] && [ "$cnt" = "$existing" ] \
       && [ "$rm" = "$(repos-mtime "$(repos-registry-file)")" ] \
       && [ $((now - at)) -lt "$REPOS_CACHE_TTL" ]; then
      reuse=1
    fi
  fi
  if [ "$reuse" = 1 ]; then
    live="$(jq -c '.repos' "$cf")"
  else
    live="$(repos-live-json "$reg")"
    repos-cache-write "$live" "$dirs" 2>/dev/null || true
  fi

  local cur
  cur="$(repos-toplevel)"
  if [ "$json" = 1 ]; then
    printf '%s' "$live" | jq --arg cur "$cur" '
      map(. + {current: (.path == $cur or (.worktrees | any(.path == $cur)))})'
    return 0
  fi

  if [ "$total" = 0 ]; then
    printf 'No repos registered yet. Run /repo scan.\n'
    return 0
  fi
  {
    printf ' \tREPO\tBRANCH\tDIRTY\tTASKS\tTOP\n'
    printf '%s' "$live" | jq -r --arg cur "$cur" '
      def row: map(tostring | gsub("\t"; " ")) | join("\t");
      .[] as $r
      | ([(if $r.path == $cur then "*" else " " end), $r.name, $r.branch, (if $r.dirty then "dirty" else "clean" end),
          $r.open_tasks, $r.top_task] | row),
        ($r.worktrees[] | [(if .path == $cur then "*" else " " end), ("  " + $r.name + " (wt " + .name + ")"), .branch,
          (if .dirty then "dirty" else "clean" end), .open_tasks, .top_task] | row)'
  } | awk -F'\t' '
    { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; nf = NF > nf ? NF : nf }
    END { for (r = 1; r <= n; r++) { line = ""; for (i = 1; i <= nf; i++) { v = c[r, i]; if (i < nf) { while (length(v) < w[i]) v = v " "; line = line v "  " } else line = line v } print line } }' \
    | sed -E 's/[[:space:]]+$//'
  if [ "$stale" -gt 0 ]; then
    printf '%s stale path(s) skipped (folder gone); run /repo scan to refresh the registry.\n' "$stale"
  fi
  if [ "$changed" = 1 ]; then
    printf 'Scanned folders changed since the last scan; run /repo scan to pick up new repos.\n'
  fi
  if [ -n "$cur" ]; then
    if ! printf '%s' "$live" | jq -e --arg cur "$cur" 'any(.[]; .path == $cur or (.worktrees | any(.path == $cur)))' >/dev/null; then
      printf 'Current repo: %s (not in the registry; run /repo scan)\n' "$(repos-short "$cur")"
    fi
  fi
  return 0
}

# --- paths -----------------------------------------------------------------

# repos-paths — registered repo roots that exist plus a live depth-1 sibling
# scan of the current repo; unique, no writes. Used by _taskid/in-this-repo.sh.
function repos-paths() {
  local reg p top main out="" excl
  reg="$(repos-registry-read 2>/dev/null || printf '{}')"
  excl="$(printf '%s' "$reg" | jq -r '.exclude // [] | .[]' 2>/dev/null || true)"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && out="${out}${p}
"
  done <<<"$(printf '%s' "$reg" | jq -r '.repos // [] | .[].path' 2>/dev/null || true)"
  top="$(repos-toplevel)"
  if [ -n "$top" ]; then
    main="$(repos-main-of "$top" || true)"
    if [ -n "$main" ]; then
      REPOS_WALK_DIRS=""; REPOS_WALK_SKIPPED=""
      repos-collect "$(dirname "$main")" 1 0 "$excl"
      out="${out}${REPOS_COLLECTED}
"
    fi
  fi
  printf '%s' "$out" | grep . | LC_ALL=C sort -u || true
}

function repos-usage() {
  cat <<'EOF'
Usage:
  repos.sh scan [path] [--depth N] [--all] [--roots a:b]
  repos.sh list [--json] [--fresh]
  repos.sh paths
EOF
}

function repos-main() {
  command -v jq >/dev/null 2>&1 || { repos-die "jq is required"; return 2; }
  local verb="${1:-}"
  [ $# -gt 0 ] && shift
  case "$verb" in
    scan) repos-scan "$@" ;;
    list) repos-list "$@" ;;
    paths) repos-paths "$@" ;;
    ""|-h|--help|help) repos-usage ;;
    *) repos-usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  repos-main "$@"
fi
