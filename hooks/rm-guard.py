#!/usr/bin/env python3
"""PreToolUse(Bash) guard: deny plain file deletion, point the agent at trash.sh.

Reads the hook JSON on stdin. Prints a permissionDecision "deny" JSON object when
the Bash command would delete something outside a temp dir; prints nothing
(no opinion) otherwise. Any internal error or parse failure FAILS OPEN: one line
on stderr, nothing on stdout, exit 0.

Detected as a real invocation (command position, after tokenizing with a small
shell lexer, not a text grep): rm, unlink, `find ... -delete`, `find ... -exec rm`,
`xargs rm`, also behind /bin/rm, command, sudo, env, nohup, time, ... and inside
&&, ||, ;, |, $( ), backticks, ( ), `bash -c '...'`, eval, heredocs fed to a shell.
Not detected: `git rm`, `docker rm`, `npm rm`, `kubectl delete`, the word rm inside
quotes / echo / grep / commit messages, and rmdir (only removes empty dirs).

Allowed: every delete target resolves strictly under /tmp, /private/tmp or $TMPDIR
(simple `VAR=/tmp/x` assignments, `cd`, ~, $TMPDIR and `$(mktemp -d)` are followed).
A target that cannot be resolved statically ($(...), unknown $VAR, braces, xargs
stdin) counts as outside temp.

Escape hatch: CCXP_ALLOW_RM=1 in the environment of the Claude Code process.
"""
import json
import os
import re
import sys

TEMP_SENTINEL = "/tmp/.ccxp-mktemp"  # stands for "a fresh path made by mktemp"
MAX_DEPTH = 8


class ParseError(Exception):
    pass


class TempVal(object):
    """Value of a variable assigned from `$(mktemp ...)` that lands in a temp dir."""


class Word(object):
    def __init__(self):
        self.segs = []   # (kind, text); kind: lit | dq | raw | sub
        self.subs = []   # inner text of each command substitution

    def add(self, kind, text):
        if self.segs and self.segs[-1][0] == kind and kind != "sub":
            self.segs[-1] = (kind, self.segs[-1][1] + text)
        else:
            self.segs.append((kind, text))

    def empty(self):
        return not self.segs

    def source(self):
        return "".join(t for k, t in self.segs if k != "sub")


def lit_word(text):
    w = Word()
    w.add("lit", text)
    return w


class Cmd(object):
    def __init__(self, sep):
        self.sep = sep       # operator that preceded it: ; && || | |& & ( ) or ""
        self.words = []
        self.extra_subs = []  # substitutions found in redirection targets
        self.heredocs = []    # heredoc bodies attached to this command


# --------------------------------------------------------------------------- lexer

def heredoc_end(s, i):
    """s[i:] is just after '<<' inside $( ). Return the index just past the
    heredoc body's terminator line, or None when it is not a recognizable
    heredoc (then the caller scans on as before)."""
    n = len(s)
    if i < n and s[i] == "-":
        i += 1
    while i < n and s[i] in " \t":
        i += 1
    q = s[i] if i < n and s[i] in "'\"" else ""
    if q:
        i += 1
    j = i
    while j < n and (s[j].isalnum() or s[j] == "_"):
        j += 1
    delim = s[i:j]
    if not delim or (q and (j >= n or s[j] != q)):
        return None
    j += 1 if q else 0
    nl = s.find("\n", j)
    if nl < 0:
        return None
    pos = nl + 1
    while pos <= n:
        e = s.find("\n", pos)
        line = s[pos:] if e < 0 else s[pos:e]
        if line.strip("\t") == delim:
            return n if e < 0 else e
        if e < 0:
            return None
        pos = e + 1
    return None


def match_paren(s, i):
    """s[i:] is just after '('. Return index of the matching ')'."""
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "<" and s.startswith("<<", i) and not s.startswith("<<<", i):
            k = heredoc_end(s, i + 2)
            if k is not None:
                i = k
                continue
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ParseError("unterminated quote in $( )")
            i = j + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                i += 2 if s[i] == "\\" else 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unterminated $(")


def match_brace(s, i):
    j = s.find("}", i)
    if j < 0:
        raise ParseError("unterminated ${")
    return j


def read_backtick(s, i):
    """s[i:] is just after the opening backtick. Return (inner, index after closing)."""
    out, n = [], len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n and s[i + 1] in "`\\$":
            out.append(s[i + 1])
            i += 2
            continue
        if c == "`":
            return "".join(out), i + 1
        out.append(c)
        i += 1
    raise ParseError("unterminated backtick")


def ansi_c(raw):
    try:
        return raw.encode("latin-1", "backslashreplace").decode("unicode_escape")
    except Exception:
        return raw


def read_dollar(s, i, word, in_dq):
    """s[i] == '$'. Append to word; return the new index."""
    n = len(s)
    kind = "dq" if in_dq else "raw"
    nxt = s[i + 1] if i + 1 < n else ""
    if nxt == "(":
        j = match_paren(s, i + 2)
        word.subs.append(s[i + 2:j])
        word.add("sub", str(len(word.subs) - 1))
        return j + 1
    if nxt == "{":
        j = match_brace(s, i + 2)
        word.add(kind, s[i:j + 1])
        return j + 1
    if nxt == "'" and not in_dq:
        j = i + 2
        while j < n and s[j] != "'":
            j += 2 if s[j] == "\\" else 1
        if j >= n:
            raise ParseError("unterminated $'")
        word.add("lit", ansi_c(s[i + 2:j]))
        return j + 1
    if nxt == '"' and not in_dq:
        return i + 1  # $"..." locale string: drop the $
    m = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]").match(s, i + 1)
    if m:
        word.add(kind, s[i:m.end()])
        return m.end()
    word.add(kind, "$")
    return i + 1


def read_dquote(s, i, word):
    """s[i] is just after the opening quote. Return index after the closing quote."""
    n = len(s)
    word.add("dq", "")
    while i < n:
        c = s[i]
        if c == '"':
            return i + 1
        if c == "\\" and i + 1 < n:
            if s[i + 1] in '$"`\\':
                word.add("lit", s[i + 1])
            elif s[i + 1] == "\n":
                pass
            else:
                word.add("dq", s[i:i + 2])
            i += 2
            continue
        if c == "$":
            i = read_dollar(s, i, word, True)
            continue
        if c == "`":
            inner, i = read_backtick(s, i + 1)
            word.subs.append(inner)
            word.add("sub", str(len(word.subs) - 1))
            continue
        word.add("dq", c)
        i += 1
    raise ParseError("unterminated double quote")


def parse(s):
    """Lex shell text into a flat list of Cmd (group parens are Cmd with words==[])."""
    cmds, n, i = [], len(s), 0
    cur = Cmd("")
    word = Word()
    pending = []  # (cmd, delimiter, strip_tabs) heredocs awaiting their body

    def flush_word():
        nonlocal word
        if not word.empty():
            cur.words.append(word)
        word = Word()

    def end_cmd(next_sep):
        nonlocal cur
        flush_word()
        if cur.words or cur.sep in ("(", ")") or cur.extra_subs or cur.heredocs:
            cmds.append(cur)
        cur = Cmd(next_sep)

    def read_redir_target(j):
        """Read the word after a redirection operator; return new index."""
        nonlocal word
        while j < n and s[j] in " \t":
            j += 1
        saved_word = word
        word = Word()
        j = read_plain_word(j)
        cur.extra_subs.extend(word.subs)
        word = saved_word
        return j

    def read_plain_word(j):
        """Read one word starting at j into `word`; return index after it."""
        while j < n:
            c = s[j]
            if c in " \t\n;&|<>()":
                break
            j = read_char(j)
        return j

    def read_char(j):
        c = s[j]
        if c == "\\":
            if j + 1 < n:
                if s[j + 1] == "\n":
                    return j + 2
                word.add("lit", s[j + 1])
                return j + 2
            return j + 1
        if c == "'":
            k = s.find("'", j + 1)
            if k < 0:
                raise ParseError("unterminated single quote")
            word.add("lit", s[j + 1:k])
            return k + 1
        if c == '"':
            return read_dquote(s, j + 1, word)
        if c == "$":
            return read_dollar(s, j, word, False)
        if c == "`":
            inner, k = read_backtick(s, j + 1)
            word.subs.append(inner)
            word.add("sub", str(len(word.subs) - 1))
            return k
        word.add("raw", c)
        return j + 1

    while i < n:
        c = s[i]
        if c in " \t":
            flush_word()
            i += 1
        elif c == "\n":
            end_cmd("")
            i += 1
            if pending:
                for (pcmd, delim, strip) in pending:
                    body = []
                    while i <= n:
                        eol = s.find("\n", i)
                        line = s[i:] if eol < 0 else s[i:eol]
                        i = n + 1 if eol < 0 else eol + 1
                        chk = line.lstrip("\t") if strip else line
                        if chk == delim:
                            break
                        body.append(line)
                    pcmd.heredocs.append("\n".join(body))
                pending = []
        elif c == "#" and word.empty():
            while i < n and s[i] != "\n":
                i += 1
        elif c == ";":
            end_cmd(";")
            i += 1
        elif c == "&" and s[i:i + 2] == "&&":
            end_cmd("&&")
            i += 2
        elif c == "&" and s[i:i + 2] == "&>":
            flush_word()
            i += 3 if s[i:i + 3] == "&>>" else 2
            i = read_redir_target(i)
        elif c == "&":
            end_cmd("&")
            i += 1
        elif c == "|":
            if s[i:i + 2] == "||":
                end_cmd("||")
                i += 2
            elif s[i:i + 2] == "|&":
                end_cmd("|&")
                i += 2
            else:
                end_cmd("|")
                i += 1
        elif c in "<>":
            if i + 1 < n and s[i + 1] == "(":
                end_cmd("(")  # process substitution: a subshell group
                cmds.append(cur)
                cur = Cmd("")
                i += 2
                continue
            if re.fullmatch(r"[0-9]+", word.source()) and len(word.segs) == 1:
                word = Word()  # fd number of the redirection
            else:
                flush_word()
            m = re.compile(r"<<<|<<-?|>>|>\||>&|<&|<>|>|<").match(s, i)
            op = m.group(0)
            i = m.end()
            if op in ("<<", "<<-"):
                while i < n and s[i] in " \t":
                    i += 1
                saved = word
                word = Word()
                i = read_plain_word(i)
                delim = "".join(t for k, t in word.segs if k != "sub")
                word = saved
                pending.append((cur, delim, op == "<<-"))
            else:
                i = read_redir_target(i)
        elif c == "(":
            prev = word.source()[-1:] if not word.empty() else ""
            if not word.empty() and prev in "?*+@!":
                depth, j = 1, i + 1
                while j < n and depth:
                    depth += (s[j] == "(") - (s[j] == ")")
                    j += 1
                word.add("raw", s[i:j])
                i = j
            elif not word.empty() and prev == "=":
                j = s.find(")", i)
                if j < 0:
                    raise ParseError("unterminated array assignment")
                word.add("lit", s[i:j + 1])
                i = j + 1
            else:
                end_cmd("(")
                cmds.append(cur)
                cur = Cmd("")
                i += 1
        elif c == ")":
            end_cmd(")")
            cmds.append(cur)
            cur = Cmd("")
            i += 1
        else:
            i = read_char(i)
    end_cmd("")
    # Re-stamp: a marker Cmd has sep "(" or ")" and no words; fine for the analyzer.
    return cmds


# --------------------------------------------------------------------------- state

class State(object):
    def __init__(self, cwd, env=None):
        self.cwd = cwd       # str or None (unknown)
        self.env = dict(env or {})  # name -> str | TempVal | None (unknown)

    def copy(self):
        return State(self.cwd, self.env)


def temp_roots():
    roots = set()
    for p in ("/tmp", "/private/tmp"):
        roots.add(p)
        roots.add(os.path.realpath(p))
    td = os.environ.get("TMPDIR")
    if td and os.path.isabs(td):
        r = os.path.realpath(td)
        home = os.path.realpath(os.environ.get("HOME", "/nonexistent"))
        # A TMPDIR of "/" or of $HOME (or above it) would turn the guard off.
        if r != "/" and not (home == r or home.startswith(r.rstrip("/") + "/")):
            roots.add(r)
    return roots


def normalize(p):
    """Absolute path with parents resolved; the last component is not followed."""
    base = os.path.basename(p)
    if p.endswith("/") or base in ("", ".", ".."):
        return os.path.realpath(p)
    return os.path.join(os.path.realpath(os.path.dirname(p)), base)


def under_temp(path, cwd):
    if not os.path.isabs(path):
        if cwd is None:
            return False
        path = os.path.join(cwd, path)
    p = normalize(path)
    for r in temp_roots():
        if p != r and p.startswith(r.rstrip("/") + "/"):
            return True
    return False


# --------------------------------------------------------------------------- expansion

_VAR = re.compile(r"\$(?:\{([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]))")
_UNRESOLVED = object()


def lookup(name, env):
    if name in env:
        return env[name]
    if name in ("TMPDIR", "HOME"):
        return os.environ.get(name)
    return _UNRESOLVED


def expand_var(expr, env):
    """expr is the inside of ${...} or a bare name. Return str, TempVal or _UNRESOLVED."""
    if expr in ("$", "!", "#", "?"):
        return "1"  # numeric specials ($$ pid, $? status, ...): never a path on their own
    m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?::?[-=](.*))?", expr, re.S)
    if not m:
        return _UNRESOLVED
    name, default = m.group(1), m.group(2)
    v = lookup(name, env)
    if v is _UNRESOLVED or v is None:
        if name == "TMPDIR" and default is not None:
            return default
        return _UNRESOLVED
    if isinstance(v, str) and v == "" and default is not None:
        return default
    return v


def expand(word, st, soft=False):
    """Return (string, flags) or (None, flags) when it cannot be resolved statically.

    soft=True is for text that will be re-parsed as a script (bash -c, eval, trap):
    an unresolvable $VAR or $(...) stays in the text verbatim instead of failing.
    """
    out, flags = [], set()
    for idx, (kind, text) in enumerate(word.segs):
        if kind == "sub":
            if not soft:
                return None, flags
            out.append("$(" + word.subs[int(text)] + ")")
            continue
        if kind == "lit":
            out.append(text)
            continue
        if kind == "raw":
            if re.search(r"[{}]", _VAR.sub("", text)):
                return None, flags
            if idx == 0 and text.startswith("~"):
                m = re.match(r"~(/|$)", text)
                if not m:
                    return None, flags
                home = os.environ.get("HOME")
                if not home:
                    return None, flags
                text = home + text[1:]
            if re.search(r"[*?\[]", _VAR.sub("", text)):
                flags.add("glob")
        # raw / dq: expand variables
        pieces, last = [], 0
        for m in _VAR.finditer(text):
            pieces.append(text[last:m.start()])
            v = expand_var(m.group(1) if m.group(1) is not None else m.group(2), st.env)
            if v is _UNRESOLVED:
                if not soft:
                    return None, flags
                pieces.append(m.group(0))
            else:
                pieces.append(TEMP_SENTINEL if isinstance(v, TempVal) else v)
            last = m.end()
        pieces.append(text[last:])
        out.append("".join(pieces))
    s = "".join(out)
    if "glob" in flags:
        for comp in s.split("/"):
            if comp.startswith(".") and re.search(r"[*?\[]", comp):
                return None, flags  # .* can match .. in some shells
    return s, flags


def expand_str(word, st):
    return expand(word, st)[0]


def expand_soft(word, st):
    return expand(word, st, soft=True)[0]


# --------------------------------------------------------------------------- analysis

RESERVED = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until",
            "coproc", "fi", "done", "esac"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "ash"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")

# wrapper -> options that consume a separate argument
WRAPPERS = {
    "sudo": set("-u -g -h -p -C -D -R -T -U -r -t --user --group --host --prompt "
                "--chdir --close-from --role --type --other-user".split()),
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "--unset", "--chdir"},
    "nohup": set(),
    "nice": {"-n", "--adjustment"},
    "time": {"-f", "-o", "--format", "--output"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "stdbuf": {"-i", "-o", "-e"},
    "ionice": {"-c", "-n", "-p", "-t"},
    "exec": {"-a"},
    "command": set(),
    "builtin": set(),
}
XARGS_ARG_OPTS = {"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "-R", "-S",
                  "--arg-file", "--delimiter", "--max-args", "--max-procs",
                  "--max-lines", "--max-chars", "--eof", "--replace"}


class Analyzer(object):
    def __init__(self):
        self.violations = []

    # -- helpers
    def violate(self, what, why):
        self.violations.append((what, why))

    def check_targets(self, label, target_words, st, extra_strs=()):
        """target_words: list of Word; extra_strs: already-resolved strings."""
        bad = []
        for w in target_words:
            s = expand_str(w, st)
            if s is None:
                bad.append(w.source() or "<expr>")
            elif not under_temp(s, st.cwd):
                bad.append(s)
        for s in extra_strs:
            if not under_temp(s, st.cwd):
                bad.append(s)
        if bad:
            self.violate(label, bad)

    def analyze_text(self, text, st, depth=0):
        if depth > MAX_DEPTH:
            return
        cmds = parse(text)
        self.run_cmds(cmds, st, depth)

    def run_cmds(self, cmds, st, depth):
        stack = []
        prev_pipe_text = None  # (basename, joined args) of an echo/printf feeding a pipe
        for idx, cmd in enumerate(cmds):
            if cmd.sep == "(" and not cmd.words:
                stack.append(st.copy())
                continue
            if cmd.sep == ")" and not cmd.words:
                if stack:
                    restored = stack.pop()
                    st.cwd, st.env = restored.cwd, restored.env
                continue
            nxt = cmds[idx + 1].sep if idx + 1 < len(cmds) else ""
            piped = cmd.sep in ("|", "|&") or nxt in ("|", "|&", "&")
            for w in cmd.words:
                for inner in w.subs:
                    self.analyze_text(inner, st.copy(), depth + 1)
            for inner in cmd.extra_subs:
                self.analyze_text(inner, st.copy(), depth + 1)
            if piped:
                work = st.copy()
            elif cmd.sep == "||":
                work = st.copy()
            else:
                work = st
            fed = prev_pipe_text if cmd.sep in ("|", "|&") else None
            self.run_cmd(cmd, work, depth, fed)
            if cmd.sep == "||" and not piped:
                if work.cwd != st.cwd:
                    st.cwd = None
                for k, v in work.env.items():
                    if st.env.get(k, _UNRESOLVED) != v:
                        st.env[k] = None
            prev_pipe_text = self.echo_text(cmd, st) if nxt in ("|", "|&") else None

    def echo_text(self, cmd, st):
        words = self.strip_prefix(cmd.words, st.copy())[0]
        if not words:
            return None
        name = expand_str(words[0], st)
        if name is None or os.path.basename(name) not in ("echo", "printf", "cat"):
            return None
        parts = [expand_soft(w, st) for w in words[1:]]
        parts = [p for p in parts if p is not None and not p.startswith("-")]
        return " ".join(parts) + "\n" + "\n".join(cmd.heredocs)

    def strip_prefix(self, words, st):
        """Drop reserved words and VAR=val prefixes. Returns (rest, inline_assignments)."""
        i, assigns = 0, []
        while i < len(words):
            src = words[i].source()
            if src in RESERVED and words[i].segs and words[i].segs[0][0] == "raw":
                i += 1
                continue
            m = ASSIGN.match(src)
            if m and words[i].segs[0][0] in ("raw", "lit"):
                assigns.append(words[i])
                i += 1
                continue
            break
        return words[i:], assigns

    def apply_assign(self, w, st):
        src = w.source()
        name = src[:src.index("=")].rstrip("+")
        # value word = everything after the first '='
        val = Word()
        consumed = False
        for kind, text in w.segs:
            if not consumed and "=" in text and kind in ("raw", "lit"):
                head, _, tail = text.partition("=")
                consumed = True
                if tail:
                    val.segs.append((kind, tail))
            elif consumed:
                val.segs.append((kind, text))
        val.subs = w.subs
        if src.partition("=")[0].endswith("+"):
            st.env[name] = None
            return
        meaningful = [x for x in val.segs if x != ("dq", "")]
        if len(meaningful) == 1 and meaningful[0][0] == "sub":
            inner = val.subs[int(meaningful[0][1])]
            st.env[name] = TempVal() if self.mktemp_in_temp(inner, st) else None
            return
        s, _ = expand(val, st)
        st.env[name] = s

    def mktemp_in_temp(self, inner, st):
        try:
            cmds = parse(inner)
        except ParseError:
            return False
        if len(cmds) != 1:
            return False
        words, _ = self.strip_prefix(cmds[0].words, st)
        strs = [expand_str(w, st) for w in words]
        if not strs or strs[0] is None or os.path.basename(strs[0]) != "mktemp":
            return False
        args, tmpdir_opt, tmpl_opt, i = [], None, False, 1
        while i < len(strs):
            a = strs[i]
            if a is None:
                return False
            if a == "-p" or a == "--tmpdir":
                if a == "-p" or (i + 1 < len(strs) and not strs[i + 1].startswith("-")):
                    if i + 1 >= len(strs) or strs[i + 1] is None:
                        return False
                    tmpdir_opt = strs[i + 1]
                    i += 2
                    continue
                tmpl_opt = True
            elif a.startswith("--tmpdir="):
                tmpdir_opt = a.split("=", 1)[1]
            elif a == "-t":
                tmpl_opt = True
            elif a.startswith("-") and a != "--":
                pass
            else:
                args.append(a)
            i += 1
        if tmpdir_opt is not None:
            return under_temp(tmpdir_opt + "/x", st.cwd)
        if args:
            tpl = args[0]
            if "/" in tpl:
                return under_temp(tpl, st.cwd)
            return tmpl_opt  # bare template: temp dir only with -t
        return True  # no template: $TMPDIR (or /tmp)

    def run_cmd(self, cmd, st, depth, fed_text):
        words, assigns = self.strip_prefix(cmd.words, st)
        if not words:
            for a in assigns:
                self.apply_assign(a, st)
            return
        if assigns:
            st = st.copy()
            for a in assigns:
                self.apply_assign(a, st)
        self.run_words(words, st, depth, cmd.heredocs, fed_text)

    def run_words(self, words, st, depth, heredocs, fed_text):
        words, _ = self.strip_prefix(words, st)
        if not words:
            return
        name = expand_str(words[0], st)
        if name is None:
            return  # command name unknowable
        base = os.path.basename(name)
        args = words[1:]

        if base in WRAPPERS:
            rest = self.strip_wrapper(base, args, st)
            if rest is not None and rest:
                self.run_words(rest, st, depth, heredocs, fed_text)
            return
        if base in ("rm",):
            self.do_rm("rm", args, st)
        elif base == "unlink":
            self.check_targets("unlink", [w for w in args
                                          if (expand_str(w, st) or "x") != "--"], st)
        elif base == "find":
            self.do_find(args, st, depth)
        elif base == "xargs":
            self.do_xargs(args, st, depth, heredocs, fed_text)
        elif base in SHELLS:
            self.do_shell(args, st, depth, heredocs, fed_text)
        elif base == "eval":
            parts = [expand_soft(w, st) for w in args]
            if all(x is not None for x in parts):
                self.analyze_text(" ".join(parts), st.copy(), depth + 1)
        elif base == "trap":
            if args:
                script = expand_soft(args[0], st)
                if script and not script.startswith("-"):
                    self.analyze_text(script, st.copy(), depth + 1)
        elif base == "cd":
            self.do_cd(args, st)
        elif base in ("pushd", "popd"):
            st.cwd = None
        elif base in ("export", "declare", "typeset", "local", "readonly"):
            for w in args:
                if ASSIGN.match(w.source()):
                    self.apply_assign(w, st)

    def strip_wrapper(self, wrapper, args, st):
        if wrapper == "command":
            strs = [expand_str(w, st) for w in args]
            for s in strs:
                if s in ("-v", "-V"):
                    return None  # lookup, not execution
        argopts = WRAPPERS[wrapper]
        i, n = 0, len(args)
        if wrapper == "env":
            while i < n:
                s = expand_str(args[i], st)
                if s is None:
                    return None
                if s == "--":
                    i += 1
                    break
                if s in ("-S", "--split-string") and i + 1 < n:
                    t = expand_soft(args[i + 1], st)
                    if t is not None:
                        self.analyze_text(t, st.copy(), 1)
                    return None
                if s in argopts:
                    i += 2
                elif s.startswith("-") and len(s) > 1:
                    i += 1
                elif ASSIGN.match(args[i].source()):
                    i += 1
                else:
                    break
            return args[i:]
        while i < n:
            s = expand_str(args[i], st)
            if s is None:
                return None
            if s == "--":
                i += 1
                break
            if s in argopts:
                i += 2
            elif s.startswith("-") and len(s) > 1:
                i += 1
            else:
                break
        if wrapper == "timeout" and i < n:
            i += 1  # the duration
        return args[i:]

    def do_cd(self, args, st):
        strs = [expand_str(w, st) for w in args]
        strs = [s for s in strs if s is None or s not in ("--", "-P", "-L")]
        if len(strs) != 1 or strs[0] is None or strs[0] == "-":
            st.cwd = None
            return
        t = strs[0]
        if not os.path.isabs(t):
            if st.cwd is None:
                return
            t = os.path.join(st.cwd, t)
        st.cwd = os.path.realpath(t)

    def do_rm(self, label, args, st):
        targets, opts_done, shown = [], False, ["rm"]
        for w in args:
            s = expand_str(w, st)
            shown.append(w.source())
            if not opts_done and s is not None and s == "--":
                opts_done = True
                continue
            if not opts_done and s is not None and s.startswith("-") and len(s) > 1:
                continue
            targets.append(w)
        if targets:
            self.check_targets(" ".join(shown), targets, st)

    def do_find(self, args, st, depth):
        strs = [expand_str(w, st) for w in args]
        n, i = len(args), 0
        while i < n and strs[i] is not None and (
                strs[i] in ("-H", "-L", "-P") or re.match(r"-O\d", strs[i])):
            i += 1
        if i < n and strs[i] == "-D":
            i += 2
        start = i
        while i < n and not (strs[i] is not None and (
                strs[i].startswith("-") or strs[i] in ("(", ")", "!", ","))):
            i += 1
        roots = args[start:i] or [lit_word(".")]
        shown = "find " + " ".join(w.source() for w in args)
        j = i
        while j < n:
            s = strs[j]
            if s == "-delete":
                self.check_targets(shown, roots, st)
            elif s in ("-exec", "-execdir", "-ok", "-okdir"):
                k = j + 1
                body = []
                while k < n and strs[k] not in (";", "+"):
                    body.append(args[k])
                    k += 1
                if body and self.exec_deletes(body, st):
                    extra = [w for w in self.rm_extra_args(body, st) if w.source() != "{}"]
                    self.check_targets(shown, roots + extra, st)
                elif body:
                    self.run_words(body, st.copy(), depth, [], None)
                j = k
            j += 1

    def exec_deletes(self, words, st):
        w, _ = self.strip_prefix(words, st)
        while w:
            name = expand_str(w[0], st)
            if name is None:
                return False
            base = os.path.basename(name)
            if base in ("rm", "unlink"):
                return True
            if base in WRAPPERS:
                w = self.strip_wrapper(base, w[1:], st) or []
                continue
            return False
        return False

    def rm_extra_args(self, words, st):
        w, _ = self.strip_prefix(words, st)
        while w:
            base = os.path.basename(expand_str(w[0], st) or "")
            if base in WRAPPERS:
                w = self.strip_wrapper(base, w[1:], st) or []
                continue
            break
        out, done = [], False
        for x in w[1:]:
            s = expand_str(x, st)
            if not done and s == "--":
                done = True
                continue
            if not done and s is not None and s.startswith("-") and len(s) > 1:
                continue
            out.append(x)
        return out

    def do_xargs(self, args, st, depth, heredocs, fed_text):
        strs = [expand_str(w, st) for w in args]
        i, n = 0, len(args)
        while i < n:
            s = strs[i]
            if s is None:
                # Unresolvable option token such as -I{}: skip it. Anything
                # else unresolvable is the command itself; give up (allow).
                if args[i].source().startswith("-"):
                    i += 1
                    continue
                return
            if s == "--":
                i += 1
                break
            if s in XARGS_ARG_OPTS:
                i += 2
            elif s.startswith("-") and len(s) > 1:
                i += 1
            else:
                break
        rest = args[i:]
        if not rest:
            return
        if self.exec_deletes(rest, st):
            self.violate("xargs " + " ".join(w.source() for w in rest),
                         ["<paths read from stdin>"])
        else:
            self.run_words(rest, st.copy(), depth, heredocs, fed_text)

    def do_shell(self, args, st, depth, heredocs, fed_text):
        i, n = 0, len(args)
        while i < n:
            s = expand_str(args[i], st)
            if s is None:
                return
            if s == "--":
                i += 1
                break
            if re.fullmatch(r"-[A-Za-z]+", s) and "c" in s:
                if i + 1 < n:
                    script = expand_soft(args[i + 1], st)
                    if script is not None:
                        self.analyze_text(script, st.copy(), depth + 1)
                return
            if s.startswith("-") or s.startswith("+"):
                i += 2 if s in ("-o", "+o", "-O", "+O") else 1
                continue
            break
        if i >= n:  # no script file: `bash <<EOF ...` or `echo '...' | bash`
            for body in heredocs:
                self.analyze_text(body, st.copy(), depth + 1)
            if fed_text:
                self.analyze_text(fed_text, st.copy(), depth + 1)


# --------------------------------------------------------------------------- main

def deny_reason(violations, trash_path, trash_ok):
    shown = []
    for what, why in violations[:3]:
        shown.append("%s  [outside temp: %s]" % (what, ", ".join(why)))
    mover = ("bash '%s' [--label <job>] <paths>" % trash_path) if trash_ok else \
        "mv <paths> ~/.Trash/<YYYYMMDD-HHMMSS>-<label>/ (trash.sh is missing)"
    return (
        "Blocked by the ccxp-skills rm-guard hook: nothing is deleted outright, "
        "it goes to the Trash. Run " + mover + " instead, then list what you moved "
        "and the TRASH <dir> line in your report. Deletes whose targets all sit under "
        "/tmp, /private/tmp or $TMPDIR are allowed. Blocked: " + " ; ".join(shown) +
        " (the owner can override with CCXP_ALLOW_RM=1 in the Claude Code environment)."
    )


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        if os.environ.get("CCXP_ALLOW_RM") == "1":
            return 0
        if data.get("tool_name", "Bash") != "Bash":
            return 0
        command = (data.get("tool_input") or {}).get("command")
        if not isinstance(command, str) or not command.strip():
            return 0
        cwd = data.get("cwd")
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            cwd = os.getcwd()
        an = Analyzer()
        an.analyze_text(command, State(os.path.realpath(cwd)))
        if not an.violations:
            return 0
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        trash = os.path.join(root, "agent-pairing", "scripts", "trash.sh")
        out = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": deny_reason(an.violations, trash, os.path.isfile(trash)),
        }}
        sys.stdout.write(json.dumps(out) + "\n")
        return 0
    except Exception as e:  # fail open
        sys.stderr.write("rm-guard: could not analyze the command (%s: %s); allowing it\n"
                         % (type(e).__name__, e))
        return 0


if __name__ == "__main__":
    sys.exit(main())
