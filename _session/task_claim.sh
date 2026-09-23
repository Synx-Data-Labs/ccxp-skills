#!/usr/bin/env bash
# task_claim.sh <verb> <task-id> [args] — durable, main-resident task claim.
#
# Unlike _session/claim.sh (the soft Project-board *visualization* layer), this
# claim lives in the task FILE's frontmatter on `main`. Because every session
# merges to the same `origin/main`, a merge is an atomic cross-machine
# compare-and-swap: two sessions claiming the same task edit the SAME
# `claimed_by:` line, so the second merge conflicts. **The conflict IS the lock.**
# See build-pipeline-repo T20260611-104067 for the full design.
#
# The claim is two fields in the task file's leading `---` frontmatter block:
#   claimed_by:      <machine>:<working-dir>  (empty when unclaimed; the lock —
#                                              already carries the working-dir)
#   status:          Coding                   (board projection; secondary)
#
# The claimant id is the (machine, clone-path) pair, NOT a per-invocation session
# id — so a new /drive or ccxp run in the SAME clone is the SAME claimant and
# supersedes its own prior claim instead of stacking a new one. That clone-stable
# identity is what makes release-on-pickup (the `release-others` verb, formerly
# `release-mine` — still accepted as an alias) reliable.
# See build-pipeline-repo T20260615-169917 (retires the old <sid>@<machine>).
#
# `sync-tasks-to-issues` projects claimed_by from `main` onto the Project V2
# field of the SAME name (1:1). The soft-claim direct writes
# (_session/claim.sh, heartbeat.sh) and the old machine/cc_session_id/clone_path/
# last_heartbeat Project fields are retired; there is no heartbeat in this design
# (liveness comes from git progress).
#
# NOTE: `claimed_by:` is the *session execution lock* and is distinct from the
# informal human-assignee field `owner:` (e.g. "owner: Alex"). This lib never
# touches `owner:`.
#
# CORRECTNESS INVARIANT: the `claimed_by:` line is the canonical single-line
# claim location. For the conflict-guarantee to hold, two concurrent claims MUST
# produce a git merge conflict — which they do iff both edit the same existing
# `claimed_by:` line to different values. Task files should therefore carry a
# `claimed_by:` line (empty) even when unclaimed; see the seed migration slice.
#
# PR OWNERSHIP IS DERIVED, NOT SEPARATELY TRACKED (T20260622-404636). A PR is
# owned by whoever owns the TASK it implements — i.e. that task's `claimed_by`
# on `main`, the single source of truth above. There is no per-PR marker; the
# `pr-owner` verb resolves PR → task → claimed_by so callers (`/address-pr`
# §1.6) defer to another agent's live work or proceed on their own / a free
# task. This replaced the old `pr_owner.sh` cc-owned-label/marker mechanism,
# whose stranded markers under dead sessions were the recurring pain — a problem
# that simply does not exist when ownership lives on the task, freed by
# release-on-pickup (same agent) and the reclaim sweep (foreign dead agent).
#
# Verbs:
#   acquire <task-id>            → claim if free. Prints one of:
#                                    "acquired"        (was free, now mine)
#                                    "mine"            (already mine; idempotent)
#                                    "claimed:<by>"    (held by another; exit 3)
#   read    <task-id>            → prints "<status>\t<claimed_by>" (empty if none)
#   release <task-id> [status]   → clear claimed_by, set status (default Open). Prints "released"
#   release-others [except-id]   → release-on-pickup: clear EVERY task held by this
#                                    identity EXCEPT the optional <except-id> (the
#                                    task about to be acquired), so a session holds
#                                    ≤1 active claim. Prints "released:<id>" per freed
#                                    task. NOTE the inverted argument vs `release`
#                                    above: `release <id>` releases <id> itself;
#                                    `release-others <id>` releases everything BUT
#                                    <id>. Don't confuse the two — this was a real,
#                                    hit-in-production mix-up (T20260720-113930,
#                                    build-pipeline-repo), which is why the verb was
#                                    renamed from `release-mine` (still accepted as a
#                                    backward-compatible alias) to a name that doesn't
#                                    read as a sibling of `release`.
#   pr-owner <pr-number>         → derive PR ownership from its task's claimed_by.
#                                    Prints "mine" | "free" | "new" (T20260918-404944:
#                                    a same-repo PR, e.g. /stage, introduces the task
#                                    file itself — unclaimed, not yet on `main`; claim
#                                    procedure differs from "free", see address-pr
#                                    SKILL.md §1.6) | "owned:<by>" | "untracked" (PR
#                                    maps to no task) | "unknown" (task file
#                                    unresolvable — caller defers).
#   reclaimable <task-id> [days] → "reclaimable" | "live". Stale iff the relevant
#                                    activity signal exceeds the window (default
#                                    2d): commit date on `main` for a no-PR task,
#                                    or the open PR's last activity (updatedAt)
#                                    for an open-PR task. Open PRs no longer
#                                    auto-block reclaim (T20260622-404636).
#   claimant-id                  → prints this session's claimant id (<machine>:<working-dir>)
#
# Frontmatter edits are best-effort-safe: they operate ONLY within the first
# `---`...`---` fence and never touch the body. All operations are idempotent.

set -uo pipefail

_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TC_DIR/_lib.sh"   # identity helpers: session_machine, session_clone_path
# shellcheck source=/dev/null
source "$_TC_DIR/claimant-id.sh"  # claimant_id + claimant_is_current_shape — the
                                  # ONE definition of the claimant identity,
                                  # shared with statusline-command.sh

# Where task files live, relative to repo root. Resolved at call time
# (via _tc_task_dir) so tests and other repos can override TASK_CLAIM_DIR.
_tc_task_dir() { printf '%s' "${TASK_CLAIM_DIR:-dev/TODO}"; }

# --- Identity ----------------------------------------------------------------

_tc_claimant_id() {
  # "cc1-<machine-id>:<path-hash>" — see claimant-id.sh for the format and why
  # each half looks the way it does. Still the (machine, clone-path) pair
  # semantically: stable across CC invocations in the SAME clone (one clone =
  # one session), so a new /drive or ccxp run supersedes its OWN prior claim
  # instead of stacking a new one, and globally unique when two machines share
  # a /home/... path.
  #
  # T20260911-698434 replaced the plaintext "<hostname>:<clone-path>" form. Two
  # reasons, in order of severity: `hostname` is not stable on one machine
  # (mDNS/MagicDNS/ComputerName disagree and change under you), which produced
  # false "owned by another agent" verdicts against a task's own live owner;
  # and the value lands on `main`, so it published a machine name, an OS
  # username and a filesystem path into a public repo.
  #
  # Fails CLOSED (empty + nonzero) rather than degrading to a hostname, so a
  # caller can never write a half-formed or PII-bearing claim.
  claimant_id
}

# Where PARKING task files live — derived from the TODO dir so a TASK_CLAIM_DIR
# override (tests, other repos) relocates both in lockstep. release-others (formerly release-mine) scans
# TODO + PARKING because a parked task can still carry this session's claim.
_tc_parking_dir() {
  if [ -n "${TASK_CLAIM_PARKING_DIR:-}" ]; then printf '%s' "$TASK_CLAIM_PARKING_DIR"; return; fi
  # Sibling of the task dir (dev/TODO → dev/PARKING). Always derive from the
  # resolved task dir — never a cwd-relative literal — so a TASK_CLAIM_DIR
  # override (or a non-/TODO layout) can't make release-others (formerly release-mine) scan/mutate an
  # unrelated dev/PARKING in the caller's cwd.
  local td; td="$(_tc_task_dir)"
  printf '%s/PARKING' "$(dirname "$td")"
}

# --- Frontmatter get/set (pure; operate only within the first --- fence) -----

_tc_fm_get() {
  # $1 file  $2 field → echo the field's value (trimmed), or empty. First fence only.
  local file="$1" field="$2"
  [ -r "$file" ] || return 1
  awk -v f="$field" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm {
      # anchored "field:" at line start; capture the remainder verbatim
      if (index($0, f":") == 1) {
        v = substr($0, length(f) + 2)        # drop "field:"
        sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        print v; exit
      }
    }
  ' "$file"
}

_tc_fm_set() {
  # $1 file  $2 field  $3 value → set/insert "field: value" within the first
  # fence (replace if present, else insert before the closing ---). An empty
  # value writes a bare "field:" (no trailing space). Atomic.
  local file="$1" field="$2" value="$3" line tmp
  [ -w "$file" ] || { _session_log "task_claim: not writable: $file"; return 1; }
  if [ -n "$value" ]; then line="$field: $value"; else line="$field:"; fi
  tmp="$(mktemp "${file}.tc.XXXXXX")" || return 1
  awk -v f="$field" -v repl="$line" '
    BEGIN { infm = 0; done = 0; opened = 0 }
    NR==1 && $0=="---" { infm = 1; opened = 1; print; next }
    {
      if (infm && $0=="---") {              # closing fence
        if (!done) { print repl; done = 1 }
        infm = 0; print; next
      }
      if (infm && !done && index($0, f":") == 1) {
        print repl; done = 1; next          # replace existing
      }
      print
    }
    END {
      # No frontmatter fence at all → do not fabricate one (task files must
      # have frontmatter). opened guards that pathological case.
      if (!opened) exit 0
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file"
}

# --- scheduled: reality-stamp helpers ----------------------------------------

_tc_current_monday() {
  # Print the ISO date (YYYY-MM-DD) of the Monday that starts the current week.
  # Respects SESSION_TODAY env var for testability (same hook as iteration.sh).
  local today
  today="${SESSION_TODAY:-$(date +%F)}"
  python3 -c "
import datetime, sys
try:
    d = datetime.date.fromisoformat('${today}')
    print((d - datetime.timedelta(days=d.weekday())).isoformat())
except Exception:
    sys.exit(1)
"
}

_tc_stamp_scheduled_if_needed() {
  # Stamp scheduled: = current Monday iff the field is empty/missing OR set to
  # a future Monday (early-pickup — task was scheduled ahead but work starts now).
  # A past scheduled: is a historical record and is left untouched.
  # Idempotent: calling twice with the same current Monday is a no-op.
  local file="$1" cur_monday existing
  cur_monday="$(_tc_current_monday)" || return 1
  existing="$(_tc_fm_get "$file" scheduled)"
  if [ -z "$existing" ] || [[ "$existing" > "$cur_monday" ]]; then
    _tc_fm_set "$file" scheduled "$cur_monday" || return 1
  fi
}

# --- The own-or-defer decision (the anti-steal core) -------------------------

_tc_decide() {
  # $1 current-claimant (may be empty)  $2 my-id → "none" | "mine" | "other".
  local cur="$1" mine="$2"
  if [ -z "$cur" ] || [ "$cur" = "none" ]; then printf 'none'; return 0; fi
  if [ "$cur" = "$mine" ]; then printf 'mine'; return 0; fi
  printf 'other'
}

# --- The reclaim decision (pure; git/gh facts gathered by the caller) --------

_tc_reclaim_decide() {
  # $1 status  $2 claimed_by  $3 commit_days  $4 pr_days  $5 stale_days
  # $6 (optional) live_signal — "1" if the caller observed an in-progress
  #    GH Actions run or a live local PID for this claim, else empty/"0".
  #   → "reclaimable" | "live"
  #
  # A claim is reclaimable only when actively-claimed (Coding/Review with a
  # claimant) AND BOTH activity signals exceed the window:
  #   - commit_days: days since the last commit mentioning the id on `main`
  #     (large when none — incl. an open-PR task whose work sits on an unmerged
  #     branch, invisible to `git log` on main);
  #   - pr_days: days since the open PR's last activity (updatedAt — captures
  #     pushes, comments, reviews), or large when there is NO open PR.
  #
  # An open PR no longer auto-blocks reclaim. The old `has_pr=1 -> live` rule was
  # too conservative: it leaked a dead session's open-PR task forever, which was
  # the recurring pain (T20260622-404636). Now the PR's OWN activity gates it —
  # a PR touched within the window is live, an abandoned one is reclaimable.
  # Because the irrelevant signal is large (no-PR task -> pr_days large; open-PR
  # work-on-branch -> commit_days large), the AND reduces to "the RELEVANT signal
  # is stale", so the no-PR behaviour is unchanged and open-PR tasks gain a
  # PR-activity-gated reclaim path.
  #
  # Two pre-checks (T20260724-312324) run BEFORE the staleness window, either
  # one short-circuiting straight to "live":
  #   1. Non-session claimant format — a claimed_by that matches NEITHER the
  #      current "<host>:<path>" shape (_tc_claimant_id, contains ':/') NOR
  #      the legacy "<sid>@<machine>" shape (contains '@', pre-T20260615-169917
  #      — ages out via this same staleness window, see
  #      "legacy <sid>@<machine> claim still parses, defers, and clears" in
  #      tests/task_claim.bats) is a deliberate human override
  #      (e.g. `claimed_by: Alex`) and is NEVER auto-reclaimable, regardless of
  #      activity staleness.
  #   2. Caller-observed liveness signal — an in-progress GH Actions run or a
  #      live local PID referencing this claim. Gathering it is impure
  #      (gh/ps I/O), so the caller (_tc_reclaimable) computes it and passes
  #      the verdict in as $6, keeping this function pure/unit-testable.
  local status="$1" claimed_by="$2" commit_days="$3" pr_days="$4" stale="$5" live_signal="${6:-}"
  case "$status" in
    Coding|Review) : ;;
    *) printf 'live'; return 0 ;;
  esac
  if [ -z "$claimed_by" ] || [ "$claimed_by" = "none" ]; then printf 'live'; return 0; fi
  case "$claimed_by" in
    *:/*) : ;;  # session-shaped: current "<host>:<path>"
    *)
      # Legacy "<sid>@<machine>" shape (pre-T20260615-169917) — a hex session
      # id of 6+ chars before the '@' (every real example is 8 hex chars,
      # e.g. deadbeef@buildhost, 8d907ecf@buildhost; 6 is a conservative
      # floor). A bare
      # '*@*' match is too loose: a human override that happens to contain
      # '@' (an email address, an '@'-mention) would misclassify as
      # session-shaped and lose its "never auto-reclaimable" protection —
      # caught in code review, T20260724-312324.
      if [[ "$claimed_by" =~ ^cc1-[0-9a-f]{8}:[0-9a-f]{16}$ ]]; then
        # Current "cc1-<machine-id>:<path-hash>" shape (T20260911-698434).
        # ONE-WAY DOOR: this arm must survive a revert of the code that
        # WRITES the shape. Reverting both would leave every live cc1-
        # claim matching neither arm, falling through to the
        # human-override branch below, and becoming permanently
        # unreclaimable — a silent repo-wide stranding. Reader landed
        # before the writer for exactly this reason; drop it only after
        # no cc1- claim exists anywhere.
        # Anchored rather than a `cc1-*` glob so a real hostname that
        # merely begins "cc1-" can never be mistaken for this shape,
        # independently of arm ordering (a legacy plaintext claim like
        # `cc1-box:/home/x` still matches the `*:/*` arm above first).
        : # session-shaped — subject to the staleness window
      elif [[ "$claimed_by" =~ ^[0-9a-fA-F]{6,}@ ]]; then
        : # session-shaped — subject to the staleness window
      else
        printf 'live'; return 0  # non-session claimant — human-assigned, never auto-reclaimable
      fi
      ;;
  esac
  if [ "$live_signal" = "1" ]; then printf 'live'; return 0; fi
  if [ "${commit_days:-0}" -ge "$stale" ] 2>/dev/null && [ "${pr_days:-0}" -ge "$stale" ] 2>/dev/null; then
    printf 'reclaimable'
  else
    printf 'live'
  fi
}

# --- File lookup -------------------------------------------------------------

_tc_find_file() {
  # $1 task-id → echo path to the task file under the task dir, or empty (+ nonzero).
  local id="$1" dir m
  dir="$(_tc_task_dir)"
  for m in "$dir/$id"*.md; do
    [ -e "$m" ] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

_tc_find_file_anydir() {
  # $1 task-id → echo path under TODO **or PARKING**, or empty (+ nonzero).
  # release-others' except-id resolution needs this: the task about to be picked
  # may be a PARKED task being resumed, and a TODO-only lookup would fail to
  # protect it — release-others would then clear the very claim it was told to keep.
  local id="$1" dir m
  for dir in "$(_tc_task_dir)" "$(_tc_parking_dir)"; do
    for m in "$dir/$id"*.md; do
      [ -e "$m" ] && { printf '%s' "$m"; return 0; }
    done
  done
  return 1
}

# --- I/O: git-progress liveness ---------------------------------------------

_tc_days_since_last_commit() {
  # $1 task-id → whole days since the most recent commit mentioning the id on
  # the current branch, or a large number if none. Uses committer date.
  local id="$1" last now
  last="$(git log -1 --format=%ct --grep="$id" 2>/dev/null || true)"
  [ -n "$last" ] || { printf '99999'; return 0; }
  now="$(date +%s)"
  printf '%d' $(( (now - last) / 86400 ))
}

_tc_iso_to_epoch() {
  # $1 ISO-8601 UTC → epoch seconds, or empty. GNU date then BSD date.
  local iso="$1" e
  e="$(date -u -d "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  e="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null)" && { printf '%s' "$e"; return 0; }
  printf ''
}

_tc_pick_pr_field() {
  # $1 task-id  $2 field-name  $3 open-PRs JSON (array of {updatedAt, headRefName, body, title})
  #   → the <field-name> value off the most-recently-updated PR that references
  #     the id by HEAD BRANCH (`t<digits>-…`), body, or title — or empty. Pure
  #     (no I/O), unit-tested. Shared matcher behind _tc_pick_pr_updated_at and
  #     _tc_pick_pr_head_ref (T20260724-312324) — same match set, each caller
  #     just picks a different field off the winning PR.
  #
  # Why match the BRANCH locally (T20260622-404636): a task-tracked PR can carry
  # its id only in the branch name, and `gh ... --search "<id>"` does NOT index
  # headRefName — a bare-term search returns nothing, the PR reads as "no open
  # PR" (99999 -> stale -> FALSE reclaim of a live PR). The branch is the
  # load-bearing signal: `/drive` Phase 4 and `/gcpr` ALWAYS name the branch
  # `t<id>-…`, so every conventionally-created PR is matched here.
  #
  # BY DESIGN — agreement with session_pr_task_id holds on every task-tracked PR
  # (T20260625-733429, resolving T20260622-404636's HIGH finding). session_pr_task_id
  # (the pr-owner resolver) has a THIRD signal this picker does not replicate — a
  # commit-messageHeadline scan — so on paper a PR carrying its id ONLY in commit
  # subjects (non-`t<id>-…` branch AND no id in body/title) resolves there but is
  # missed here. That asymmetry is UNREACHABLE in the reclaim path, this picker's
  # only consumers: _tc_reclaimable (via reclaim_sweep.sh) and _tc_has_live_run
  # run solely against `claimed_by:` task files, and a claimed task's PR is created
  # by /drive Phase 4 or /gcpr, which ALWAYS name the branch `t<id>-…` — signal #1,
  # keyed by BOTH session_pr_task_id and this picker. So every task-tracked PR a
  # claim could have is matched here; a commit-only-id PR is non-task-tracked by
  # construction (no convention created it) and so is never a claimed task's live
  # PR. Replicating signal #3 would need a per-PR commits fetch (N+1 gh calls over
  # every open PR, every reclaim tick) to protect a PR type no tooling produces —
  # the wrong tradeoff. Both halves of the invariant are pinned in
  # tests/task_claim.bats ("matches a BRANCH-named PR (id only in headRefName)" +
  # "commit-only-id PR is by-design unmatched").
  local id="$1" field="$2" json="$3" head_token
  head_token="$(printf '%s' "$id" | sed 's/^T/t/')"
  printf '%s' "$json" | python3 -c '
import json, sys
tid, h, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(0)
m = [p for p in arr
     if (p.get("headRefName") or "").startswith(h)
     or tid in (p.get("body") or "")
     or tid in (p.get("title") or "")]
m.sort(key=lambda p: p.get("updatedAt") or "")
print((m[-1].get(field) or "") if m else "")
' "$id" "$head_token" "$field" 2>/dev/null
}

_tc_pick_pr_updated_at() {
  # $1 task-id  $2 open-PRs JSON → updatedAt of the matched PR. See
  # _tc_pick_pr_field for the match semantics (T20260622-404636/T20260625-733429).
  _tc_pick_pr_field "$1" updatedAt "$2"
}

_tc_pick_pr_head_ref() {
  # $1 task-id  $2 open-PRs JSON → headRefName of the same matched PR (see
  # _tc_pick_pr_field) — the branch _tc_has_live_run checks GH Actions run
  # status against (T20260724-312324).
  _tc_pick_pr_field "$1" headRefName "$2"
}

_tc_has_live_run() {
  # $1 task-id → "1" if there is an in-progress/queued/pending-approval GH
  # Actions run on the branch of this task's open PR, else empty.
  # Cross-host-safe (no PID/host assumptions — works regardless of which box
  # the claim was made from); this is the "always-available" liveness signal
  # T20260724-312324 calls out over a same-host PID check. Best-effort: any
  # gh/network failure resolves to "not live" — fails toward the pre-existing
  # staleness-window behavior, never toward blocking a genuinely dead claim
  # from reclaim.
  local id="$1" pr_json head statuses
  pr_json="$(_session_gh pr list --state open --limit 200 \
             --json headRefName,body,title,updatedAt 2>/dev/null || true)"
  [ -n "$pr_json" ] || { printf ''; return 0; }
  head="$(_tc_pick_pr_head_ref "$id" "$pr_json")"
  [ -n "$head" ] || { printf ''; return 0; }
  statuses="$(_session_gh run list --branch "$head" --limit 5 \
              --json status --jq '.[].status' 2>/dev/null || true)"
  # requested/pending cover a run awaiting environment approval — still live,
  # not just in_progress/queued/waiting (code review, T20260724-312324).
  if grep -qE '^(in_progress|queued|waiting|requested|pending)$' <<<"$statuses"; then
    printf '1'
  else
    printf ''
  fi
}

_tc_pr_activity_days() {
  # $1 task-id → whole days since the most-recently-active OPEN PR referencing the
  # id was last touched (updatedAt: push / comment / review), or a large number
  # when there is NO open PR. Lets an actively-driven PR read as live even with
  # no NEW commits, while an abandoned open PR ages into reclaimability.
  local id="$1" json ts last now
  json="$(_session_gh pr list --state open --limit 200 \
          --json updatedAt,headRefName,body,title 2>/dev/null || true)"
  [ -n "$json" ] || { printf '99999'; return 0; }
  ts="$(_tc_pick_pr_updated_at "$id" "$json")"
  [ -n "$ts" ] || { printf '99999'; return 0; }
  last="$(_tc_iso_to_epoch "$ts")"
  [ -n "$last" ] || { printf '99999'; return 0; }
  now="$(date +%s)"
  printf '%d' $(( (now - last) / 86400 ))
}

# --- Verbs -------------------------------------------------------------------

# $1 claimed_by  $2 my-clone-path → 0 when $1 is a LEGACY "<host>:<path>" claim
# written by this very clone before T20260911-698434 changed the format.
#
# Migration path for claims already on `main`. _tc_acquire only overwrites
# claimed_by in the `none` branch; a legacy self-claim looks like `other` (a
# value is present and does not string-match the new id), so without this it
# would refuse forever and a human would have to hand-edit every claimed task.
#
# Deliberately narrow: LEGACY SHAPE ONLY (contains ':/' — a current cc1- value
# can never reach here) and the path half must be exactly this clone. It does
# NOT compare the host half, because the whole bug being fixed is that the host
# half drifts on one machine — requiring it to match would fail precisely the
# case this exists to rescue.
#
# Residual risk, accepted knowingly: two machines sharing an identical clone
# path (say /home/ci/repo on two CI boxes) can each read the other's legacy
# claim as their own during the migration window. The merge-to-`main` still
# arbitrates the real lock — both would re-stamp different cc1- ids and the
# second merge conflicts — so this changes who wins a race, not whether the
# lock holds. The window closes as soon as each claim is re-stamped.
_tc_is_legacy_self_claim() {
  local claimed_by="$1" my_path="$2"
  [ -n "$claimed_by" ] && [ -n "$my_path" ] || return 1
  case "$claimed_by" in *:/*) : ;; *) return 1 ;; esac
  [ "${claimed_by#*:}" = "$my_path" ]
}

# "ccxp" | "interactive" for THIS clone. Written alongside claimed_by because
# the claimant id's path half is now a hash: attribution used to recover the
# clone path from claimed_by and test it against ATTRIBUTION_CCXP_PATHS, which a
# hash makes impossible (T20260911-698434). A coarse role token is all
# attribution ever consumed, carries no PII, and — unlike a path hash — stays
# comparable from another machine at standup time.
#
# Resolution order mirrors _attribution_load_env: an exported value wins, then
# $ENV_FILE, then ~/.claude/.env; skipped under BATS unless ENV_FILE points at a
# fixture, to keep tests hermetic.
_tc_claimed_role() {
  local path="${1:-}" list p
  [ -n "$path" ] || path="$(claimant_clone_path)"
  list="${ATTRIBUTION_CCXP_PATHS:-}"
  if [ -z "$list" ]; then
    if [ -n "${ENV_FILE:-}" ]; then
      # shellcheck disable=SC1090
      [ -f "$ENV_FILE" ] && source "$ENV_FILE"
    elif [ -z "${BATS_TEST_TMPDIR:-}" ] && [ -f "$HOME/.claude/.env" ]; then
      # shellcheck disable=SC1090
      source "$HOME/.claude/.env"
    fi
    list="${ATTRIBUTION_CCXP_PATHS:-}"
  fi
  local IFS=':'
  for p in $list; do
    [ -n "$p" ] || continue
    [ "$path" = "$p" ] && { printf 'ccxp'; return 0; }
  done
  printf 'interactive'
}

_tc_acquire() {
  local id="$1" file cur mine decision
  file="$(_tc_find_file "$id")" || { _session_log "task_claim: no task file for $id under $(_tc_task_dir)"; return 2; }
  cur="$(_tc_fm_get "$file" claimed_by)"
  mine="$(_tc_claimant_id)" || { _session_log "task_claim: cannot resolve claimant id — refusing to claim $id"; return 1; }
  decision="$(_tc_decide "$cur" "$mine")"
  if [ "$decision" = "other" ] && _tc_is_legacy_self_claim "$cur" "$(claimant_clone_path)"; then
    # Our own pre-migration claim: re-stamp in place, keep status untouched.
    _session_log "task_claim: migrating legacy claim on $id to the current format"
    _tc_fm_set "$file" claimed_by "$mine" || return 1
    _tc_fm_set "$file" claimed_role "$(_tc_claimed_role)" || return 1
    printf 'mine\n'; return 0
  fi
  case "$decision" in
    mine)  printf 'mine\n'; return 0 ;;
    other) printf 'claimed:%s\n' "$cur"; return 3 ;;
    none)
      _tc_fm_set "$file" claimed_by "$mine" || return 1
      _tc_fm_set "$file" claimed_role "$(_tc_claimed_role)" || return 1
      _tc_fm_set "$file" status Coding || return 1
      _tc_stamp_scheduled_if_needed "$file" || return 1
      printf 'acquired\n'; return 0 ;;
  esac
}

_tc_read() {
  local id="$1" file
  file="$(_tc_find_file "$id")" || { _session_log "task_claim: no task file for $id"; return 2; }
  printf '%s\t%s\n' "$(_tc_fm_get "$file" status)" "$(_tc_fm_get "$file" claimed_by)"
}

_tc_release() {
  local id="$1" final="${2:-Open}" file
  file="$(_tc_find_file "$id")" || { _session_log "task_claim: no task file for $id"; return 2; }
  _tc_fm_set "$file" claimed_by "" || return 1
  _tc_fm_set "$file" claimed_role "" || return 1   # same clear-on-close contract as claimed_by
  _tc_fm_set "$file" status "$final" || return 1
  printf 'released\n'
}

_tc_release_others() {
  # Release-on-pickup: free EVERY task currently claimed by THIS identity across
  # TODO + PARKING, EXCEPT $1 if given, so a session holds ≤1 active claim. The
  # pick step (/drive Phase 1, /todo, /ccxp) calls this before acquiring a new
  # task; the clone-stable claimant id (_tc_claimant_id) is what makes "mine"
  # recognizable across CC invocations — without it a live session never
  # releases its prior task and claims accumulate until the backlog reads
  # fully-claimed.
  #
  # Named release-OTHERS (not release-mine, T20260720-113930) so its argument
  # can't be misread as "the task to release" — it's the opposite: the one
  # task to KEEP. `release-mine` is kept as a dispatcher-level alias for any
  # existing caller; both invoke this same function.
  #
  # $1 (optional) except-id — keep this task's claim (the one about to be
  # acquired / re-picked), so re-picking the same task is a no-op. Resolved by
  # FILE across TODO **and PARKING** (_tc_find_file_anydir) so a parked task being
  # resumed is protected, and so the short task-ids used in tests work too.
  #
  # Status handling: only an actively-claimed-but-now-abandoned task (Coding /
  # Design) is returned to the pickable pool (→ Open). Every other status is
  # PRESERVED, just shorn of its claim — critically `Blocked by T<id>` (the
  # compound blocked status: resetting it to Open would re-inject a still-blocked
  # task and destroy the blocker linkage /todo + the lint board-pass rely on),
  # `Review` (a live PR drives it), and the terminal Done/Closed/Parked.
  # Prints "released:<id>" per freed task (nothing if none).
  local except="${1:-}" mine dir f status b id except_file=""
  mine="$(_tc_claimant_id)"
  [ -n "$mine" ] || return 0
  if [ -n "$except" ]; then except_file="$(_tc_find_file_anydir "$except" 2>/dev/null || true)"; fi
  for dir in "$(_tc_task_dir)" "$(_tc_parking_dir)"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      if [ -n "$except_file" ] && [ "$f" -ef "$except_file" ]; then continue; fi
      [ "$(_tc_fm_get "$f" claimed_by)" = "$mine" ] || continue
      status="$(_tc_fm_get "$f" status)"
      case "$status" in Coding|Design) status="Open" ;; *) : ;; esac
      _tc_fm_set "$f" claimed_by ""        || return 1
      _tc_fm_set "$f" status "$status"     || return 1
      b="$(basename "$f")"
      if [[ "$b" =~ (T[0-9]{8}-[0-9]{6}) ]]; then id="${BASH_REMATCH[1]}"; else id="${b%.md}"; fi
      printf 'released:%s\n' "$id"
    done
  done
  return 0
}

_tc_reclaimable() {
  local id="$1" stale="${2:-${TASK_CLAIM_STALE_DAYS:-2}}" file status claimed_by commit_days pr_days live_signal
  file="$(_tc_find_file "$id")" || { _session_log "task_claim: no task file for $id"; return 2; }
  status="$(_tc_fm_get "$file" status)"
  claimed_by="$(_tc_fm_get "$file" claimed_by)"
  commit_days="$(_tc_days_since_last_commit "$id")"
  pr_days="$(_tc_pr_activity_days "$id")"
  live_signal="$(_tc_has_live_run "$id")"
  _tc_reclaim_decide "$status" "$claimed_by" "$commit_days" "$pr_days" "$stale" "$live_signal"
  printf '\n'
}

# --- PR ownership, DERIVED from the task claim (T20260622-404636) ------------

_tc_resolve_task_location() {
  # $1 pr  $2 task-id → echo "<owner/repo>\t<path-to-task-file>" or empty (+ nonzero).
  #
  # Cross-repo PRs carry an explicit `Task:` LINE in the body (a hub URL); the
  # task file then lives in THAT repo, not the PR's repo. Two hardening rules
  # the resolution MUST hold (T20260622-404636 verification):
  #   - parse only the link on the `Task:` line, NOT the first blob link anywhere
  #     in the body — a decoy `Spec:`/`Plan:`/`Builds-on:` cross-link that precedes
  #     it must not redirect us to the wrong file; and
  #   - the resolved filename must belong to THIS task id (basename startswith id),
  #     so a mislinked URL forces the caller's fail-safe `unknown` (defer).
  # A body-fetch FAILURE is not an empty body: fail closed (return 1 -> unknown)
  # rather than silently degrading to the same-repo lookup against the wrong
  # (target) clone — gh always resolves against $PWD's origin.
  local pr="$1" id="$2" body rc links matched n url repo path
  body="$(_session_gh pr view "$pr" --json body --jq '.body // ""' 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 1
  # All blob links on `Task:` lines (a cross-repo PR carries exactly one; a prose
  # "Task:" mention without a link contributes nothing).
  links="$(printf '%s' "$body" | grep -iE '^[[:space:]]*Task:' \
           | grep -oE 'github\.com/[^/]+/[^/]+/blob/[^ )]+\.md')"
  if [ -n "$links" ]; then
    # Keep only links to THIS task's file via a TOKEN-BOUNDARY id match
    # (`<id>-<slug>.md` or bare `<id>.md`) — a string-prefix test would let a
    # longer colliding id through (T…404636 vs T…4046369) — then dedupe. Resolve
    # only if EXACTLY ONE distinct hub link remains: zero (all mislinks) or >1
    # (ambiguous / a same-id decoy line in another repo) → fail closed → defer.
    matched="$(printf '%s\n' "$links" | while IFS= read -r u; do
      [ -n "$u" ] || continue
      case "$(basename "$u")" in "$id"-*.md|"$id".md) printf '%s\n' "$u" ;; esac
    done | sort -u)"
    n="$(printf '%s' "$matched" | grep -c .)"
    [ "$n" -eq 1 ] || return 1
    url="$matched"
    repo="$(printf '%s' "$url" | sed -E 's#.*github\.com/([^/]+/[^/]+)/blob/.*#\1#')"
    path="$(printf '%s' "$url" | sed -E 's#.*/blob/[^/]+/##')"
    { [ -n "$repo" ] && [ -n "$path" ]; } && { printf '%s\t%s' "$repo" "$path"; return 0; }
    return 1
  fi
  # Same-repo: the task file is in this repo under the task dir, falling back
  # to the PARKING dir when TODO has no match — a same-repo PR can revive AND
  # claim a parked task in one commit (the standard "resume a parked task"
  # pattern), and until that PR merges the file only exists in dev/PARKING on
  # `main` (T20260805-345509). Mirrors _tc_find_file_anydir's existing
  # dual-directory search, same token-boundary id match as the cross-repo path
  # above.
  repo="$(_session_gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  [ -n "$repo" ] || return 1
  local dir name
  for dir in "$(_tc_task_dir)" "$(_tc_parking_dir)"; do
    name="$(_session_gh api "/repos/$repo/contents/$dir?ref=main" \
            --jq ".[] | select(.name | startswith(\"$id\")) | .name" 2>/dev/null \
            | while IFS= read -r nm; do case "$nm" in "$id"-*.md|"$id".md) printf '%s\n' "$nm" ;; esac; done \
            | head -1)"
    [ -n "$name" ] && { printf '%s\t%s/%s' "$repo" "$dir" "$name"; return 0; }
  done
  return 1
}

_tc_fetch_fm_field() {
  # $1 owner/repo  $2 path  $3 field  [$4 ref, default "main"] → echo the
  # frontmatter field from that file at $4 (`main` is the source of truth for
  # the common case), or nonzero on any fetch/decode failure. $4 exists so a
  # caller can read a file that only exists on a PR's own head ref and not yet
  # on `main` — see _tc_resolve_task_location_head (T20260918-404944).
  local repo="$1" path="$2" field="$3" ref="${4:-main}" b64 tmp val
  b64="$(_session_gh api "/repos/$repo/contents/$path?ref=$ref" --jq '.content // ""' 2>/dev/null || true)"
  [ -n "$b64" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/tc-fm.XXXXXX")" || return 1
  printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  val="$(_tc_fm_get "$tmp" "$field")"
  rm -f "$tmp"
  printf '%s' "$val"
}

_tc_resolve_task_location_head() {
  # $1 pr  $2 task-id → echo "<owner/repo>\t<path>\t<head-sha>" for a task
  # file that exists on THIS PR's own head ref but is absent from `main` —
  # the /stage "commit queue.md + the new task file in the same PR" case
  # (T20260918-404944): the file legitimately doesn't exist on `main` yet at
  # the moment `/address-pr` is asked to drive the very PR that will put it
  # there. Same-repo only — a cross-repo PR's `Task:` body link (when it
  # carries a real blob-link URL) always names a file already ON the hub
  # repo's `main`, so that case can't hit this gap; see
  # _tc_pr_has_cross_repo_task_link, which the caller uses to gate this
  # fallback so it is only ever reached for the genuine same-repo case.
  # Deliberately a SEPARATE function with a 3-field return — never shares
  # _tc_resolve_task_location's 2-field contract, so every existing caller
  # and test of that function is untouched. Nonzero + empty if the head ref
  # can't be resolved or the file isn't found in either dir.
  local pr="$1" id="$2" repo head dir name
  repo="$(_session_gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  [ -n "$repo" ] || return 1
  head="$(_session_gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)"
  [ -n "$head" ] || return 1
  for dir in "$(_tc_task_dir)" "$(_tc_parking_dir)"; do
    name="$(_session_gh api "/repos/$repo/contents/$dir?ref=$head" \
            --jq ".[] | select(.name | startswith(\"$id\")) | .name" 2>/dev/null \
            | while IFS= read -r nm; do case "$nm" in "$id"-*.md|"$id".md) printf '%s\n' "$nm" ;; esac; done \
            | head -1)"
    [ -n "$name" ] && { printf '%s\t%s/%s\t%s' "$repo" "$dir" "$name" "$head"; return 0; }
  done
  return 1
}

_tc_pr_has_cross_repo_task_link() {
  # $1 pr → 0 (the body has a `Task:`-prefixed line naming a github blob-link
  # URL) | 1 (no such line — either no `Task:` line at all, or one with no
  # link). Mirrors _tc_resolve_task_location's OWN two-stage gate at
  # _session/task_claim.sh:642-644 EXACTLY (Task:-prefix grep piped into a
  # blob-URL grep) so this can never disagree with which branch that function
  # actually takes — see T20260918-404944 design review findings (a
  # presence-only check on the `Task:` prefix alone was too broad: it fired
  # even for a Task:-worded line with no link, which never sends
  # _tc_resolve_task_location down its cross-repo branch in the first place).
  #
  # Fails CLOSED on its own body-fetch failure: prints/returns as if a link
  # WERE present (blocking the same-repo head-ref fallback) rather than as
  # "no link" (which would wrongly allow it) — mirrors
  # _tc_resolve_task_location's own fetch-failure fail-closed behavior
  # (_session/task_claim.sh:638-639, tests/task_claim.bats:780).
  local pr="$1" body rc links
  body="$(_session_gh pr view "$pr" --json body --jq '.body // ""' 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 0   # fetch failed -> fail closed -> "link present"
  links="$(printf '%s' "$body" | grep -iE '^[[:space:]]*Task:' \
           | grep -oE 'github\.com/[^/]+/[^/]+/blob/[^ )]+\.md')"
  [ -n "$links" ]
}

_tc_is_own_cross_repo_clone() {
  # $1 task-id  $2 claimed_by  $3 my-claimant-id  $4 my-clone-path (optional;
  # defaults to this clone) → 0 (yes) | 1 (no). The cross-repo counterpart to
  # _tc_decide's exact-path match.
  #
  # $4 exists because of T20260911-698434: the claimant id's path half is now a
  # HASH, so the ephemeral-target-directory check below can no longer read the
  # path back out of $3. It takes the real local path instead — which is safe,
  # since that value is only compared locally and never written anywhere. Pass
  # it explicitly to keep this pure string logic (the unit tests do).
  #
  # T20260626-195977: a cross-repo task's claim is written from the HUB clone
  # (/drive Phase 1), but /address-pr's cross-repo mode runs from an ephemeral
  # TARGET clone (Phase 1.5: `/tmp/<task-id>-<slug>-target`) — a different path
  # on the SAME host. _tc_decide's exact `<host>:<path>` match can never say
  # "mine" for that legitimate case, so pr-owner always deferred (`owned:`) on
  # the session's own cross-repo PRs. This recognizes exactly that one
  # additional case, without loosening the anti-steal guarantee for anything
  # else: both the machine must match (a foreign machine is never "mine") AND
  # the current clone's path must be the ephemeral ${task-id}-*-target directory
  # Phase 1.5 itself creates for THIS task — a same-host clone working a
  # DIFFERENT task, or any clone that isn't this exact naming convention,
  # still falls through to _tc_decide's "other".
  local id="$1" claimed_by="$2" mine="$3" my_clone_path="${4:-}"
  local claim_host claim_path my_host my_path base
  [ -n "$claimed_by" ] && [ -n "$mine" ] || return 1
  [ -n "$my_clone_path" ] || my_clone_path="$(claimant_clone_path)"
  # The machine half is everything before the first ':'. Under the current
  # format that is "cc1-<machine-id>", which still differs per machine — the
  # whole reason the version marker rides inside this field instead of being a
  # ":"-separated field of its own. Had it been "cc1:<id>:<hash>", this would
  # evaluate to the literal "cc1" for EVERY claim and the foreign-machine guard
  # below would silently pass for everyone.
  claim_host="${claimed_by%%:*}"; claim_path="${claimed_by#*:}"
  my_host="${mine%%:*}";          my_path="${mine#*:}"
  [ -n "$claim_host" ] && [ "$claim_host" = "$my_host" ] || return 1
  [ "$claim_path" != "$my_path" ] || return 1   # exact match is _tc_decide's job, not this one
  base="$(basename "$my_clone_path")"
  case "$base" in
    "$id"-*-target) return 0 ;;
    *) return 1 ;;
  esac
}

_tc_pr_owner() {
  # $1 pr → "mine" | "free" | "new" | "owned:<by>" | "untracked" | "unknown".
  # Derive PR ownership from the claim on the task the PR implements. The task's
  # claimed_by on `main` (the hub repo) is the single source of truth; fetched
  # over the API so it works cross-repo and reads the AUTHORITATIVE main value
  # (not a possibly-edited branch copy). Fail-safe: an unresolvable task file
  # returns "unknown" so the caller defers, never silently proceeds on a PR it
  # cannot prove is free.
  #
  # "new" (T20260918-404944): a same-repo PR (e.g. `/stage`) that introduces
  # the task file itself, unclaimed — the file legitimately doesn't exist on
  # `main` yet. Distinct from "free" because its claim procedure differs (see
  # address-pr/SKILL.md §1.6) — "free"'s claim-on-a-branch-off-main procedure
  # can't see a file that only exists on this PR's own branch.
  local pr="$1" id loc repo path claimed_by mine decision ref="main" via_head=0
  id="$(session_pr_task_id "$pr")"
  [ -n "$id" ] || { printf 'untracked\n'; return 0; }
  if ! loc="$(_tc_resolve_task_location "$pr" "$id")"; then
    # Not on `main` yet. Only fall back to the same-repo head-ref search when
    # _tc_resolve_task_location's failure genuinely came from "no cross-repo
    # Task: link at all" — never when a Task: link WAS present but failed to
    # resolve (fetch error / ambiguous / mismatched / wrong-id), which must
    # stay `unknown` exactly as today (see _tc_pr_has_cross_repo_task_link's
    # own header comment and the T20260918-404944 design review).
    if _tc_pr_has_cross_repo_task_link "$pr"; then
      printf 'unknown\n'; return 0
    fi
    loc="$(_tc_resolve_task_location_head "$pr" "$id")" || { printf 'unknown\n'; return 0; }
    ref="${loc##*$'\t'}"
    loc="${loc%$'\t'*}"
    via_head=1
  fi
  [ -n "$loc" ] || { printf 'untracked\n'; return 0; }
  repo="${loc%%$'\t'*}"; path="${loc#*$'\t'}"
  claimed_by="$(_tc_fetch_fm_field "$repo" "$path" claimed_by "$ref")" || { printf 'unknown\n'; return 0; }
  mine="$(_tc_claimant_id)"
  decision="$(_tc_decide "$claimed_by" "$mine")"
  if [ "$decision" = "other" ] && _tc_is_own_cross_repo_clone "$id" "$claimed_by" "$mine" "$(claimant_clone_path)"; then
    decision="mine"
  fi
  case "$decision" in
    none)  if [ "$via_head" = 1 ]; then printf 'new\n'; else printf 'free\n'; fi ;;
    mine)  printf 'mine\n' ;;
    other) printf 'owned:%s\n' "$claimed_by" ;;
  esac
}

_tc_main() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    acquire)        _tc_acquire "$@" ;;
    read)           _tc_read "$@" ;;
    release)        _tc_release "$@" ;;
    release-others) _tc_release_others "$@" ;;
    release-mine)   _tc_release_others "$@" ;;  # deprecated alias, T20260720-113930
    pr-owner)       _tc_pr_owner "$@" ;;
    reclaimable)    _tc_reclaimable "$@" ;;
    claimant-id)    _tc_claimant_id; printf '\n' ;;
    *) _session_log "usage: task_claim.sh <acquire|read|release|release-others|pr-owner|reclaimable|claimant-id> [task-id|pr-number] [args]"; return 64 ;;
  esac
}

# Dispatch only when executed directly; sourcing (tests) is side-effect-free.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _tc_main "$@"
fi
