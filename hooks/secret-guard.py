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

Allow-list: .secret-guard-allow in the git toplevel of cwd, one
`rule-id:command-glob:reason` per line (reason mandatory; the glob is matched
against the whole command string, `*` crosses spaces).

Override: CCXP_ALLOW_SECRETS=1 (handled by secret-guard.sh) still runs this
analyzer so the override log can name the rule ids.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys

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
    r"(?<![\w-])--(?:token|password|passwd|passphrase|secret|api-key|apikey|auth-token|access-token)"
    r"(?:\s+|=)(?!-)(['\"]?)(\S+?)\1(?=\s|$|;|\||&)"
)
PASSWORD_ASSIGN = re.compile(r"(?<![\w-])password=(['\"]?)([^\s'\"$;|&]{4,})\1", re.I)
CURL_USER = re.compile(r"\bcurl\b[^|;&\n]*?\s(?:-u|--user)\s+(['\"]?)([^\s:'\"]+):([^\s'\"]+)\1")
DOCKER_LOGIN = re.compile(r"\bdocker\s+login\b[^|;&\n]*?\s(?:-p|--password)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")
URL_CREDS = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s/:@'\"]+:([^\s/@'\"]+)@")
GH_SECRET_BODY = re.compile(r"\bgh\s+secret\s+set\b[^|;&\n]*?\s(?:-b|--body)(?:\s+|=)(['\"]?)(\S+?)\1(?=\s|$)")

VAR_REF = re.compile(r"(?<!\\)\$\{?([A-Za-z_][A-Za-z0-9_]*)")


def mask(v):
    n = min(len(v) // 4, 4)
    return v[:n] + "..."


def secret_var(text):
    """Return the first secret-looking $VAR name in text, or None."""
    for m in VAR_REF.finditer(text):
        name = m.group(1)
        if SAFE_SUFFIX.search(name):
            continue
        if name.isupper() or "_" in name:
            if re.search(SECRET_NAME, name):
                return name
        elif name.lower() in ("token", "password", "passwd", "passphrase", "secret", "pass", "apikey"):
            return name
    return None


def segments(cmd):
    return [s for s in re.split(r"\n|;|&&|\|\||(?<!\|)&(?!&)", cmd) if s.strip()]


def analyze(cmd):
    """Return a list of (rule_id, masked_value) findings for one command string."""
    out = []

    def add(rule, val):
        item = (rule, mask(val))
        if item not in out:
            out.append(item)

    for pat in TOKEN_PATTERNS:
        for m in pat.finditer(cmd):
            add("token-literal", m.group(0))
    for m in NAMED_LITERAL.finditer(cmd):
        if not VAR_REF.match(m.group(2)):
            add("token-literal", m.group(2))

    for m in FLAG_VALUE.finditer(cmd):
        add("cmdline-secret", m.group(2).lstrip("$"))
    for m in PASSWORD_ASSIGN.finditer(cmd):
        add("cmdline-secret", m.group(2))
    for m in CURL_USER.finditer(cmd):
        add("cmdline-secret", m.group(3).lstrip("$"))
    for m in DOCKER_LOGIN.finditer(cmd):
        add("cmdline-secret", m.group(2).lstrip("$"))
    for m in URL_CREDS.finditer(cmd):
        if not m.group(1).startswith("$"):
            add("cmdline-secret", m.group(1))
    for m in GH_SECRET_BODY.finditer(cmd):
        add("cmdline-secret", m.group(2).lstrip("$"))

    for seg in segments(cmd):
        s = seg.strip()
        # echo/printf of a secret variable that goes nowhere but the terminal/transcript.
        m = re.match(r"(?:echo|printf)\b(.*)", s, re.S)
        if m and "|" not in s and ">" not in s:
            name = secret_var(m.group(1))
            if name:
                add("echo-secret", name)
        # environment dumps
        if re.match(r"(?:env|printenv|export\s+-p|declare\s+-[xp]+|set)\s*$", s) or re.match(
            r"(?:env|printenv|export\s+-p)\s*\|\s*(?:cat|less|more)\s*$", s
        ):
            add("env-dump", "env")
        m = re.match(r"printenv\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", s)
        if m and re.search(SECRET_NAME, m.group(1)) and not SAFE_SUFFIX.search(m.group(1)):
            add("env-dump", m.group(1))
        m = re.match(r"(?:env|printenv|export\s+-p)\s*\|\s*(?:grep|egrep|rg)\s+(.*)", s)
        if m and re.search(r"(?i)token|secret|passw|api_?key|credential", m.group(1)) and not re.search(
            r"(?:^|\s)-[a-zA-Z]*[qcl]", m.group(1)
        ):
            add("env-dump", "env")
        if re.match(r"(?:cat|head|tail|less|more|bat)\s+(?:-\S+\s+)*(?:\S*/)?\.env(?:\.[A-Za-z0-9_-]+)?\s*(?:$|\|)", s) and not re.search(
            r"\.env\.(?:tpl|example|sample|template)\b", s
        ):
            add("env-dump", ".env")

    m = re.search(r"(?<![\w-])(?:set\s+-[a-zA-Z]*x|(?:ba|z)?sh\s+(?:-\S+\s+)*-[a-zA-Z]*x)\b", cmd)
    if m:
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


def allowed_rules(cmd, cwd):
    """Rule ids allowed for this command by .secret-guard-allow."""
    path = os.path.join(toplevel(cwd), ".secret-guard-allow")
    allow = set()
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return allow
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":", 2)
        if len(parts) != 3 or not parts[2].strip():
            continue  # reason is mandatory; malformed entries allow nothing
        rule, glob, _ = parts
        if fnmatch.fnmatchcase(cmd, glob.strip()):
            allow.add(rule.strip())
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
        findings = [f for f in findings if f[0] not in ok]
    if os.environ.get("SECRET_GUARD_REPORT_ONLY") == "1":
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
