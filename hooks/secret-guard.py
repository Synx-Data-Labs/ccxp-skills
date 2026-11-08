#!/usr/bin/env python3
"""PreToolUse(Bash) hook: deny commands that put a secret where it leaks.

Reads the Claude Code hook JSON on stdin and, when the command line holds a
secret, prints a JSON permissionDecision "deny" on stdout (exit 0), like
rm-guard.py. It never prints a matched value: token-shaped literals are masked
to a short prefix plus "...", every other value to its length only.

Rule ids (kept in step with the header of the hub repo's
scripts/lint-secret-handling.sh; tests/secret_guard_rules.bats compares them):
  token-literal   token-shaped literal (ghp_/github_pat_/xox*-/AKIA/private key/
                  Slack webhook, or SECRET_NAME=<long literal>)
  cmdline-secret  --token/--password <value>, password=<value>, curl -u u:p,
                  docker login -p <value>, user:pass@ URL, gh secret set --body,
                  NAME=<literal> for a secret-named variable
  echo-secret     echo/printf/cat<<< of a secret variable not piped to a
                  consumer or redirected to a file
  env-dump        bare env/printenv/export -p, printenv SECRET_NAME,
                  env|grep secret-ish, cat/head/grep ... .env
  set-x-secret    set -x / bash -x in the same command line as a secret variable
                  (hook semantics: one command line, not a whole script)

Scope: a heuristic backstop on the command string, not a sandbox. Text-only
commands (git commit/log/tag, gh pr|issue create|comment|edit, grep/rg/man, and
echo/printf for the flag rules) are not scanned for flag-like words, and heredoc
bodies are ignored except for token-shaped literals.

Allow-list: .secret-guard-allow in the git toplevel of cwd, honoured only when
tracked and unmodified (an edit alone cannot grant a pass; a committed entry is
visible in review), one `rule-id:command-glob:reason` per line (rule id up to the
first colon, reason after the last, the glob may contain colons; the glob is
matched against the whole command string, `*` crosses spaces). Each hit is
logged like an override.

Override: CCXP_ALLOW_SECRETS=1 (handled by secret-guard.sh) still runs this
analyzer (--report-only) so the override log can name the rule ids.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
import time

RULE_IDS = ("token-literal", "cmdline-secret", "echo-secret", "env-dump", "set-x-secret")

# A secret-ish variable name: a whole "_"-separated word, so TOKENS_USED / TOKENIZER do not match.
SECRET_WORD = r"(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|APIKEY|PRIVATE_KEY|CREDENTIALS?|AUTH|PAT)"
SECRET_NAME_RE = re.compile(r"(?:^|_)" + SECRET_WORD + r"(?:_|$)", re.I)
# AUTH/PAT alone are too common in config names (GH_AUTH=enabled): only echo/expansion rules use them.
STRONG_NAME_RE = re.compile(r"(?:^|_)(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|APIKEY|PRIVATE_KEY|CREDENTIALS?)(?:_|$)", re.I)
SAFE_SUFFIX = re.compile(r"_(?:FILE|PATH|NAME|ID|DIR|URL|VAR|ENV|LENGTH|LEN|COUNT|HOST|USER|MODE|TYPE|METHOD|ENABLED|ENABLE|DISABLED)$", re.I)

TOKEN_PATTERNS = [
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"),
]
# NAME=<long literal> where NAME has a secret word; the value must mix a digit in (not a plain word or path).
NAMED_LITERAL = re.compile(
    r"(?<![\w$])([A-Za-z0-9_]*)=(['\"]?)([A-Za-z0-9+_\-]{16,})\2(?![A-Za-z0-9+_.\-])"
)
# NAME=<literal> as an env prefix or `-e NAME=literal`, any length >= 6, no expansion.
ENV_PREFIX = re.compile(r"(?:(?<=\s)|^)(?:-e\s+|--env[ =]\s*)?([A-Za-z_][A-Za-z0-9_]*)=(['\"]?)([^\s'\"$`()]{6,})\2(?=\s|$)")

FLAG_VALUE = re.compile(
    r"(?<![\w-])--(?:token|password|passwd|passphrase|api-key|apikey|auth-token|access-token)"
    r"(?:\s+|=)(?!-)(['\"]?)(\S+?)\1(?=\s|$|;|\||&)"
)
PASSWORD_ASSIGN = re.compile(r"(?<![\w-])password=(['\"]?)([^\s'\"$;|&]{4,})\1", re.I)
CURL_USER = re.compile(
    r"\bcurl\b[^|;&\n]*?\s(?:-[A-Za-z]*u\s*|--user[=\s]\s*)(['\"]?)([^\s:'\"]*):([^\s'\"]+)\1"
)
DOCKER_LOGIN = re.compile(r"\bdocker\s+login\b[^|;&\n]*?\s(?:-p|--password)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")
MYSQL_P = re.compile(r"\b(?:mysql|mysqldump|mariadb)\w*\s[^|;&\n]*?\s-p([^\s-]\S*)")
URL_CREDS = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@'\"]+:([^\s/@'\"]+)@")
GH_SECRET_BODY = re.compile(r"\bgh\s+secret\s+set\b[^|;&\n]*?\s(?:-b|--body)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")

VAR_REF = re.compile(r"(?<!\\)\$\{?([A-Za-z_][A-Za-z0-9_]*)")

# Commands whose arguments are prose or patterns, not credentials.
TEXT_CMD = re.compile(
    r"\s*(?:grep|egrep|fgrep|rg|man|git\s+(?:commit|log|tag|notes)|gh\s+(?:pr|issue)\s+(?:create|comment|edit|review))\b"
)
ECHO_CMD = re.compile(r"\s*(?:echo|printf)\b")
# A pipe stage that prints its stdin back to the transcript.
PRINTING_SINK = re.compile(r"\s*(?:cat|sed|tee|base64|xxd|od|head|tail|less|more|awk|cut|tr|rev|nl|hexdump)\b")
ENV_FILE_CMD = re.compile(r"\s*(?:cat|head|tail|less|more|bat|grep|egrep|rg|sed|awk)\b")
ENV_FILE_ARG = re.compile(r"(?:^|\s)(?:<\s*)?(?:\S*/)?\.env(?:\.(?!tpl\b|example\b|sample\b|template\b)[A-Za-z0-9_-]+)?(?=\s|$)")


def mask(v, token_shaped=False):
    """Token-shaped literals show a short prefix; anything else shows a length only."""
    if token_shaped:
        return v[: min(len(v) // 4, 4)] + "..."
    return "(%d chars)" % len(v)


def strip_heredocs(cmd):
    """Drop heredoc bodies (their text is data, and an apostrophe there would confuse quoting)."""
    lines = cmd.split("\n")
    out, term = [], None
    for line in lines:
        if term is not None:
            if line.strip() == term:
                term = None
            continue
        out.append(line)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m and "<<<" not in line[m.start():m.start() + 3]:
            term = m.group(2)
    return "\n".join(out)


def split_stages(cmd, pipes=True):
    """Split on newline ; && || & (and a single | when pipes) outside quotes."""
    parts, cur, q, i = [], [], None, 0
    n = len(cmd)
    while i < n:
        c = cmd[i]
        if c == "\\" and q != "'" and i + 1 < n:
            cur.append(cmd[i:i + 2]); i += 2; continue
        if q is None and c in "'\"":
            q = c
        elif q == c:
            q = None
        if q is None:
            two = cmd[i:i + 2]
            if two in ("&&", "||"):
                parts.append("".join(cur)); cur = []; i += 2; continue
            if c in "\n;" or (c == "&" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != ">") or (c == "|" and pipes):
                parts.append("".join(cur)); cur = []; i += 1; continue
        cur.append(c); i += 1
    parts.append("".join(cur))
    return [x for x in parts if x.strip()]


def unquoted_has(text, pattern):
    """True when regex pattern matches outside quotes in text."""
    q = None
    i = 0
    flat = []
    while i < len(text):
        c = text[i]
        if c == "\\" and q != "'" and i + 1 < len(text):
            flat.append("  "); i += 2; continue
        if q is None and c in "'\"":
            q = c; flat.append(" ")
        elif q == c:
            q = None; flat.append(" ")
        else:
            flat.append(" " if q else c)
        i += 1
    return re.search(pattern, "".join(flat)) is not None


def secret_var(text):
    """Return the first secret-looking $VAR name expanded in text, or None."""
    text = re.sub(r"'[^']*'", "''", text)          # single quotes never expand
    text = re.sub(r"\$\{#\w+\}|\$\{\w+:\+[^}]*\}", "", text)  # ${#X} length and ${X:+set} idioms
    for m in VAR_REF.finditer(text):
        name = m.group(1)
        if SAFE_SUFFIX.search(name):
            continue
        if SECRET_NAME_RE.search(name) or name.lower() in ("pass",):
            return name
    return None


def analyze(cmd):
    """Return a list of (rule_id, masked_value) findings for one command string."""
    out = []

    def add(rule, val, token_shaped=False):
        item = (rule, mask(val, token_shaped))
        if item not in out:
            out.append(item)

    for pat in TOKEN_PATTERNS:
        for m in pat.finditer(cmd):
            add("token-literal", m.group(0), True)

    body = strip_heredocs(cmd)

    for m in NAMED_LITERAL.finditer(body):
        name, val = m.group(1), m.group(3)
        if (STRONG_NAME_RE.search(name) and not SAFE_SUFFIX.search(name)
                and re.search(r"\d", val) and re.search(r"[A-Za-z]", val)):
            add("token-literal", val)

    for stage in split_stages(body, pipes=True):
        if TEXT_CMD.match(stage):
            continue
        is_echo = bool(ECHO_CMD.match(stage))
        if not is_echo:
            for m in FLAG_VALUE.finditer(stage):
                add("cmdline-secret", m.group(2).lstrip("$"))
            for m in PASSWORD_ASSIGN.finditer(stage):
                add("cmdline-secret", m.group(2))
            for m in ENV_PREFIX.finditer(stage):
                if (STRONG_NAME_RE.search(m.group(1)) and not SAFE_SUFFIX.search(m.group(1))
                        and not re.search(r"^[/.~]|\.[A-Za-z]{1,5}$", m.group(3))):  # a file path is not a value
                    add("cmdline-secret", m.group(3))
            for pat, grp in ((CURL_USER, 3), (DOCKER_LOGIN, 2), (MYSQL_P, 1), (GH_SECRET_BODY, 2)):
                for m in pat.finditer(stage):
                    add("cmdline-secret", m.group(grp).lstrip("$"))
        for m in URL_CREDS.finditer(stage):
            add("cmdline-secret", m.group(1).lstrip("$"))

    for s in (x.strip() for x in split_stages(body, pipes=False)):
        m = re.search(r"(?:^|[\s({]|\bthen\s|\bdo\s)(?:echo|printf)\b(.*)", s, re.S)
        if m and not TEXT_CMD.match(s):
            rest = m.group(1)
            name = secret_var(rest)
            to_file = unquoted_has(rest, r"(?<![0-9&])>>?\s*(?!&|/dev/std)\S")
            piped = unquoted_has(rest, r"(?<!\|)\|(?!\|)")
            if piped:
                after = split_stages(rest, pipes=True)[1:]
                printing = any(PRINTING_SINK.match(a) or re.match(r"\s*tee\s+/dev/std", a) for a in after)
                piped = not printing
            if name and not to_file and not piped:
                add("echo-secret", name)
        m = re.match(r"cat\s*<<<\s*(.*)", s)
        if m and secret_var(m.group(1)) and not unquoted_has(s, r"[|>]"):
            add("echo-secret", secret_var(m.group(1)))

    for s in (x.strip() for x in split_stages(body, pipes=False)):
        if re.match(r"(?:env|printenv|export\s+-p|declare\s+-[xp]+|set)\s*$", s):
            add("env-dump", "env")
        m = re.match(r"(?:env|printenv|export\s+-p)\s*\|\s*(.*)", s)
        if m:
            rest = m.group(1)
            if re.match(r"(?:cat|less|more|sort|head|tail)\b[^|]*$", rest):
                add("env-dump", "env")
            g = re.match(r"(?:grep|egrep|rg)\s+(.*)", rest)
            if g and re.search(r"(?i)token|secret|passw|api_?key|credential|aws_", g.group(1)) and not re.search(
                r"(?:^|\s)-[a-zA-Z]*[qcl]", g.group(1)
            ):
                add("env-dump", "env")
        m = re.match(r"printenv\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", s)
        if m and SECRET_NAME_RE.search(m.group(1)) and not SAFE_SUFFIX.search(m.group(1)):
            add("env-dump", m.group(1))
        if ENV_FILE_CMD.match(s) and ENV_FILE_ARG.search(s):
            add("env-dump", ".env")

    m = re.search(r"(?<![\w-])(?:set\s+-[a-zA-Z]*x|set\s+-o\s+xtrace|(?:ba|z)?sh\s+(?:-\S+\s+)*-[a-zA-Z]*x)\b", body)
    if m:
        name = secret_var(body)
        if name:
            add("set-x-secret", name)
    return out


def toplevel(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return cwd or "."


def log_line(text):
    # secret-guard.sh passes the resolved path in CCXP_SECRET_GUARD_LOG; the fallback
    # only serves a direct run (tests) and mirrors the helper's order.
    log = os.environ.get("CCXP_SECRET_GUARD_LOG") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"),  # profile-dir-ok
        "secret-guard-overrides.log")
    try:
        os.makedirs(os.path.dirname(log), exist_ok=True)
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")
    except OSError:
        pass


def allowlist_trusted(top, path):
    """The file must be tracked and unmodified, so a bare edit cannot grant a pass."""
    def git(*a):
        return subprocess.run(["git", "-C", top] + list(a), capture_output=True, timeout=5).returncode
    try:
        return git("ls-files", "--error-unmatch", path) == 0 and git("diff", "--quiet", "HEAD", "--", path) == 0
    except (OSError, subprocess.SubprocessError):
        return False


def allowed_rules(cmd, cwd):
    """Rule ids allowed for this command by a committed, unmodified .secret-guard-allow."""
    top = toplevel(cwd)
    path = os.path.join(top, ".secret-guard-allow")
    allow = set()
    if not os.path.isfile(path) or not allowlist_trusted(top, ".secret-guard-allow"):
        return allow
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return allow
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # rule-id up to the first ":", reason after the LAST ":", glob in between (may hold ":").
        head, _, rest = line.partition(":")
        glob, _, reason = rest.rpartition(":")
        if not head or not glob or not reason.strip():
            continue  # reason is mandatory; malformed entries allow nothing
        if fnmatch.fnmatchcase(cmd, glob.strip()):
            allow.add(head.strip())
    return allow


def deny_message(findings):
    lines = ["secret-guard: this command would expose a secret (values are masked here):"]
    for rule, val in findings:
        lines.append("  - %s: %s" % (rule, val))
    lines += [
        "Use a safe form instead:",
        "  - read it from stdin: `cmd --password-stdin <<< \"$VAR\"` or `printf %s \"$VAR\" | cmd --token-stdin`",
        "  - pass a file: `--token-file <path>`; or inject at run time: `op run -- cmd`, `op inject -i .env.tpl`",
        "  - never echo, `env`, `set -x` or `cat .env` a secret; do not write the value in the command",
        "Deliberate exception: add a line `rule-id:command-glob:reason` to a committed .secret-guard-allow, or set "
        "CCXP_ALLOW_SECRETS=1 in the Claude Code process environment (the override is logged).",
    ]
    return "\n".join(lines)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write("secret-guard: unparsable hook input; allowing the command\n")
        return 0
    if not isinstance(data, dict) or data.get("tool_name") not in (None, "Bash"):
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    findings = analyze(cmd)
    if findings:
        ok = allowed_rules(cmd, data.get("cwd", ""))
        hit = sorted({f[0] for f in findings if f[0] in ok})
        if hit:
            log_line("%s allow-list rules=%s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), ",".join(hit)))
        findings = [f for f in findings if f[0] not in ok]
    if "--report-only" in sys.argv[1:]:
        # Used by secret-guard.sh under CCXP_ALLOW_SECRETS=1: print rule ids only.
        print(",".join(sorted({r for r, _ in findings})))
        return 0
    if not findings:
        return 0
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": deny_message(findings),
    }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
