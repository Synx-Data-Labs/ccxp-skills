#!/usr/bin/env bash
# nightly-rca.sh <subcommand>   (T20261105-423915)
#
# Read-only helpers for /nightly-rca. Nothing here writes outside the briefing directory it is given,
# posts, re-runs a workflow or opens an issue. `gh` is overridable with GH_BIN (tests).
#
#   classify <run.json>             run.json = `gh run view <id> --json name,conclusion,createdAt,startedAt,updatedAt,jobs`
#       prints key=value lines: verdict=queued|running|failed|hung|green|other, queue_min, run_min, job, step.
#       queued: the run waited 60+ minutes before it started and has not concluded (2026-11-04: ~8 h queue, not a hang).
#       hung: not concluded, last update 6+ hours ago. running: not concluded, short queue, recent update. other: any other conclusion (skipped, startup_failure, ...). failed: concluded failure/timed_out/cancelled.
#   last-green <owner/repo> <workflow> <before-run-id>
#       prints "<run id><TAB><head sha>" of the newest successful run of that workflow older than the given id.
#   pin-diff <old.yml> <new.yml>    prints "name<TAB>old<TAB>new" for each component whose prepared_commit changed
#       (added or removed components show "-" on the missing side).
#   sha-reachable <owner/repo> <branch> <sha>
#       prints reachable|unreachable|missing: GitHub compare API; missing = 404 (SHA not in the mirror at all),
#       unreachable = present but not an ancestor of the branch; exit 3 when the branch itself does not exist.
#   briefing <run-id> <out-dir>     writes <out-dir>/nightly-rca-<run-id>.md (mode 600) with the fixed section
#       skeleton and prints its path. Refuses to overwrite.
#
# Exit: 2 usage, 3 input unreadable, 4 gh failure.
set -euo pipefail

function nr-die() { echo "nightly-rca: $1" >&2; }
function nr-gh() { "${GH_BIN:-gh}" "$@"; }

# epoch of an ISO-8601 UTC stamp (GNU date, then BSD date)
function nr-epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

function nr-classify() {
  local f=${1:-}
  [ -n "$f" ] || { nr-die "classify: run.json required"; return 2; }
  [ -r "$f" ] || { nr-die "classify: cannot read $f"; return 3; }
  local conc created started updated job step now q r
  conc="$(jq -r '.conclusion // ""' "$f")" || return 3
  created="$(jq -r '.createdAt // empty' "$f")"
  started="$(jq -r '.startedAt // .createdAt // empty' "$f")"
  updated="$(jq -r '.updatedAt // empty' "$f")"
  [ -n "$created" ] && [ -n "$updated" ] || { nr-die "classify: createdAt/updatedAt missing"; return 3; }
  q=$(( ($(nr-epoch "$started") - $(nr-epoch "$created")) / 60 ))
  r=$(( ($(nr-epoch "$updated") - $(nr-epoch "$started")) / 60 ))
  job="$(jq -r '[.jobs[]? | select(.conclusion=="failure" or .conclusion=="timed_out")][0].name // "-"' "$f")"
  step="$(jq -r '[.jobs[]? | select(.conclusion=="failure" or .conclusion=="timed_out") | .steps[]? | select(.conclusion=="failure")][0].name // "-"' "$f")"
  now="${NR_NOW:-$(date -u +%s)}"
  local verdict stale=$(( (now - $(nr-epoch "$updated")) / 60 ))
  case "$conc" in
    success) verdict=green ;;
    failure|timed_out|cancelled) verdict=failed ;;
    "")
      if [ "$stale" -ge 360 ]; then verdict=hung
      elif [ "$q" -ge 60 ]; then verdict=queued
      else verdict=running; fi ;;
    *) verdict=other ;;   # skipped, neutral, startup_failure, action_required, ...
  esac
  printf 'verdict=%s\nqueue_min=%s\nrun_min=%s\njob=%s\nstep=%s\n' "$verdict" "$q" "$r" "$job" "$step"
}

function nr-last-green() {
  [ "$#" -eq 3 ] || { nr-die "last-green <owner/repo> <workflow> <before-run-id>"; return 2; }
  local repo=$1 wf=$2 before=$3 out
  [[ "$before" =~ ^[0-9]+$ ]] || { nr-die "last-green: run id must be numeric"; return 2; }
  out="$(nr-gh run list --repo "$repo" --workflow "$wf" --status success --limit 100 --json databaseId,headSha)" \
    || { nr-die "last-green: gh run list failed"; return 4; }
  jq -r --argjson b "$before" '[.[] | select(.databaseId < $b)] | sort_by(-.databaseId)[0] // empty | "\(.databaseId)\t\(.headSha)"' <<<"$out"
}

# name<TAB>prepared_commit per component of a manifest
function nr-pins() {
  awk '
    /^components:/ { inc=1; next }
    inc && /^[^ -]/ { inc=0 }
    inc && /^  - name:/ { name=$3; gsub(/["'\'']/, "", name); next }
    inc && /^    prepared_commit:/ { v=$2; gsub(/["'\'']/, "", v); if (name != "") print name "\t" v }
  ' "$1"
}

function nr-pin-diff() {
  [ "$#" -eq 2 ] || { nr-die "pin-diff <old.yml> <new.yml>"; return 2; }
  [ -r "$1" ] && [ -r "$2" ] || { nr-die "pin-diff: cannot read manifest"; return 3; }
  local a b
  a="$(nr-pins "$1")"; b="$(nr-pins "$2")"
  { [ -z "$a" ] || printf '%s\n' "$a" | awk '{ print "o\t" $0 }'; [ -z "$b" ] || printf '%s\n' "$b" | awk '{ print "n\t" $0 }'; } | awk -F'\t' '
    $1=="o" { old[$2]=$3; seen[$2]=1; next }
    $1=="n" { new[$2]=$3; seen[$2]=1 }
    END { for (n in seen) { o=(n in old)?old[n]:"-"; w=(n in new)?new[n]:"-"; if (o!=w) print n "\t" o "\t" w } }
  ' | LC_ALL=C sort
}

function nr-sha-reachable() {
  [ "$#" -eq 3 ] || { nr-die "sha-reachable <owner/repo> <branch> <sha>"; return 2; }
  local repo=$1 branch=$2 sha=$3 out
  [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || { nr-die "sha-reachable: bad sha"; return 2; }
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$branch" != *..* ]] || { nr-die "sha-reachable: bad branch"; return 2; }
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { nr-die "sha-reachable: bad repo"; return 2; }
  # a typo in the branch also 404s the compare call, so prove the branch exists first
  if ! out="$(nr-gh api "repos/$repo/branches/$branch" --jq .name 2>&1)"; then
    if grep -q -E '404|Not Found' <<<"$out"; then nr-die "sha-reachable: branch $branch not found in $repo"; return 3; fi
    nr-die "sha-reachable: gh api failed"; return 4
  fi
  if out="$(nr-gh api "repos/$repo/compare/$branch...$sha" --jq .status 2>&1)"; then
    case "$out" in
      identical|behind) printf 'reachable\n' ;;
      ahead|diverged) printf 'unreachable\n' ;;
      *) nr-die "sha-reachable: unexpected status '$out'"; return 4 ;;
    esac
  elif grep -q -E '404|422|Not Found|No commit found|No common ancestor' <<<"$out"; then
    printf 'missing\n'
  else
    nr-die "sha-reachable: gh api failed"; return 4
  fi
}

function nr-briefing() {
  [ "$#" -eq 2 ] || { nr-die "briefing <run-id> <out-dir>"; return 2; }
  local id=$1 dir=$2 f
  [[ "$id" =~ ^[0-9]+$ ]] || { nr-die "briefing: run id must be numeric"; return 2; }
  mkdir -p "$dir" 2>/dev/null && [ -d "$dir" ] || { nr-die "briefing: cannot create $dir"; return 3; }
  f="$dir/nightly-rca-$id.md"
  [ ! -e "$f" ] || { nr-die "briefing: $f exists, not overwriting"; return 2; }
  ( umask 077; set -o noclobber; cat > "$f" <<EOT
# Nightly RCA: run $id

## Verdict

- Cause: <one line>. Confidence: <high|medium|low> because <evidence>.
- Corrections to earlier claims: <none | what was wrong, e.g. queued, not hung>.

## Timeline

| When (UTC) | Event | Evidence |
|---|---|---|
| <time> | <event> | <run/log/commit link> |

## Flow

\`\`\`
<ASCII diagram: which input moved, which stage consumed it, where it broke>
\`\`\`

## Options

- A: <option, cost, risk>
- B: <option, cost, risk>

## Who to ask

- <role, not a name>: <question>
- Draft upstream issue (drafts only, never posted): <dev_collaboration title and body, or none>
EOT
  )
  printf '%s\n' "$f"
}

function nightly-rca() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    classify) nr-classify "$@" ;;
    last-green) nr-last-green "$@" ;;
    pin-diff) nr-pin-diff "$@" ;;
    sha-reachable) nr-sha-reachable "$@" ;;
    briefing) nr-briefing "$@" ;;
    *) nr-die "usage: nightly-rca.sh classify|last-green|pin-diff|sha-reachable|briefing ..."; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  nightly-rca "$@"
fi
