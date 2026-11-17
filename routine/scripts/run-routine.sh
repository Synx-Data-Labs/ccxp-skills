#!/usr/bin/env bash
# run-routine.sh [--repo DIR] <verb> ...   (T20261114-400715, part 2 of the routines epic T20261114-267875)
#
# Record file and exit-code arithmetic for /routine. The runner (the model, following routine/SKILL.md) calls the
# steps' skills itself; this script keeps the facts: which steps ran, how the run rolled up, which claim action follows.
#
#   plan <routine>                           the steps a run would call (TSV: index, skill, args); touches nothing
#   begin <routine> [--key K]                start a record; K is the key `routine-due.sh claim` printed (absent: manual run)
#   step <routine> <key> <idx> <outcome> [note]   outcome: ok | nothing-to-do | failed | needs-human; prints continue|stop
#   finish <routine> <key> [summary]         roll up (ok | partial | failed | needs-human) and call routine-due.sh done|release
#   attempts <routine> <key>                 attempt count; exit 1 once the retry cap (1 run + 3 retries) is reached
#   last <routine>                           newest record, JSON
#   list                                     name, enabled, schedule, last status and time, per routine
#   enable|disable <routine>                 write the machine-local profile file only
#   allowed <routine> <capability>           exit 0 only when the profile file grants it (`send` is never grantable)
#
# Records: ${CCXP_ROUTINES_RUN_DIR:-<profile dir>/ccxp-routines}/<repo-key>/<routine>-<key>.json
# (<repo-key> as the ritual markers use; `_any` outside a repo). A manual run (no key) touches no claim.
set -euo pipefail

_RR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../agent-pairing/scripts/routine-due.sh
# shellcheck source-path=SCRIPTDIR
. "$_RR_DIR/../../agent-pairing/scripts/routine-due.sh"

function rr-die() { echo "run-routine: $*" >&2; return "${RR_RC:-2}"; }

function rr-profile-file() { echo "${CCXP_ROUTINES_PROFILE_FILE:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-routines.yml}}"; }

# record dir for the repo at $1 ("" = no repo)
function rr-dir() {
  local top=$1 base key
  base="${CCXP_ROUTINES_RUN_DIR:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-routines}}"
  [ -n "$base" ] || { echo "run-routine: no profile dir (set CCXP_ROUTINES_RUN_DIR)" >&2; return 1; }
  if [ -n "$top" ]; then
    key="$(CCXP_RITUAL_DIR="${CCXP_RITUAL_DIR:-/x}" rd-marker-dir "$top")"
    echo "$base/$(basename "$key")"
  else
    echo "$base/_any"
  fi
}

# run the python helper with the routine's merged definition
function rr-py() {
  local top=$1 name=$2 show dir
  shift 2
  [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { rr-die "bad routine name '$name'"; return; }
  show="$(rt-config show "$top" "$name")" || { RR_RC=3 rr-die "unknown routine '$name'"; return; }
  dir="$(rr-dir "$top")" || return
  RR_NAME="$name" RR_SHOW="$show" RR_DIR="$dir" python3 -I "$_RR_DIR/run-routine.py" "$@"
}

function rr-set-enabled() {
  local top=$1 name=$2 val=$3 file
  [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { rr-die "bad routine name '$name'"; return; }
  rt-config show "$top" "$name" >/dev/null 2>&1 || { RR_RC=3 rr-die "unknown routine '$name'"; return; }
  file="$(rr-profile-file)"
  [ -n "$file" ] || { rr-die "no profile file (set CCXP_ROUTINES_PROFILE_FILE or run under a profile)"; return; }
  python3 -I -c 'import yaml' 2>/dev/null || { RR_RC=3 rr-die "enable/disable needs PyYAML (the profile file is rewritten)"; return; }
  mkdir -p "$(dirname "$file")"
  python3 -I - "$file" "$name" "$val" <<'PY'
import os, sys, yaml
path, name, val = sys.argv[1:4]
try:
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
except FileNotFoundError:
    doc = {}
if not isinstance(doc, dict) or not isinstance(doc.get("routines") or {}, dict):
    sys.exit("run-routine: %s is not a routine config; fix it by hand first" % path)
if doc.get("routines") is None:
    doc["routines"] = {}
r = doc["routines"]
if not isinstance(r.get(name), dict):
    r[name] = {}
r[name]["enabled"] = val == "true"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
os.replace(tmp, path)
PY
}

function rr-list() {
  local top=$1 name enabled sch last dir
  dir="$(rr-dir "$top")"
  while IFS=$'\t' read -r name enabled sch; do
    [ -n "$name" ] || continue
    last="-"
    if [ -d "$dir" ]; then last="$(RR_NAME="$name" RR_DIR="$dir" RR_SHOW="" python3 -I "$_RR_DIR/run-routine.py" last 2>/dev/null | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["status"], r.get("finished") or r["started"])' 2>/dev/null || echo "-")"; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$enabled" "$sch" "$last"
  done < <(rt-config all "$top")
  return 0
}

function run-routine() {
  local repo="" verb top="" name key out claim status
  if [ "${1:-}" = --repo ]; then repo="${2:?--repo needs a directory}"; shift 2; fi
  verb="${1:-}"
  [ $# -eq 0 ] || shift
  top="$(rd-repo-root "${repo:-.}")" || top=""
  case "$verb" in
    plan) rr-py "$top" "${1:?plan needs a routine}" plan ;;
    begin)
      name="${1:?begin needs a routine}"; shift
      key=""
      if [ "${1:-}" = --key ]; then key="${2:?--key needs the claim key}"; shift 2; fi
      [ -n "$key" ] || key="manual-$(date +%s)"
      rr-py "$top" "$name" begin "$key" >/dev/null || return
      echo "$key" ;;
    step) rr-py "$top" "${1:?step needs a routine}" step "${@:2}" ;;
    attempts) rr-py "$top" "${1:?attempts needs a routine}" attempts "${2:?attempts needs a key}" ;;
    last) rr-py "$top" "${1:?last needs a routine}" last ;;
    finish)
      name="${1:?finish needs a routine}"; key="${2:?finish needs a key}"
      out="$(rr-py "$top" "$name" finish "$key" "${3:-}")" || return
      echo "$out"
      claim="$(sed -n 's/.*claim=\([a-z]*\).*/\1/p' <<<"$out")"
      case "$claim" in
        done) routine-due --repo "${top:-.}" "done" "$name" "$key" || echo "::warning::run-routine: could not mark $name $key done (routine disabled or unknown?); the record is written" >&2 ;;
        release | capped) routine-due --repo "${top:-.}" release "$name" "$key" || echo "::warning::run-routine: could not release $name $key (routine disabled or unknown?); the record is written" >&2 ;;
      esac
      status="${out#status=}"; status="${status%% *}"
      [ -n "$status" ] ;;
    list) rr-list "$top" ;;
    enable) rr-set-enabled "$top" "${1:?enable needs a routine}" true ;;
    disable) rr-set-enabled "$top" "${1:?disable needs a routine}" false ;;
    allowed)
      name="${1:?allowed needs a routine}"; key="${2:?allowed needs a capability}"
      [ "$key" != send ] || { echo "run-routine: 'send' is never grantable" >&2; return 1; }
      rt-config show "$top" "$name" | python3 -I -c '
import json, sys
cap = sys.argv[1]
for line in sys.stdin:
    k, _, v = line.partition(": ")
    if k == "allow":
        a = json.loads(v)
        sys.exit(0 if isinstance(a, list) and cap in a else 1)
sys.exit(1)' "$key" ;;
    *) echo "usage: run-routine.sh [--repo DIR] plan|begin|step|finish|attempts|last|list|enable|disable|allowed ..." >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run-routine "$@"
fi
