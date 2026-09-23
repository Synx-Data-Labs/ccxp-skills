#!/usr/bin/env bash
# eta.sh [T<id>] [--tz <IANA-zone>] [--repo-root DIR]
#
# Estimate time-to-completion for the current task (or an explicit T<id>):
# resolves the task file, derives a start time from the git commit that set
# claimed_by (git log -S — see _session/task_claim.sh:525-539, which confirms
# no timestamp field exists to read directly), converts the estimation:
# bucket to a literal wall-clock duration, and prints elapsed / remaining /
# projected-finish. Defaults to the local system timezone; --tz overrides.
#
# See eta/SKILL.md for the duration-bucket assumption and the
# start-time-unknown fallback this deliberately degrades to.
set -uo pipefail

USAGE="usage: eta.sh [T<id>] [--tz <IANA-zone>] [--repo-root DIR]"

_ETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _eta_cand in "$_ETA_DIR/../../_session/claimant-id.sh" \
                 "$HOME/.claude/skills/_session/claimant-id.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_eta_cand" ] && { . "$_eta_cand"; break; }
done
unset _eta_cand

eta_repo_root="$(pwd)"
eta_tz=""
eta_task_id=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tz)
      [ $# -ge 2 ] || { echo "eta: --tz requires an argument" >&2; exit 2; }
      eta_tz="$2"; shift 2 ;;
    --repo-root)
      [ $# -ge 2 ] || { echo "eta: --repo-root requires an argument" >&2; exit 2; }
      eta_repo_root="$2"; shift 2 ;;
    -h|--help)
      echo "$USAGE"; exit 0 ;;
    T*)
      eta_task_id="$1"; shift ;;
    *)
      echo "eta: unknown argument '$1'" >&2
      echo "$USAGE" >&2
      exit 2 ;;
  esac
done

eta_todo_dir="$eta_repo_root/dev/TODO"

eta_find_file() {
  # $1 task-id → echo path under eta_todo_dir, or empty (+ nonzero).
  local id="$1" m
  for m in "$eta_todo_dir/$id"*.md; do
    [ -e "$m" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

eta_file=""
if [ -n "$eta_task_id" ]; then
  eta_file="$(eta_find_file "$eta_task_id")" || {
    echo "eta: no task file for $eta_task_id under $eta_todo_dir" >&2
    exit 1
  }
else
  eta_clone_id=""
  if declare -F claimant_id >/dev/null 2>&1; then
    eta_clone_id="$(claimant_id "$eta_repo_root" 2>/dev/null || true)"
  fi
  if [ -z "$eta_clone_id" ]; then
    echo "eta: no current task (could not resolve claimant id — pass T<id> explicitly)" >&2
    exit 1
  fi
  # Same convention as statusline-setup/scripts/statusline-command.sh's
  # sl-claimed-task-label: escape regex-special chars in the id, anchor the
  # tail so a longer sibling claimant-id can't match as a prefix.
  eta_esc_id="${eta_clone_id//\\/\\\\}"
  eta_esc_id="${eta_esc_id//./\\.}"
  eta_file="$(grep -rlE "^claimed_by:[[:space:]]+${eta_esc_id}([[:space:]]|\$)" "$eta_todo_dir" 2>/dev/null | head -1)"
  if [ -z "$eta_file" ]; then
    echo "eta: no current task (nothing claimed by this clone under $eta_todo_dir)" >&2
    exit 1
  fi
  eta_task_id="$(basename "$eta_file" .md | grep -oE 'T[0-9]+-[0-9]+')"
fi

eta_fm_get() {
  # $1 file  $2 field → echo the field's value (trimmed), or empty. First fence only.
  local file="$1" field="$2"
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm && $0 ~ "^"f":" {
      line=$0
      sub("^"f":[ \t]*", "", line)
      print line
      exit
    }
  ' "$file"
}

eta_estimation="$(eta_fm_get "$eta_file" estimation)"
eta_claimed_by="$(eta_fm_get "$eta_file" claimed_by)"

if [ -z "$eta_estimation" ]; then
  echo "eta: $eta_task_id has no estimation: field" >&2
  exit 1
fi

# Bucket → literal wall-clock duration in seconds (documented assumption —
# see eta/SKILL.md: not workday-relative, a future task can revisit that).
eta_bucket_seconds() {
  case "$1" in
    15m) printf '900' ;;
    30m) printf '1800' ;;
    1h)  printf '3600' ;;
    2h)  printf '7200' ;;
    4h)  printf '14400' ;;
    1d)  printf '86400' ;;
    2d)  printf '172800' ;;
    1w)  printf '604800' ;;
    *) return 1 ;;
  esac
}

eta_duration_s="$(eta_bucket_seconds "$eta_estimation")" || {
  echo "eta: unrecognized estimation bucket '$eta_estimation' (expected one of 15m 30m 1h 2h 4h 1d 2d 1w)" >&2
  exit 1
}

# Validate --tz early (before doing any date math) so an invalid zone always
# exits 2 with a clear error rather than silently falling back to UTC — GNU
# `date` accepts an unrecognized TZ string with exit 0 (silently treating it
# as UTC), so `date`'s own exit code cannot be trusted to catch a typo. Check
# the zone against the IANA tzdata the system actually has instead.
if [ -n "$eta_tz" ]; then
  eta_tz_ok=0
  for eta_tz_db in /usr/share/zoneinfo /etc/zoneinfo; do
    [ -e "$eta_tz_db/$eta_tz" ] && { eta_tz_ok=1; break; }
  done
  if [ "$eta_tz_ok" -ne 1 ]; then
    echo "eta: invalid timezone '$eta_tz'" >&2
    exit 2
  fi
fi

# Start-time derivation: the git commit that introduced this exact
# "claimed_by: <value>" line, oldest match. Every claim path (task_claim.sh
# acquire, /drive Phase 1, /claim) lands this line in its own claim-PR commit,
# so its author date is a reliable proxy for "when work started" — see
# T20260922-453135's Problem section for the CCXP_PEER_MODE=0 bypass this
# doesn't cover, which is exactly the fallback below.
eta_start_iso=""
if [ -n "$eta_claimed_by" ] && git -C "$eta_repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  eta_start_iso="$(git -C "$eta_repo_root" log -S"claimed_by: $eta_claimed_by" --format=%aI -- "$eta_file" 2>/dev/null | tail -1)"
fi

eta_fmt_duration() {
  # $1 seconds (may be negative) → "<H>h<M>m", sign preserved.
  local s="$1" neg=""
  if [ "$s" -lt 0 ]; then neg="-"; s=$(( -s )); fi
  printf '%s%dh%dm' "$neg" $(( s/3600 )) $(( (s%3600)/60 ))
}

if [ -z "$eta_start_iso" ]; then
  echo "$eta_task_id: start time unknown — showing remaining estimation only"
  echo "  estimation: $eta_estimation ($(eta_fmt_duration "$eta_duration_s"))"
  exit 0
fi

eta_start_epoch="$(date -d "$eta_start_iso" +%s 2>/dev/null || true)"
if [ -z "$eta_start_epoch" ]; then
  echo "eta: could not parse start time '$eta_start_iso' from git history" >&2
  exit 1
fi

eta_now_epoch="$(date +%s)"
eta_elapsed_s=$(( eta_now_epoch - eta_start_epoch ))
eta_remaining_s=$(( eta_duration_s - eta_elapsed_s ))
eta_finish_epoch=$(( eta_start_epoch + eta_duration_s ))

eta_render_time() {
  # $1 epoch  $2 zone (empty = local system timezone)
  local epoch="$1" zone="$2"
  if [ -n "$zone" ]; then
    TZ="$zone" date -d "@$epoch" '+%Y-%m-%d %H:%M %Z'
  else
    date -d "@$epoch" '+%Y-%m-%d %H:%M %Z'
  fi
}

echo "$eta_task_id"
echo "  estimation: $eta_estimation"
echo "  elapsed:    $(eta_fmt_duration "$eta_elapsed_s")"
if [ "$eta_remaining_s" -lt 0 ]; then
  echo "  overdue by: $(eta_fmt_duration "$eta_remaining_s" | sed 's/^-//')"
else
  echo "  remaining:  $(eta_fmt_duration "$eta_remaining_s")"
fi
echo "  projected finish: $(eta_render_time "$eta_finish_epoch" "$eta_tz")"
