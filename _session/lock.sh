#!/usr/bin/env bash
# _session/lock.sh — exclusive lock files for bash scripts (T20261120-258991). Sourceable, no side effects.
#
# lock_try <lock>            create the lock atomically; 0 = we hold it. Bash's own noclobber redirection
#                            opens it O_CREAT|O_EXCL. Never use `mkdir` as the test-and-set: uutils mkdir
#                            (the ubuntu-latest runner's coreutils) lets several concurrent callers win.
# lock_age <path>            seconds since <path> was modified; 0 when it is gone
# lock_break_stale <lock> <max-age>
#                            remove the lock when older than <max-age> seconds, without ever removing a
#                            live one: breakers serialize on <lock>.brk and re-check the age while holding it
# lock_acquire <lock> <max-age> <tries> <pause>
#                            lock_try, breaking a stale lock, retrying <tries> times <pause> seconds apart
# lock_release <lock>        remove the lock if it is still ours (it holds our pid)
# A legacy directory lock (older versions used mkdir) is treated like any lock: held, and removed once stale.

lock_try() { ( set -o noclobber; printf '%s' "$$" > "$1" ) 2>/dev/null; }

lock_age() {
  local m; m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || m=""
  [ -n "$m" ] || { echo 0; return 0; }
  echo $(( $(date +%s) - m ))
}

lock_remove() { rm -f "$1/pid" "$1" 2>/dev/null; rmdir "$1" 2>/dev/null || true; }

lock_break_stale() {
  local lock="$1" max="$2" brk="$1.brk"
  if ! lock_try "$brk"; then
    [ "$(lock_age "$brk")" -gt "$max" ] && lock_remove "$brk"   # a crashed breaker's marker
    return 0
  fi
  [ "$(lock_age "$lock")" -gt "$max" ] && lock_remove "$lock"
  lock_remove "$brk"
  return 0
}

lock_acquire() {
  local lock="$1" max="$2" tries="$3" pause="$4" i=0
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  until lock_try "$lock"; do
    [ "$(lock_age "$lock")" -gt "$max" ] && lock_break_stale "$lock" "$max"
    i=$(( i + 1 )); [ "$i" -le "$tries" ] || return 1
    sleep "$pause"
  done
}

lock_release() { [ "$(cat "$1" 2>/dev/null)" = "$$" ] && lock_remove "$1"; return 0; }
