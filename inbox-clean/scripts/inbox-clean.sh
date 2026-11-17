#!/usr/bin/env bash
# inbox-clean.sh <verb> ...   (T20261116-391393, routines part 3)
#
# Fact keeper for /inbox-clean. It never talks to Gmail: it validates the plan the model drew up, names the connector
# calls that plan may make, and keeps the undo note. A send-type operation is not reachable from any verb.
#
#   tools                              the connector tools the skill may call, with the capability each needs
#   check-tool <tool>                  exit 0 allowed; 4 never grantable (send, reply, forward, trash, spam, delete); 1 unknown
#   plan [--dry-run] [--routine R] [--repo DIR]   TSV on stdin (thread_id, archive|label|draft, [label]) -> ordered calls
#   undo <file>                        the calls that reverse an undo note (archive, label); drafts are listed for hand removal
#
# Capabilities (gmail.label, gmail.archive, gmail.draft) are checked only when --routine names a routine, and only
# from the machine-local profile file (run-routine.sh allowed). An interactive run has the user present and checks none.
# Undo notes: ${CCXP_INBOX_CLEAN_DIR:-<profile dir>/ccxp-inbox-clean}/undo-<epoch>.tsv (action, thread id, label; never mail text).
set -euo pipefail

_IC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IC_DRAFT_LABEL="ccxp/draft-for-review"
IC_ARCHIVE_LABEL="ccxp/archived"

function ic-die() { echo "inbox-clean: $*" >&2; return "${IC_RC:-2}"; }

# tool<TAB>capability ('-' = read only)
function ic-tools() {
  printf '%s\t%s\n' \
    search_threads - get_thread - get_message - list_labels - \
    create_label gmail.label label_thread gmail.label \
    unlabel_thread gmail.archive create_draft gmail.draft
}

function ic-check-tool() {
  local tool="${1:?check-tool needs a tool name}"
  case "$tool" in
    send_message | reply | forward | trash_* | untrash_* | mark_*spam | unmark_*spam | delete_* | update_draft | update_message_labels | label_message | unlabel_message | apply_sensitive_*)
      echo "never-grantable $tool"; return 4 ;;
  esac
  if ic-tools | cut -f1 | grep -Fqx -- "$tool"; then echo "allowed $tool"; return 0; fi
  echo "unknown $tool"; return 1
}

function ic-plan() {
  local dry=0 routine="" repo="." profile_dir line n=0 k=0 tid action arg cap
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --routine) routine="${2:?--routine needs a name}"; shift 2 ;;
      --repo) repo="${2:?--repo needs a dir}"; shift 2 ;;
      *) ic-die "plan: unknown argument '$1'"; return ;;
    esac
  done
  local -a labels=() archives=() drafts=() undo=()
  local has_label=" " seen_cap=" "   # space-delimited sets (no bash 4 associative arrays: stock macOS bash is 3.2)
  while IFS=$'\t' read -r tid action arg || [ -n "${tid:-}" ]; do
    n=$((n + 1))
    [ -n "$tid" ] || continue
    k=$((k + 1))
    [[ "$tid" =~ ^[0-9a-f]{6,32}$ ]] || { IC_RC=4 ic-die "line $n: bad thread id"; return; }
    case "$action" in
      label)
        # only the skill's own ccxp/ namespace: system labels (INBOX, TRASH, SPAM, CATEGORY_*, any case) can never match
        [[ "${arg:-}" =~ ^ccxp/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]] || { IC_RC=4 ic-die "line $n: label must be ccxp/<name>"; return; }
        labels+=("$tid"$'\t'"$arg"); has_label="$has_label$tid "; seen_cap="$seen_cap""gmail.label " ;;
      archive) archives+=("$tid"); seen_cap="$seen_cap""gmail.archive " ;;
      draft) drafts+=("$tid"); seen_cap="$seen_cap""gmail.draft gmail.label " ;;
      *) IC_RC=4 ic-die "line $n: action '$action' is not one of archive|label|draft"; return ;;
    esac
  done
  (( k > 0 )) || { IC_RC=3 ic-die "empty plan"; return; }
  # an archived thread keeps a label so it stays findable
  for tid in ${archives[@]+"${archives[@]}"}; do [[ "$has_label" == *" $tid "* ]] || { labels+=("$tid"$'\t'"$IC_ARCHIVE_LABEL"); seen_cap="$seen_cap""gmail.label "; }; done
  if [ -n "$routine" ]; then
    local runner="$_IC_DIR/../../routine/scripts/run-routine.sh"
    for cap in $(tr ' ' '\n' <<<"$seen_cap" | sort -u); do
      bash "$runner" --repo "$repo" allowed "$routine" "$cap" || { IC_RC=5 ic-die "routine '$routine' lacks $cap (profile file only)"; return; }
    done
  fi
  local pfx=""; (( dry )) && pfx="DRY-RUN "
  local -a calls=()
  for line in ${labels[@]+"${labels[@]}"}; do
    IFS=$'\t' read -r tid arg <<<"$line"
    calls+=("${pfx}label_thread"$'\t'"$tid"$'\t'"$arg"); undo+=("label"$'\t'"$tid"$'\t'"$arg")
  done
  for tid in ${archives[@]+"${archives[@]}"}; do
    calls+=("${pfx}unlabel_thread"$'\t'"$tid"$'\tINBOX'); undo+=("archive"$'\t'"$tid"$'\tINBOX')
  done
  for tid in ${drafts[@]+"${drafts[@]}"}; do
    calls+=("${pfx}create_draft"$'\t'"$tid"$'\t-' "${pfx}label_thread"$'\t'"$tid"$'\t'"$IC_DRAFT_LABEL")
    undo+=("draft"$'\t'"$tid"$'\t'"$IC_DRAFT_LABEL")
  done
  if (( ! dry )); then
    # the undo note is written before any call is printed: no note, no call
    profile_dir="${CCXP_INBOX_CLEAN_DIR:-${CCXP_PROFILE_DIR:+$CCXP_PROFILE_DIR/ccxp-inbox-clean}}"
    [ -n "$profile_dir" ] || { IC_RC=3 ic-die "no undo dir (set CCXP_INBOX_CLEAN_DIR); make no call without an undo note"; return; }
    umask 077
    mkdir -p "$profile_dir"
    local file; file="$profile_dir/undo-$(date +%s)-$$.tsv"
    printf '%s\n' "${undo[@]}" >"$file"
    chmod 600 "$file"
    echo "undo=$file"
  fi
  printf '%s\n' "${calls[@]}"
}

function ic-undo() {
  local file="${1:?undo needs a file}" action tid label
  [ -r "$file" ] || { IC_RC=3 ic-die "cannot read $file"; return; }
  while IFS=$'\t' read -r action tid label; do
    [[ "$tid" =~ ^[0-9a-f]{6,32}$ ]] || { IC_RC=4 ic-die "bad undo line"; return; }
    [[ "$label" =~ ^(ccxp/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*|INBOX)$ ]] || { IC_RC=4 ic-die "bad undo line"; return; }
    case "$action" in
      archive) printf 'label_thread\t%s\t%s\n' "$tid" "$label" ;;
      label) printf 'unlabel_thread\t%s\t%s\n' "$tid" "$label" ;;
      draft) printf 'MANUAL\t%s\tremove the draft by hand (no delete call is made)\n' "$tid" ;;
      *) IC_RC=4 ic-die "bad undo line"; return ;;
    esac
  done <"$file"
}

function inbox-clean() {
  local verb="${1:-}"
  [ $# -eq 0 ] || shift
  case "$verb" in
    tools) ic-tools ;;
    check-tool) ic-check-tool "$@" ;;
    plan) ic-plan "$@" ;;
    undo) ic-undo "$@" ;;
    *) echo "usage: inbox-clean.sh tools|check-tool|plan|undo ..." >&2; return 2 ;;
  esac
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  inbox-clean "$@"
fi
