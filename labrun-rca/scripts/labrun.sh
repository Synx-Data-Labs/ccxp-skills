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
# Exit: 0 ok.
set -uo pipefail

die() { echo "labrun.sh: $1" >&2; exit "${2:-2}"; }

cmd_parse() {
  [ $# -eq 1 ] || die "usage: labrun.sh parse <permalink-or-text>"
  local found url
  found="$(printf '%s\n' "$1" | grep -oE 'https://[A-Za-z0-9.-]+\.slack\.com/archives/[^][:space:]<>|]+' | head -n1)"
  [ -n "$found" ] || die "no Slack permalink found; expected https://<workspace>.slack.com/archives/<channel_id>/p<ts_without_dot>"
  url="${found%%[?#]*}"
  if [[ "$url" =~ ^https://[A-Za-z0-9.-]+\.slack\.com/archives/([CGD][A-Z0-9]{2,})/p([0-9]{16})$ ]]; then
    local ch="${BASH_REMATCH[1]}" raw="${BASH_REMATCH[2]}"
    printf 'channel_id=%s\nmessage_ts=%s.%s\n' "$ch" "${raw:0:10}" "${raw:10}"
  else
    die "malformed Slack permalink; expected https://<workspace>.slack.com/archives/<channel_id>/p<16 digits>"
  fi
}

cmd_extract_run() {
  [ $# -le 1 ] || die "usage: labrun.sh extract-run [FILE]"
  local text ids urls n
  if [ $# -eq 1 ]; then [ -r "$1" ] || die "cannot read $1"; text="$(cat "$1")"; else text="$(cat)"; fi
  urls="$(printf '%s\n' "$text" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+' | awk -F/runs/ '!s[$2]++')"
  if [ -n "$urls" ]; then
    ids="$(printf '%s\n' "$urls" | sed -E 's#.*/runs/##' | awk '!s[$0]++')"
  else
    ids="$(printf '%s\n' "$text" | grep -oiE '\brun[ :#]+[0-9]{6,}' | grep -oE '[0-9]+$' | awk '!s[$0]++')"
    if [ -z "$ids" ]; then
      # a lone bare number, not part of a decimal (Slack ts) or a longer token
      ids="$(printf '%s\n' "$text" | grep -oE '(^|[^0-9.A-Za-z_])[0-9]{11,13}([^0-9.A-Za-z_]|$)' | grep -oE '[0-9]+' | awk '!s[$0]++')"
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
    -e 'hooks\.slack\.com/services/[A-Za-z0-9/]+' \
    -e '://[^/[:space:]:@]+:[^/[:space:]@]+@' && return 0
  # case-insensitive: credential assignments and Authorization headers
  printf '%s' "$1" | grep -qiE \
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

[ $# -ge 1 ] || die "usage: labrun.sh parse|extract-run|render-reply ..."
sub="$1"; shift
case "$sub" in
  parse) cmd_parse "$@" ;;
  extract-run) cmd_extract_run "$@" ;;
  render-reply) cmd_render_reply "$@" ;;
  *) die "unknown subcommand: $sub (parse|extract-run|render-reply)" ;;
esac
