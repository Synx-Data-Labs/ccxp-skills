#!/usr/bin/env python3
"""PreToolUse(Bash) hook: deny commands that put a secret where it leaks.

Reads the Claude Code hook JSON on stdin and, when the command line holds a
secret, prints a JSON permissionDecision "deny" on stdout (exit 0), like
rm-guard.py. It never prints a matched value: findings are masked to a few
leading characters plus "...".

Rule ids (kept in step with the header of the hub repo's
scripts/lint-secret-handling.sh; tests/secret_guard_rules.bats compares them):
  token-literal   token-shaped literal (ghp_/github_pat_/xox*-/AKIA/private key/
                  Slack webhook, or SECRET_NAME=<long literal>)
  cmdline-secret  --token/--password <value>, password=<value>, curl -u u:p,
                  docker login -p <value>, user:pass@ URL, gh secret set --body
  echo-secret     echo/printf of a secret variable with no pipe or redirect
  env-dump        bare env/printenv/export -p, printenv SECRET_NAME,
                  env|grep secret-ish, cat .env
  set-x-secret    set -x / bash -x in the same command line as a secret variable
                  (hook semantics: one command line, not a whole script)

Allow-list: .secret-guard-allow in the git toplevel of cwd, honoured only when
tracked and unmodified (the agent cannot write itself a pass), one
`rule-id:command-glob:reason` per line (rule id up to the first colon, reason
after the last, the glob may contain colons; the glob is matched against the
whole command string, `*` crosses spaces). Each hit is logged like an override.

Override: CCXP_ALLOW_SECRETS=1 (handled by secret-guard.sh) still runs this
analyzer so the override log can name the rule ids.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
import time

RULE_IDS = ("token-literal", "cmdline-secret", "echo-secret", "env-dump", "set-x-secret")

SECRET_NAME = r"(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|PRIVATE_KEY|CREDENTIALS?)"
SAFE_SUFFIX = re.compile(r"_(?:FILE|PATH|NAME|ID|DIR|URL|VAR|ENV|LENGTH|LEN|COUNT|HOST|USER)$", re.I)

TOKEN_PATTERNS = [
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"),
]
NAMED_LITERAL = re.compile(
    r"\b[A-Za-z0-9_]*" + SECRET_NAME + r"[A-Za-z0-9_]*=(['\"]?)([A-Za-z0-9+_\-]{16,})\1(?![A-Za-z0-9+_\-])"
)

FLAG_VALUE = re.compile(
    r"(?<![\w-])--(?:token|password|passwd|passphrase|api-key|apikey|auth-token|access-token)"
    r"(?:\s+|=)(?!-)(['\"]?)(\S+?)\1(?=\s|$|;|\||&)"
)
PASSWORD_ASSIGN = re.compile(r"(?<![\w-])password=(['\"]?)([^\s'\"$;|&]{4,})\1", re.I)
CURL_USER = re.compile(r"\bcurl\b[^|;&\n]*?\s(?:-u|--user)\s+(['\"]?)([^\s:'\"]+):([^\s'\"]+)\1")
DOCKER_LOGIN = re.compile(r"\bdocker\s+login\b[^|;&\n]*?\s(?:-p|--password)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")
URL_CREDS = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@'\"]+:([^\s/@'\"]+)@")
MYSQL_P = re.compile(r"\b(?:mysql|mysqldump|mariadb)\w*\s[^|;&\n]*?\s-p([^\s-]\S*)")
GH_SECRET_BODY = re.compile(r"\bgh\s+secret\s+set\b[^|;&\n]*?\s(?:-b|--body)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")

VAR_REF = re.compile(r"(?<!\\)\$\{?([A-Za-z_][A-Za-z0-9_]*)")


def mask(v, token_shaped=False):
    """Token-shaped literals show a short prefix; anything else shows a length only."""
    if token_shaped:
        return v[: min(len(v) // 4, 4)] + "..."
    return "(%d chars)" % len(v)


def in_quotes(text, pos):
    """True when position pos sits inside an unclosed '...' or "..." string."""
    q = None
    i = 0
    while i < pos:
        c = text[i]
        if c == "\\" and q != "'":
            i += 2
            continue
        if q is None and c in "'\"":
            q = c
        elif q == c:
            q = None
        i += 1
    return q is not None


def split_unquoted(cmd):
    """Split on newline ; && || & outside quotes."""
    parts, cur, q, i = [], [], None, 0
    while i < len(cmd):
        c = cmd[i]
        if c == "\\" and q != "'" and i + 1 < len(cmd):
            cur.append(cmd[i:i + 2]); i += 2; continue
        if q is None and c in "'\"":
            q = c
        elif q == c:
            q = None
        if q is None and (c in "\n;" or (c == "&" and cmd[i - 1:i] != ">" and cmd[i + 1:i + 2] != ">") or (c == "|" and cmd[i + 1:i + 2] == "|")):
            parts.append("".join(cur)); cur = []
            if c in "&|" and cmd[i + 1:i + 2] == c:
                i += 1
            i += 1
            continue
        cur.append(c); i += 1
    parts.append("".join(cur))
    return [x for x in parts if x.strip()]


def secret_var(text):
    """Return the first secret-looking $VAR name in text, or None."""
    for m in VAR_REF.finditer(text):
        name = m.group(1)
        if SAFE_SUFFIX.search(name):
            continue
        if re.search(SECRET_NAME, name, re.I) or re.search(r"(?:^|_)(?:AUTH|PAT)(?:_|$)", name, re.I):
            return name
        if name.lower() in ("pass", "apikey"):
            return name
    return None


def analyze(cmd):
    """Return a list of (rule_id, masked_value) findings for one command string."""
    out = []

    def add(rule, val, token_shaped=False):
        item = (rule, mask(val, token_shaped))
        if item not in out:
            out.append(item)

    def live(m):
        """A match that is real command text, not inside a quoted message/pattern."""
        return not in_quotes(cmd, m.start())

    for pat in TOKEN_PATTERNS:
        for m in pat.finditer(cmd):
            add("token-literal", m.group(0), True)
    for m in NAMED_LITERAL.finditer(cmd):
        add("token-literal", m.group(2))

    plain_text_cmd = re.compile(r"\s*(?:echo|printf|grep|egrep|fgrep|rg|man|git\s+(?:commit|log|tag)|gh\s+(?:pr|issue)\s+(?:create|comment|edit))\b")
    for seg in split_unquoted(cmd):
        if plain_text_cmd.match(seg):
            continue  # flag-like words here are message/pattern text
        for m in FLAG_VALUE.finditer(seg):
            if not in_quotes(seg, m.start()):
                add("cmdline-secret", m.group(2).lstrip("$"))
    for m in PASSWORD_ASSIGN.finditer(cmd):
        if live(m):
            add("cmdline-secret", m.group(2))
    for m in CURL_USER.finditer(cmd):
        add("cmdline-secret", m.group(3).lstrip("$"))
    for m in DOCKER_LOGIN.finditer(cmd):
        add("cmdline-secret", m.group(2).lstrip("$"))
    for m in MYSQL_P.finditer(cmd):
        add("cmdline-secret", m.group(1))
    for m in URL_CREDS.finditer(cmd):
        add("cmdline-secret", m.group(1).lstrip("$"))
    for m in GH_SECRET_BODY.finditer(cmd):
        add("cmdline-secret", m.group(2).lstrip("$"))

    for s in (x.strip() for x in split_unquoted(cmd)):
        # echo/printf (also inside if/then/subshell prefixes) of a secret variable whose
        # output is neither piped to a consumer nor redirected to a real file.
        m = re.search(r"(?:^|[\s({]|\bthen\s|\bdo\s)(?:echo|printf)\b(.*)", s, re.S)
        if m:
            rest = m.group(1)
            name = secret_var(rest)
            to_file = re.search(r"(?<![0-9&])>>?\s*(?!&|/dev/std)\S", rest)
            piped = re.search(r"\|(?!\|)", rest) and not re.search(r"\|\s*tee\s+/dev/std", rest)
            if name and not to_file and not piped:
                add("echo-secret", name)
        m = re.match(r"(?:cat\s*)?<<<\s*(.*)", s)
        if m and re.match(r"cat\b", s) and secret_var(m.group(1)) and "|" not in s and ">" not in s:
            add("echo-secret", secret_var(m.group(1)))
        # environment dumps
        if re.match(r"(?:env|printenv|export\s+-p|declare\s+-[xp]+|set)\s*$", s) or re.match(
            r"(?:env|printenv|export\s+-p)\s*\|\s*(?:cat|less|more)\s*$", s
        ):
            add("env-dump", "env")
        m = re.match(r"printenv\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", s)
        if m and re.search(SECRET_NAME, m.group(1), re.I) and not SAFE_SUFFIX.search(m.group(1)):
            add("env-dump", m.group(1))
        m = re.match(r"(?:env|printenv|export\s+-p)\s*\|\s*(?:grep|egrep|rg)\s+(.*)", s)
        if m and re.search(r"(?i)token|secret|passw|api_?key|credential|aws_", m.group(1)) and not re.search(
            r"(?:^|\s)-[a-zA-Z]*[qcl]", m.group(1)
        ):
            add("env-dump", "env")
        if re.match(r"(?:cat|head|tail|less|more|bat|source|\.)\s+(?:-\S+\s+)*(?:\S*/)?\.env(?:\.[A-Za-z0-9_-]+)?\s*(?:$|\||[0-9]?>)", s) and not re.search(
            r"\.env\.(?:tpl|example|sample|template)\b", s
        ) and not re.match(r"(?:source|\.)\s", s):
            add("env-dump", ".env")

    m = re.search(r"(?<![\w-])(?:set\s+-[a-zA-Z]*x|(?:ba|z)?sh\s+(?:-\S+\s+)*-[a-zA-Z]*x)\b", cmd)
    if m and not in_quotes(cmd, m.start()):
        name = secret_var(cmd)
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
    log = os.environ.get("CCXP_SECRET_GUARD_LOG") or os.path.join(
        os.path.expanduser("~"), ".claude", "secret-guard-overrides.log")
    try:
        os.makedirs(os.path.dirname(log), exist_ok=True)
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")
    except OSError:
        pass


def allowlist_trusted(top, path):
    """The file must be tracked and unmodified: the agent cannot write itself a pass."""
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
        "Deliberate exception: add a line `rule-id:command-glob:reason` to .secret-guard-allow, or set "
        "CCXP_ALLOW_SECRETS=1 in the Claude Code process environment (the override is logged).",
    ]
    return "\n".join(lines)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        sys.stderr.write("secret-guard: unparsable hook input; allowing the command\n")
        return 0
    if data.get("tool_name") not in (None, "Bash"):
        return 0
    cmd = (data.get("tool_input") or {}).get("command") or ""
    findings = analyze(cmd)
    if findings:
        ok = allowed_rules(cmd, data.get("cwd", ""))
        hit = sorted({f[0] for f in findings if f[0] in ok})
        if hit and not os.environ.get("SECRET_GUARD_NO_LOG"):
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
