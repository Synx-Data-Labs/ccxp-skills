#!/usr/bin/env bash
# labrun.sh — the mechanical parts of /labrun-rca. It only parses and renders
# text; it never posts to Slack and never calls gh (the /slack MCP call and the
# root-cause diagnosis stay with the skill).
#
#   labrun.sh parse <permalink-or-text>
#       Find the first Slack message permalink
#       (https://<ws>.slack.com/archives/<C|G|D...>/p<16 digits>) and print
#         channel_id=<id>
#         message_ts=<10 digits>.<6 digits>
#       Exit 2 if there is no well-formed permalink.
#
#   labrun.sh extract-run [FILE]        (text from FILE, or stdin)
#       Find the announced GitHub Actions run: /actions/runs/<id> links first,
#       else "run <id>" / "run #<id>", else a lone bare 11-13 digit number.
#       One distinct id prints  run_id=<id>  and, when it came from a link,
#       run_url=<https url>. Exit 3 = no run id, 4 = more than one distinct id
#       (the ids are listed on stdout as candidate=<id>); never guesses.
#
#   labrun.sh render-reply --workflow W --run-id N --run-url URL --error E
#       --root-cause R --classification C --confidence F --impact I --action A
#       Render the RCA thread reply (Slack mrkdwn) on stdout. All values are
#       one line. classification: Our code|Infrastructure|Upstream|Transient|
#       Configuration (case-insensitive, "our-code" ok); confidence: Confirmed|
#       Unconfirmed. Exit 2 usage, 5 enum failure, 6 the reply contains a
#       token-like string (nothing is printed, the match is not echoed).
#
#   labrun.sh input <permalink> | <channel_id> <message_ts> | <run_id>
#       Resolve a job's argument. Prints channel_id=/message_ts= (permalink or
#       pair) or run_id= (a bare number of 6+ digits). Exit 2 otherwise.
#
#   labrun.sh repo-of <run-url>            prints repo=<owner/repo> (exit 2 if not a run url)
#   labrun.sh repo-allowed <owner/repo>    exit 0 when the owner (or full repo) is in
#       LABRUN_SERVED_OWNERS (space/comma separated, default Synx-Data-Labs), else 7.
#   labrun.sh channel-guard <channel_id>   exit 0 only for $SLACK_AUTOMATION_ALERTS_CHANNEL_ID
#       (exit 8 for any other channel, 2 when the variable is unset).
#
#   labrun.sh group-alerts              (lines '<key><TAB><run_id>' on stdin)
#       Prints '<key><TAB><run_id><TAB>rca|reuse': the first alert of a run id is
#       'rca' (run the RCA), later ones 'reuse' (same result, own thread reply).
#
#   labrun.sh alert-kind [--branch B] [--default-branch D]   (message text on stdin)
#       Prints "failure" (exit 0), or "not a failure alert[: branch X is not D]"
#       (exit 9): no failure signal (failed/errored/cancelled/timed out, or failure/
#       failing/:x:/a run link without a recovery word), recovered/resolved text, or a
#       branch other than D (default main). The job stays silent on exit 9.
#
#   labrun.sh thread-state --now EPOCH [--live-job yes|no]   (replies on stdin, "ts<TAB>text")
#       done (exit 10): a reply starts with *RCA. wait (exit 11): the only replies
#       are the ack and it is under 60 minutes old or a job is live. continue (exit 0).
# Exit: 0 ok.
set -uo pipefail

die() { echo "labrun.sh: $1" >&2; exit "${2:-2}"; }

cmd_parse() {
  [ $# -eq 1 ] || die "usage: labrun.sh parse <permalink-or-text>"
  local cand url any=0
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    any=1
    url="${cand%%[?#]*}"
    url="$(printf '%s' "$url" | sed -E 's/[).,;:!]+$//')"
    if [[ "$url" =~ ^https://[A-Za-z0-9.-]+\.slack\.com/archives/([CGD][A-Z0-9]{2,})/p([0-9]{16})$ ]]; then
      local ch="${BASH_REMATCH[1]}" raw="${BASH_REMATCH[2]}"
      printf 'channel_id=%s\nmessage_ts=%s.%s\n' "$ch" "${raw:0:10}" "${raw:10}"
      return 0
    fi
  done < <(printf '%s\n' "$1" | grep -oE 'https://[A-Za-z0-9.-]+\.slack\.com/archives/[^][:space:]<>|]+')
  if [ "$any" = 1 ]; then die "malformed Slack permalink; expected https://<workspace>.slack.com/archives/<channel_id>/p<16 digits>"; fi
  die "no Slack permalink found; expected https://<workspace>.slack.com/archives/<channel_id>/p<ts_without_dot>"
}

cmd_extract_run() {
  [ $# -le 1 ] || die "usage: labrun.sh extract-run [FILE]"
  local text ids urls n
  if [ $# -eq 1 ]; then [ -r "$1" ] || die "cannot read $1"; text="$(cat "$1")"; else text="$(cat)"; fi
  text="$(printf '%s' "$text" | sed 's#\\/#/#g')"   # Block Kit JSON escapes / as \/
  urls="$(printf '%s\n' "$text" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+' | awk -F/runs/ '!s[$2]++')"
  if [ -n "$urls" ]; then
    ids="$(printf '%s\n' "$urls" | sed -E 's#.*/runs/##' | awk '!s[$0]++')"
  else
    ids="$(printf '%s\n' "$text" | grep -oiE '\brun[ :#]+[0-9]{6,}(\.[0-9])?' | grep -v '\.' | grep -oE '[0-9]+$' | awk '!s[$0]++')"
    if [ -z "$ids" ]; then
      # a lone bare number as its own token (not part of a decimal / Slack ts)
      ids="$(printf '%s\n' "$text" | tr -c '0-9A-Za-z._' '\n' | sed -E 's/\.+$//' | grep -xE '[0-9]{11,13}' | awk '!s[$0]++')"
    fi
  fi
  n="$(printf '%s' "$ids" | grep -c .)"
  if [ "$n" -eq 0 ]; then echo "labrun.sh: no run id found in the notification" >&2; exit 3; fi
  if [ "$n" -gt 1 ]; then
    echo "labrun.sh: $n distinct run ids found; not guessing" >&2
    printf '%s\n' "$ids" | sed 's/^/candidate=/'
    exit 4
  fi
  printf 'run_id=%s\n' "$ids"
  [ -z "$urls" ] || printf 'run_url=%s\n' "$urls"
}

# escape Slack control characters; keep the value on one line
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# token-like strings: provider prefixes, private keys, JWTs, webhook URLs,
# and "token/secret/password = value" assignments
has_token() {
  printf '%s' "$1" | grep -qE \
    -e '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' \
    -e 'xox[abeprs]-[A-Za-z0-9-]{8,}|xapp-[0-9]-[A-Za-z0-9-]{8,}' \
    -e '(AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}' \
    -e '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}' \
    -e 'npm_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20,}' \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY' \
    -e 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' \
    -e 'sk_(live|test)_[A-Za-z0-9]{16,}|[sr]k_live_[A-Za-z0-9]{16,}' \
    -e 'hooks\.slack\.com/services/[A-Za-z0-9/]+' \
    -e '://[^/[:space:]:@]+:[^/[:space:]@]+@' && return 0
  # case-insensitive: credential assignments and Authorization headers
  printf '%s' "$1" | grep -qiE \
    -e '(token|secret|passw(or)?d|api[_-]?key) +[A-Za-z0-9._~+/=-]{20,}' \
    -e '(bearer|basic) +[A-Za-z0-9._~+/=-]{16,}' \
    -e '(token|secret|passw(or)?d|api[_-]?key|access[_-]?key|authorization)[A-Za-z0-9_]*["'\'']? *[=:] *["'\'']?[^[:space:]"'\'']{8,}'
}

cmd_render_reply() {
  local wf="" rid="" url="" err="" root="" cls="" conf="" impact="" action="" k
  local seen=" "
  while [ $# -gt 0 ]; do
    k="$1"
    case "$k" in
      --workflow|--run-id|--run-url|--error|--root-cause|--classification|--confidence|--impact|--action) ;;
      *) die "unknown argument: $k" ;;
    esac
    [ $# -ge 2 ] || die "$k needs a value"
    case "$2" in *$'\n'*|*$'\r'*) die "$k must be a single line" ;; esac
    seen="$seen$k "
    case "$k" in
      --workflow) wf="$2" ;; --run-id) rid="$2" ;; --run-url) url="$2" ;;
      --error) err="$2" ;; --root-cause) root="$2" ;; --classification) cls="$2" ;;
      --confidence) conf="$2" ;; --impact) impact="$2" ;; --action) action="$2" ;;
    esac
    shift 2
  done
  for k in --workflow --run-id --run-url --error --root-cause --classification --confidence --impact --action; do
    case "$seen" in *" $k "*) ;; *) die "missing $k" ;; esac
  done
  for k in "$wf" "$err" "$root" "$impact" "$action"; do
    [ -n "$(printf '%s' "$k" | tr -d '[:space:]')" ] || die "empty value for a required field"
  done
  [[ "$rid" =~ ^[0-9]+$ ]] || die "--run-id must be numeric"
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$ ]] || die "--run-url must be https://github.com/<owner>/<repo>/actions/runs/<id>"

  [ "${url##*/runs/}" = "$rid" ] || die "--run-id $rid does not match the id in --run-url"
  local c
  c="$(printf '%s' "$cls" | tr '[:upper:] ' '[:lower:]-')"
  case "$c" in
    our-code) cls="Our code" ;; infrastructure) cls="Infrastructure" ;; upstream) cls="Upstream" ;;
    transient) cls="Transient" ;; configuration) cls="Configuration" ;;
    *) die "--classification must be Our code|Infrastructure|Upstream|Transient|Configuration, got '$cls'" 5 ;;
  esac
  c="$(printf '%s' "$conf" | tr '[:upper:]' '[:lower:]')"
  case "$c" in
    confirmed) conf="Confirmed" ;; unconfirmed) conf="Unconfirmed" ;;
    *) die "--confidence must be Confirmed|Unconfirmed, got '$conf'" 5 ;;
  esac

  local out
  out="$(printf '*RCA — %s run %s*\n\n*Error:* `%s`\n*Root cause:* %s\n*Classification:* %s\n*Confidence:* %s\n*Impact:* %s\n*Action:* %s\n\nLogs: <%s|run>\n' \
    "$(esc "$wf")" "$rid" "$(esc "$err" | tr '`' "'")" "$(esc "$root")" "$cls" "$conf" "$(esc "$impact")" "$(esc "$action")" "$url")"
  if has_token "$out"; then
    echo "labrun.sh: the reply contains a token-like string; refusing to render (redact the input)" >&2
    exit 6
  fi
  printf '%s\n' "$out"
}


cmd_input() {
  local a
  case $# in
    1)
      a="$1"
      if [[ "$a" =~ ^[0-9]{6,}$ ]]; then printf 'run_id=%s\n' "$a"; return 0; fi
      cmd_parse "$a" ;;
    2)
      [[ "$1" =~ ^[CGD][A-Z0-9]{2,}$ ]] || die "channel id must match [CGD][A-Z0-9]{2,}, got '$1'"
      [[ "$2" =~ ^[0-9]{10}\.[0-9]{6}$ ]] || die "message ts must be <10 digits>.<6 digits>, got '$2'"
      printf 'channel_id=%s\nmessage_ts=%s\n' "$1" "$2" ;;
    *) die "usage: labrun.sh input <permalink> | <channel_id> <message_ts> | <run_id>" ;;
  esac
}

cmd_repo_of() {
  [ $# -eq 1 ] || die "usage: labrun.sh repo-of <run-url>"
  [[ "$1" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/[0-9]+([/?#]|$) ]] || die "not a GitHub Actions run url: $1"
  printf 'repo=%s\n' "${BASH_REMATCH[1]}"
}

cmd_repo_allowed() {
  [ $# -eq 1 ] || die "usage: labrun.sh repo-allowed <owner/repo>"
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "expected owner/repo, got '$1'"
  local served="${LABRUN_SERVED_OWNERS:-Synx-Data-Labs}" e want owner entries
  want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; owner="${want%%/*}"   # GitHub names are case-insensitive
  read -ra entries <<< "${served//,/ }"                                           # no glob expansion
  for e in "${entries[@]}"; do
    e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
    if [ "$e" = "$want" ] || [ "$e" = "$owner" ]; then return 0; fi
  done
  echo "labrun.sh: repo $1 is outside the accounts this profile serves" >&2
  exit 7
}

cmd_channel_guard() {
  [ $# -eq 1 ] || die "usage: labrun.sh channel-guard <channel_id>"
  [ -n "${SLACK_AUTOMATION_ALERTS_CHANNEL_ID:-}" ] || die "SLACK_AUTOMATION_ALERTS_CHANNEL_ID is not set"
  [ "$1" = "$SLACK_AUTOMATION_ALERTS_CHANNEL_ID" ] && return 0
  echo "labrun.sh: channel $1 is not the alerts channel; refusing to post" >&2
  exit 8
}

cmd_alert_kind() {
  local branch="" def="main" text
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) [ $# -ge 2 ] || die "--branch needs a value"; branch="$2"; shift 2 ;;
      --default-branch) [ $# -ge 2 ] || die "--default-branch needs a value"; def="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  text="$(cat | tr '[:upper:]' '[:lower:]')"
  # counts such as "0 failed" / "no failures" are not failure words
  local clean
  clean="$(printf '%s' "$text" | sed -E 's/\b(0|no|zero) +(failed|failures?|errors?)\b//g')"
  # A strong failure word wins over any other word in the message (job names,
  # error excerpts and "3 tests passed" must not mute a real failure). A weak
  # one ("failure", "failing") counts unless the text also says it recovered.
  if printf '%s' "$clean" | grep -qE '\b(failed|errored|cancell?ed|timed out)\b'; then
    :
  elif printf '%s' "$clean" | grep -qE '\b(failure|failing)\b|:x:|actions/runs/' &&
       ! printf '%s' "$clean" | grep -qE '\b(recovered|resolved|succeeded|now green|is green|fixed)\b'; then
    :
  else
    echo "not a failure alert"; exit 9
  fi
  if [ -n "$branch" ] && [ "$branch" != "$def" ]; then
    echo "not a failure alert: branch $branch is not $def"; exit 9
  fi
  echo failure
}

cmd_thread_state() {
  local now="" live="no" ts text last_ack=0 other=0 n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) [ $# -ge 2 ] || die "--now needs a value"; now="$2"; shift 2 ;;
      --live-job) [ $# -ge 2 ] || die "--live-job needs a value"; live="$2"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$now" =~ ^[0-9]+$ ]] || die "--now must be epoch seconds"
  case "$live" in yes|no) ;; *) die "--live-job must be yes or no" ;; esac
  while IFS=$'\t' read -r ts text || [ -n "$ts$text" ]; do
    text="${text//$'\r'/}"
    while [[ "$text" =~ ^([[:space:]]+|\<[@!][^\>]*\>) ]]; do text="${text:${#BASH_REMATCH[0]}}"; done   # leading space / mentions
    # a line whose first field is not a Slack ts is a continuation of a
    # multi-line reply: never count it as a reply of its own
    [[ "$ts" =~ ^[0-9]{9,}(\.[0-9]+)?$ ]] || continue
    n=$((n+1))
    case "$text" in
      "*RCA"*) echo done; exit 10 ;;
      "🔍 Running RCA"*) last_ack="${ts%%.*}" ;;
      *) other=1 ;;
    esac
  done
  if [ "$n" -gt 0 ] && [ "$other" = 0 ] && [ "$last_ack" != 0 ]; then
    if [ "$live" = yes ] || [ $((now - last_ack)) -lt 3600 ]; then echo wait; exit 11; fi
  fi
  echo continue
}

cmd_group_alerts() {
  [ $# -eq 0 ] || die "usage: labrun.sh group-alerts   (lines '<key><TAB><run_id>' on stdin)"
  local key rid seen=" "
  while IFS=$'\t' read -r key rid || [ -n "$key$rid" ]; do
    rid="${rid//$'\r'/}"
    [ -n "$key" ] || continue
    [[ "$rid" =~ ^[0-9]+$ ]] || die "run id must be numeric, got '$rid'"
    case "$seen" in
      *" $rid "*) printf '%s\t%s\treuse\n' "$key" "$rid" ;;
      *) seen="$seen$rid "; printf '%s\t%s\trca\n' "$key" "$rid" ;;
    esac
  done
}

[ $# -ge 1 ] || die "usage: labrun.sh parse|extract-run|render-reply|input|repo-of|repo-allowed|channel-guard|alert-kind|thread-state|group-alerts ..."
sub="$1"; shift
case "$sub" in
  parse) cmd_parse "$@" ;;
  extract-run) cmd_extract_run "$@" ;;
  render-reply) cmd_render_reply "$@" ;;
  input) cmd_input "$@" ;;
  repo-of) cmd_repo_of "$@" ;;
  repo-allowed) cmd_repo_allowed "$@" ;;
  channel-guard) cmd_channel_guard "$@" ;;
  alert-kind) cmd_alert_kind "$@" ;;
  thread-state) cmd_thread_state "$@" ;;
  group-alerts) cmd_group_alerts "$@" ;;
  *) die "unknown subcommand: $sub (parse|extract-run|render-reply|input|repo-of|repo-allowed|channel-guard|alert-kind|thread-state)" ;;
esac
