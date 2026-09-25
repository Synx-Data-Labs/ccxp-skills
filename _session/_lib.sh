#!/usr/bin/env bash
# _session/_lib.sh — shared helpers for the Project board mirror + PR correlation.
#
# Provides, for a given task ID:
#   - the Project **Status** single-select mirror (Open/Design/In Progress
#     [or the legacy Coding alias, T20260809-355059]/Review/Blocked/Parked/
#     Done) — best-effort reflection of the task file's `status:`;
#   - **PR→task correlation** (resolve a PR number back to its task ID);
#   - **PR-ref issue-title** annotation (append "(<repo>#<num>)" to the board's
#     issue title so the task→PR mapping shows at a glance);
#   - **session identity** helpers (machine / clone path / cc_session_id),
#     consumed by `task_claim.sh` (the on-main claim lock; PR ownership is now
#     DERIVED from that claim — `task_claim.sh pr-owner` — so the retired
#     `pr_owner.sh` is gone, T20260622-404636). `session_cc_session_id` survives
#     as a generic per-host session-id helper; the claim lock keys on the
#     clone-stable `<machine>:<clone-path>` identity, not on it.
#
# Source from a wrapping script (status.sh, set-pr-ref.sh, …) or call functions
# directly. All operations are idempotent; failures are best-effort (log +
# continue) and never block the caller.
#
# Configuration via env vars (required — no adopting-team default is baked
# in; each team supplies its own via ~/.claude/.env, see README Prerequisites):
#   PROJECT_OWNER       — org login owning the Project V2 board
#   PROJECT_NUMBER      — Project V2 number
#   SESSION_TOKEN       — PAT for org-level Projects RW; falls back to
#                         PROJECT_PAT, then GH_TOKEN
#   CLAUDE_CODE_SESSION_ID — this session's ID; falls back to a
#                         per-host stable UUID in ~/.claude/state/session-id
#
# Unset PROJECT_OWNER/PROJECT_NUMBER do not break anything — every caller in
# this file is best-effort (log + return 1, never abort); the Project board
# mirror just stays a no-op until configured. The frontmatter `status:` field
# on the task file remains the source of truth regardless.

set -uo pipefail

PROJECT_OWNER="${PROJECT_OWNER:-}"
PROJECT_NUMBER="${PROJECT_NUMBER:-}"

# Load PROJECT_OWNER/PROJECT_NUMBER from ~/.claude/.env (machine-global) when
# not already exported — same resolution order and ENV_FILE test seam as
# slack/scripts/slack-send.sh and vpn/scripts/vpn.sh's load_vpn_env. Skipped
# in BATS (unless ENV_FILE points at a fixture) to keep tests hermetic.
_session_load_env() {
  [ -n "$PROJECT_OWNER" ] && return 0
  if [ -n "${ENV_FILE:-}" ]; then
    [ -f "$ENV_FILE" ] && { # shellcheck disable=SC1090
      source "$ENV_FILE"; }
    return 0
  fi
  [ -n "${BATS_TEST_TMPDIR:-}" ] && return 0
  [ -f "$HOME/.claude/.env" ] && { # shellcheck disable=SC1090
    source "$HOME/.claude/.env"; }
}
_session_load_env
PROJECT_OWNER="${PROJECT_OWNER:-}"
PROJECT_NUMBER="${PROJECT_NUMBER:-}"

# _gh/gh.sh's own directory, resolved relative to this file rather than
# hardcoded to ~/.claude/skills — that path only exists on a machine with the
# Claude Code skill installed, not on a bare GHA runner that just cloned this
# repo (T20260810-922807).
_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Internal helpers ---------------------------------------------------

_session_log() {
  printf '%s\n' "$*" >&2
}

_session_token() {
  # Prefer PROJECT_PAT (used by the Tasks-as-Issues mirror), then the
  # auto-provided Actions token.
  printf '%s' "${SESSION_TOKEN:-${PROJECT_PAT:-${GH_TOKEN:-}}}"
}

_session_gh() {
  # gh wrapper. Prefer the _gh/gh.sh sibling (present in any full clone of
  # this repo) — it has its own keyring-based account auto-detection that
  # works fine for interactive sessions. Fall back to plain `gh` when the
  # sibling isn't there (a GHA runner, or a caller that sparse-cloned just
  # _session/): every GHA runner has exactly one token
  # (GH_TOKEN/GITHUB_TOKEN) and no account ambiguity, so plain `gh` is
  # correct there, not just a degraded fallback.
  local tok wrapper
  wrapper="$_SESSION_LIB_DIR/../_gh/gh.sh"
  tok="$(_session_token)"
  if [ -f "$wrapper" ]; then
    if [ -n "$tok" ]; then GH_TOKEN="$tok" bash "$wrapper" "$@"; else bash "$wrapper" "$@"; fi
  else
    if [ -n "$tok" ]; then GH_TOKEN="$tok" gh "$@"; else gh "$@"; fi
  fi
}

# --- Identity -----------------------------------------------------------

session_machine() { hostname; }

session_clone_path() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

session_cc_session_id() {
  # Prefer the runtime-provided session ID; otherwise fall back to a per-host
  # stable UUID stored in ~/.claude/state/session-id. The short prefix
  # (first 8 chars) is what gets written to the Project for scan-ability.
  local raw="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$raw" ]; then
    local state_file="$HOME/.claude/state/session-id"
    if [ -f "$state_file" ]; then
      raw="$(cat "$state_file")"
    else
      mkdir -p "$(dirname "$state_file")"
      raw="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
      printf '%s' "$raw" > "$state_file"
    fi
  fi
  printf '%s' "${raw:0:8}"
}

session_iso_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Project resolution -------------------------------------------------

_SESSION_PROJECT_ID=""

_session_resolve_project() {
  [ -n "$_SESSION_PROJECT_ID" ] && return 0
  if [ -z "$PROJECT_OWNER" ] || [ -z "$PROJECT_NUMBER" ]; then
    _session_log "  ! _session: PROJECT_OWNER/PROJECT_NUMBER not configured — Project board mirror disabled"
    return 1
  fi
  local q='query($login:String!, $number:Int!) { organization(login:$login) { projectV2(number:$number) { id } } }'
  local r
  r="$(_session_gh api graphql -f "query=$q" -f "login=$PROJECT_OWNER" -F "number=$PROJECT_NUMBER" --jq '.data.organization.projectV2.id // ""' 2>/dev/null)" || return 1
  if [ -z "$r" ]; then
    _session_log "  ! _session: could not resolve Project $PROJECT_OWNER/projects/$PROJECT_NUMBER"
    return 1
  fi
  _SESSION_PROJECT_ID="$r"
}

# --- Status field (single-select) resolution ----------------------------
#
# Status is a single-select field with its own options (Open / Design /
# In Progress [or the legacy Coding alias] / Review / Blocked / Parked /
# Done). Cached once per process.

_SESSION_STATUS_FIELD_ID=""
_SESSION_STATUS_OPTION_IDS=""  # space-separated "name=id" pairs

_session_resolve_status_field() {
  [ -n "$_SESSION_STATUS_FIELD_ID" ] && return 0
  _session_resolve_project || return 1
  local q='query($id:ID!) { node(id:$id) { ... on ProjectV2 { fields(first:50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }'
  local raw
  raw="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" 2>/dev/null)" || return 1
  _SESSION_STATUS_FIELD_ID="$(printf '%s' "$raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for f in data.get('data', {}).get('node', {}).get('fields', {}).get('nodes', []):
    if f.get('name') == 'Status':
        print(f.get('id', ''))
        break
")"
  if [ -z "$_SESSION_STATUS_FIELD_ID" ]; then
    _session_log "  ! _session: no Status field on Project $PROJECT_OWNER/projects/$PROJECT_NUMBER"
    return 1
  fi
  _SESSION_STATUS_OPTION_IDS="$(printf '%s' "$raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for f in data.get('data', {}).get('node', {}).get('fields', {}).get('nodes', []):
    if f.get('name') == 'Status':
        for o in (f.get('options') or []):
            print(f\"{o['name']}={o['id']}\")
        break
" | tr '\n' ' ')"
}

_session_status_option_id() {
  # Echo the option ID for a given Status value name (case-insensitive).
  local name="$1" want
  want="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' $_SESSION_STATUS_OPTION_IDS | tr ' ' '\n' | awk -F= -v n="$want" 'tolower($1)==n {print $2; exit}'
}

_session_set_single_select_field() {
  # _session_set_single_select_field <item_id> <field_id> <option_id>
  local item_id="$1" field_id="$2" option_id="$3"
  [ -z "$item_id" ] || [ -z "$field_id" ] || [ -z "$option_id" ] && return 1
  local q
  q="$(printf 'mutation { updateProjectV2ItemFieldValue(input: {projectId: "%s", itemId: "%s", fieldId: "%s", value: {singleSelectOptionId: "%s"}}) { projectV2Item { id } } }' \
    "$_SESSION_PROJECT_ID" "$item_id" "$field_id" "$option_id")"
  _session_gh api graphql -f "query=$q" >/dev/null 2>&1
}

# --- Project item lookup by task ID -------------------------------------

_session_find_item_for_task() {
  # Walks Project items (up to 200) and returns the first whose linked
  # Issue title starts with "<task-id>:" or "<task-id> —".
  # Echoes the projectItem id, or empty.
  local task_id="$1"
  _session_resolve_project || return 1
  local q='query($id:ID!, $cursor:String) { node(id:$id) { ... on ProjectV2 { items(first:100, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { id content { ... on Issue { title } } } } } } }'
  local cursor=""
  local found=""
  while :; do
    local r
    if [ -z "$cursor" ]; then
      r="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" 2>/dev/null)" || return 1
    else
      r="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" -f "cursor=$cursor" 2>/dev/null)" || return 1
    fi
    found="$(printf '%s' "$r" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
items = data.get('data', {}).get('node', {}).get('items', {}).get('nodes', [])
tid = '$task_id'
for it in items:
    c = (it.get('content') or {})
    t = c.get('title') or ''
    if t.startswith(f'{tid}:') or t.startswith(f'{tid} '):
        print(it['id'])
        break
")"
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
    local has_next
    has_next="$(printf '%s' "$r" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('data',{}).get('node',{}).get('items',{}).get('pageInfo',{}).get('hasNextPage', False))")"
    [ "$has_next" != "True" ] && return 1
    cursor="$(printf '%s' "$r" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['node']['items']['pageInfo']['endCursor'])")"
  done
}

# --- Status field write -------------------------------------------------

session_set_status() {
  # session_set_status <task_id> <status_value>
  #
  # Sets the Project Status single-select field for the given task. Value
  # is case-insensitive; resolves to the matching Project option (Open,
  # Design, In Progress [or the legacy Coding alias], Review, Blocked,
  # Parked, Done).
  #
  # Best-effort: failures log and return non-zero, but never abort the
  # caller. The frontmatter `status:` field in the task file remains the
  # source of truth; this is a Project-view mirror.
  local task_id="$1" value="$2"
  [ -z "$task_id" ] && { _session_log "  ! _session: set_status called with empty task id"; return 1; }
  [ -z "$value" ] && { _session_log "  ! _session: set_status called with empty value"; return 1; }
  _session_resolve_status_field || return 1
  local item_id
  item_id="$(_session_find_item_for_task "$task_id")" || {
    _session_log "  ! _session: no Project item found for $task_id"; return 1;
  }
  local option_id
  option_id="$(_session_status_option_id "$value")"
  if [ -z "$option_id" ]; then
    _session_log "  ! _session: no Status option '$value' on Project (have: $_SESSION_STATUS_OPTION_IDS)"
    return 1
  fi
  _session_set_single_select_field "$item_id" "$_SESSION_STATUS_FIELD_ID" "$option_id" || {
    _session_log "  ! _session: set_status mutation failed for $task_id → $value"; return 1;
  }
  _session_log "  + _session: set Status=$value for $task_id"
}

# --- PR → task ID correlation ------------------------------------------

session_pr_task_id() {
  # session_pr_task_id <pr_number>
  #
  # Returns the task ID for a PR by trying three signals in order:
  #   1. PR body `Task: .../T<id>-<slug>.md` link (cross-repo PRs) — checked
  #      first because it's written deliberately (by /gcpr's cross-repo
  #      convention, or a manual rescope note) and is strictly more likely to
  #      be current than a branch name fixed at PR-creation time and never
  #      renamed (T20260718-160579: a rescoped PR's body Task: link named the
  #      correct current task while the stale branch name still matched a
  #      closed/superseded one).
  #   2. Branch name pattern `t<8-digit-date>-<id>` (tracked-task convention)
  #   3. PR commit messageHeadline scan for a `(T<id>)`-parenthesized or
  #      leading `T<id>:` mention — NOT any bare `T<id>` substring. A bare
  #      substring also matches a task ID mentioned as *data* (e.g. /top's
  #      own `docs(queue): move T<id> to the top` reorder commit), which is
  #      not the same as "this commit implements/closes that task"
  #      (T20260925-332662).
  # Echoes the task ID (e.g. T20260515-171645) or empty string. Quiet on
  # miss — callers decide what to do when correlation fails.
  local pr="$1" tid
  [ -z "$pr" ] && return 0
  # Anchor to a `Task:`-prefixed line, not the first T-id anywhere in the body —
  # a prose mention earlier in the body (e.g. a "Doc updates: T… warm-up gap"
  # bullet) must not win over the deliberate Task: link (T20260718-160579:
  # a PR body can mention several unrelated T-ids before the actual Task:
  # line).
  tid="$(_session_gh pr view "$pr" --json body --jq .body 2>/dev/null \
    | grep -iE '^[[:space:]]*Task:' \
    | grep -oE 'T[0-9]{8}-[0-9]+' | head -1)"
  if [ -z "$tid" ]; then
    tid="$(_session_gh pr view "$pr" --json headRefName --jq .headRefName 2>/dev/null \
      | grep -oE '^t[0-9]{8}-[0-9]+' | head -1 | sed 's/^t/T/')"
  fi
  if [ -z "$tid" ]; then
    tid="$(_session_gh pr view "$pr" --json commits --jq '.commits[].messageHeadline' 2>/dev/null \
      | grep -oE '\(T[0-9]{8}-[0-9]+\)|^T[0-9]{8}-[0-9]+:' \
      | grep -oE 'T[0-9]{8}-[0-9]+' | head -1)"
  fi
  printf '%s' "$tid"
}

# --- PR ref in issue title ----------------------------------------------
#
# Append "(<repo>#<num>)" to a task's issue title so the Project board shows
# the task->PR mapping at a glance. Project items are issue-backed (created by
# the Tasks-as-Issues mirror), so the board displays the *issue* title — we
# edit that, and the item inherits it. The "<task-id>:" prefix is preserved,
# so _session_find_item_for_task's startswith match keeps working unchanged.

session_parse_pr_ref() {
  # session_parse_pr_ref <pr-url-or-shortform> — echo "<repo>\t<num>" or fail.
  # Pure string logic (unit-tested). Accepts a full PR URL or a "[owner/]repo#num"
  # shortform; the owner, if present, is dropped (titles carry just the repo).
  #   https://github.com/your-org/ccxp-skills/pull/35 -> ccxp-skills  35
  #   ccxp-skills#35                                         -> ccxp-skills  35
  #   your-org/ccxp-skills#35                          -> ccxp-skills  35
  local input="${1:-}" repo="" num=""
  if [[ "$input" =~ github\.com/[^/]+/([^/]+)/pull/([0-9]+) ]]; then
    repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
  elif [[ "$input" =~ ([A-Za-z0-9._-]+)#([0-9]+)$ ]]; then
    repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
  fi
  [ -n "$repo" ] && [ -n "$num" ] && printf '%s\t%s' "$repo" "$num"
}

session_pr_ref_suffix() {
  # session_pr_ref_suffix <pr-url-or-shortform> — echo "(<repo>#<num>)" or fail.
  # Pure; built on session_parse_pr_ref.
  local parsed repo num
  parsed="$(session_parse_pr_ref "${1:-}")" || return 1
  repo="${parsed%%$'\t'*}"
  num="${parsed##*$'\t'}"
  [ -n "$repo" ] && [ -n "$num" ] && printf '(%s#%s)' "$repo" "$num"
}

_session_find_issue_for_task() {
  # Walk all Project items (100 per page) and, for the first whose linked Issue
  # title starts with "<task-id>:" or "<task-id> ", echo "<issue_node_id>\t<title>".
  # Empty + non-zero on miss. Mirrors _session_find_item_for_task's walk but
  # returns the Issue node id + title (needed to edit the board-visible title).
  local task_id="$1"
  _session_resolve_project || return 1
  local q='query($id:ID!, $cursor:String) { node(id:$id) { ... on ProjectV2 { items(first:100, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { content { ... on Issue { id title } } } } } } }'
  local cursor=""
  while :; do
    local r
    if [ -z "$cursor" ]; then
      r="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" 2>/dev/null)" || return 1
    else
      r="$(_session_gh api graphql -f "query=$q" -f "id=$_SESSION_PROJECT_ID" -f "cursor=$cursor" 2>/dev/null)" || return 1
    fi
    local found
    found="$(printf '%s' "$r" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('data', {}).get('node', {}).get('items', {}).get('nodes', [])
tid = '$task_id'
for it in items:
    c = (it.get('content') or {})
    t = c.get('title') or ''
    if t.startswith(f'{tid}:') or t.startswith(f'{tid} '):
        print((c.get('id') or '') + '\t' + t)
        break
")"
    if [ -n "$found" ]; then
      printf '%s' "$found"
      return 0
    fi
    local has_next
    has_next="$(printf '%s' "$r" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('data',{}).get('node',{}).get('items',{}).get('pageInfo',{}).get('hasNextPage', False))")"
    [ "$has_next" != "True" ] && return 1
    cursor="$(printf '%s' "$r" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['node']['items']['pageInfo']['endCursor'])")"
  done
}

_session_update_issue_title() {
  # _session_update_issue_title <issue_node_id> <new_title>
  # Passes the title via a GraphQL variable (no manual escaping needed).
  local issue_id="$1" title="$2"
  [ -z "$issue_id" ] && return 1
  local q='mutation($id:ID!, $title:String!) { updateIssue(input: {id: $id, title: $title}) { issue { id } } }'
  _session_gh api graphql -f "query=$q" -f "id=$issue_id" -f "title=$title" >/dev/null 2>&1
}

session_append_pr_ref() {
  # session_append_pr_ref <task_id> <pr-url-or-shortform>
  #
  # Append " (<repo>#<num>)" to the task's issue title (which the Project board
  # inherits). Idempotent: if that exact suffix is already in the title, no-op.
  # Best-effort: logs + returns non-zero on any failure, never aborts the caller.
  local task_id="$1" pr_ref="$2"
  [ -z "$task_id" ] && { _session_log "  ! _session: append_pr_ref called with empty task id"; return 1; }
  [ -z "$pr_ref" ] && { _session_log "  ! _session: append_pr_ref called with empty pr ref"; return 1; }
  local suffix
  suffix="$(session_pr_ref_suffix "$pr_ref")" || {
    _session_log "  ! _session: could not parse PR ref '$pr_ref'"; return 1;
  }
  local found issue_id title
  found="$(_session_find_issue_for_task "$task_id")" || {
    _session_log "  ! _session: no Project issue found for $task_id"; return 1;
  }
  issue_id="${found%%$'\t'*}"
  title="${found#*$'\t'}"
  if [ -z "$issue_id" ]; then
    _session_log "  ! _session: issue id missing for $task_id"; return 1;
  fi
  case "$title" in
    *"$suffix"*) _session_log "  = _session: $task_id title already has $suffix"; return 0 ;;
  esac
  _session_update_issue_title "$issue_id" "$title $suffix" || {
    _session_log "  ! _session: failed to update title for $task_id"; return 1;
  }
  _session_log "  + _session: appended $suffix to $task_id title"
}
