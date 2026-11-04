#!/usr/bin/env bash
# Queue high watermark for the ccxp-hud mod: the largest queue length (task lines of
# dev/TODO/queue.md) seen over three rolling windows: last 180 days, last 30 days, last 7 days.
#
# Two series feed it, both keyed by repo root + queue path (the HUD is used in many repos):
#   1. history  - a backfill derived from `git log -p` of the queue file on the default branch
#                 (one detached pass, cached, re-run at most once per HUD_HWM_TTL and only when the
#                 branch moved; incremental when the old tip is an ancestor of the new one).
#                 Gives all three windows from the first run (the pass reads the whole file history, so
#                 180 days are covered from day one), no fetch (reads local objects only).
#   2. samples  - an append-only local log of (epoch, length), written by the HUD poll whenever
#                 the length it shows changes; catches peaks that never reached a commit.
#                 Rotation keeps the 180-day window intact: past HUD_HWM_SAMPLE_CAP lines it first drops
#                 samples older than 180 days (keeping the newest of those, the value in force at the
#                 window start), and only if that is not enough the oldest half.
# A window's value at its start counts too (a queue that was 40 for the whole week and changed
# 8 days ago still has a 7d maximum of 40). There is no lifetime maximum any more; old `max-<key>`
# files from earlier versions are ignored.
#
# State dir (shared with the queue-source stamps): $HUD_QUEUE_STATE_DIR, else
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/hud-queue. Test hooks: HUD_HWM_SYNC=1 (backfill in the
# foreground), HUD_HWM_TTL, HUD_HWM_SAMPLE_CAP, HUD_HWM_NOW (fake epoch).
#
# Everything is read-only for the repo, silent on failure, and never blocks the render:
# the backfill is detached and only ever writes under the state dir.

_HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hud-lib.sh
. "$_HW_DIR/hud-lib.sh"

HUD_HWM_TTL="${HUD_HWM_TTL:-3600}"
HUD_HWM_SAMPLE_CAP="${HUD_HWM_SAMPLE_CAP:-20000}"
HUD_HWM_WINDOW_DAYS=180
HUD_HWM_TIMEOUT=60
HUD_HWM_QUEUE_PATH="dev/TODO/queue.md"

_hw-now() { printf '%s' "${HUD_HWM_NOW:-$(date +%s)}"; }

_hw-dir() { printf '%s' "${HUD_QUEUE_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/hud-queue}"; }

# $1 repo root -> a short key for repo root + queue path
sl-hwm-key() { printf '%s\0%s' "$1" "$HUD_HWM_QUEUE_PATH" | cksum | cut -d' ' -f1; }

# $1 repo root -> the ref whose history is read: origin/<default>, else a local main/master, else HEAD.
_hw-ref() {
  local root="$1" b cand
  b=$(sl-default-branch "$root")
  if [ -n "$b" ]; then printf 'refs/remotes/origin/%s' "$b"; return 0; fi
  for cand in main master; do
    if git -C "$root" rev-parse --verify -q "refs/heads/$cand^{commit}" >/dev/null 2>&1; then printf 'refs/heads/%s' "$cand"; return 0; fi
  done
  printf 'HEAD'
}

# $1 repo root -> (re)build the history series from git, in the foreground. Incremental when the
# stored tip is an ancestor of the new one. Writes hist-<key> and hist-<key>.meta ("ref sha count"). Never fails.
_sl-hwm-backfill-run() {
  local root="$1" dir key ref sha meta hist oref osha ocnt start="" count=0 mode=full tmp
  dir=$(_hw-dir); key=$(sl-hwm-key "$root"); hist="$dir/hist-$key"; meta="$hist.meta"
  ref=$(_hw-ref "$root")
  sha=$(git -C "$root" rev-parse --verify -q "$ref^{commit}" 2>/dev/null) || return 0
  if [ -f "$meta" ] && read -r oref osha ocnt < "$meta" 2>/dev/null && [ "$oref" = "$ref" ] && [[ "$ocnt" =~ ^[0-9]+$ ]]; then
    if [ "$osha" = "$sha" ]; then return 0; fi
    if git -C "$root" merge-base --is-ancestor "$osha" "$sha" 2>/dev/null; then start="$osha"; count="$ocnt"; mode=incr; fi
  fi
  local range="$sha"; [ -z "$start" ] || range="$start..$sha"
  # First-parent history with diffs against the first parent (merge commits included), oldest first;
  # -U0: only the +/- task lines matter. The awk keeps a running count and prints "epoch<TAB>count" per commit.
  local dm=() gmaj gmin
  read -r gmaj gmin < <(git --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/') || true
  if [[ "${gmaj:-}" =~ ^[0-9]+$ ]] && { [ "$gmaj" -gt 2 ] || { [ "$gmaj" -eq 2 ] && [ "${gmin:-0}" -ge 31 ]; }; }; then dm=(--diff-merges=first-parent); fi
  tmp=$(mktemp "$dir/hist-tmp.XXXXXX" 2>/dev/null) || return 0
  GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    sl-run-timeout "$HUD_HWM_TIMEOUT" git -C "$root" log --first-parent --reverse -p -U0 --no-color --no-ext-diff --no-renames "${dm[@]}" --format='@%ct' "$range" -- "$HUD_HWM_QUEUE_PATH" 2>/dev/null \
    | awk -v c="$count" '
        function flush() { if (ts != "") { printf "%s\t%d\n", ts, c } ts = "" }
        /^@[0-9]+$/ { flush(); ts = substr($0, 2); next }
        /^\+- \[T[0-9]+-[0-9]+\]\(/ { c++; next }
        /^-- \[T[0-9]+-[0-9]+\]\(/ { if (c > 0) c--; next }
        END { flush(); print "#END\t" c }' > "$tmp" 2>/dev/null
  # A git that failed or timed out mid-stream leaves a partial series: discard it, keep the old one.
  local rcs=("${PIPESTATUS[@]}")
  if [ "${rcs[0]}" -ne 0 ] || [ "${rcs[1]}" -ne 0 ]; then rm -f "$tmp" 2>/dev/null; return 0; fi
  # The trailer line carries the final count (only a completed pass has it: a timeout leaves no meta behind).
  local last; last=$(tail -n 1 "$tmp" 2>/dev/null)
  if [[ "$last" != "#END"$'\t'* ]]; then rm -f "$tmp" 2>/dev/null; return 0; fi
  local final="${last#*$'\t'}"
  sed -i.bak '$d' "$tmp" 2>/dev/null && rm -f "$tmp.bak" 2>/dev/null
  if [ "$mode" = incr ]; then cat "$tmp" >> "$hist" 2>/dev/null; rm -f "$tmp" 2>/dev/null
  else mv -f "$tmp" "$hist" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }; fi
  printf '%s %s %s\n' "$ref" "$sha" "$final" > "$meta" 2>/dev/null || true
  return 0
}

# $1 repo root -> start the backfill detached unless one ran within HUD_HWM_TTL (stamped BEFORE the
# attempt, so a slow or failing pass is not retried every poll). Never blocks.
sl-hwm-backfill() {
  local root="$1" dir key stamp now last=0
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  dir=$(_hw-dir); mkdir -p "$dir" 2>/dev/null || return 0
  key=$(sl-hwm-key "$root"); stamp="$dir/hist-$key.stamp"; now=$(_hw-now)
  if [ -f "$stamp" ]; then
    last=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null) || last=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ "$last" -le "$now" ] || last=0
  fi
  [ $((now - last)) -ge "$HUD_HWM_TTL" ] || return 0
  : > "$stamp" 2>/dev/null || return 0
  if [ "${HUD_HWM_SYNC:-}" = 1 ]; then
    _sl-hwm-backfill-run "$root"
  else
    ( _sl-hwm-backfill-run "$root" ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
  return 0
}

# $1 repo root $2 current queue length -> append "epoch<TAB>length" to the sample log when the length
# differs from the last sample; rotate past the cap (see the header: the 180-day window survives).
sl-hwm-sample() {
  local root="$1" total="$2" dir key f last lastv="" n cap="$HUD_HWM_SAMPLE_CAP" now cut
  [[ "$total" =~ ^[0-9]+$ ]] || return 0
  dir=$(_hw-dir); mkdir -p "$dir" 2>/dev/null || return 0
  key=$(sl-hwm-key "$root"); f="$dir/samples-$key"; now=$(_hw-now)
  [ -f "$f" ] && last=$(tail -n 1 "$f" 2>/dev/null) && lastv="${last#*$'\t'}"
  if [ "$lastv" != "$total" ]; then
    printf '%s\t%s\n' "$now" "$total" >> "$f" 2>/dev/null || return 0
    if [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -ge 2 ]; then
      n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$cap" ]; then
        cut=$((now - HUD_HWM_WINDOW_DAYS * 86400))
        # 1) age: drop what is older than the window, but keep the newest such line (the value at the window start)
        awk -F'\t' -v cut="$cut" '$1 + 0 >= cut { if (have) { print old; have = 0 } print; next } { old = $0; have = 1 }' "$f" > "$f.tmp.$$" 2>/dev/null \
          && mv -f "$f.tmp.$$" "$f" 2>/dev/null
        rm -f "$f.tmp.$$" 2>/dev/null
        # 2) still over the cap (a burst inside the window): the oldest half goes
        n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$cap" ]; then
          if tail -n $((cap / 2)) "$f" > "$f.tmp.$$" 2>/dev/null; then mv -f "$f.tmp.$$" "$f" 2>/dev/null || true; fi
          rm -f "$f.tmp.$$" 2>/dev/null
        fi
      fi
    fi
  fi
  return 0
}

# $1 repo root $2 current queue length -> `{"d180":N,"d30":N,"d7":N}` (d180 >= d30 >= d7 >= current), or
# nothing when $2 is not a number. Samples the length, kicks the detached backfill, then reads both series.
sl-queue-hwm() {
  local root="$1" total="$2" dir key now
  [[ "$total" =~ ^[0-9]+$ ]] || return 0
  sl-hwm-sample "$root" "$total"
  sl-hwm-backfill "$root"
  dir=$(_hw-dir); key=$(sl-hwm-key "$root"); now=$(_hw-now)
  { cat "$dir/hist-$key" "$dir/samples-$key" 2>/dev/null || true; } | LC_ALL=C sort -s -n -k1,1 | awk -F'\t' -v now="$now" -v cur="$total" '
    BEGIN { c180 = now - 180 * 86400; c30 = now - 30 * 86400; c7 = now - 7 * 86400 }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      t = $1 + 0; v = $2 + 0
      if (t < c180) k180 = v; else if (v > m180) m180 = v
      if (t < c30) k30 = v; else if (v > m30) m30 = v
      if (t < c7) k7 = v; else if (v > m7) m7 = v
    }
    END {
      if (k180 > m180) m180 = k180; if (k30 > m30) m30 = k30; if (k7 > m7) m7 = k7
      if (cur > m7) m7 = cur; if (m7 > m30) m30 = m7; if (m30 > m180) m180 = m30
      printf "{\"d180\":%d,\"d30\":%d,\"d7\":%d}\n", m180, m30, m7 }' 2>/dev/null || true
}
