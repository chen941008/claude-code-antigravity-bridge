#!/usr/bin/env python3
"""Claude Code PreToolUse hook that hard-enforces the grok-bridge safety rules.

Why enforce `<project>/.grok/grok-worker.py` instead of raw `grok` CLI calls?
  - A shell comment (`grok -p fix # --output-format json ...`) or wrapper (`bash -c`, `python3 -c`)
    can strip or bypass raw CLI flags.
  - Critical runtime protections—wall-clock timeout (`os.killpg`), persistent atomic `fcntl.flock`,
    worktree `.grok/config.toml` provisioning, and forced per-mode OS sandboxes—live in
    `<project>/.grok/grok-worker.py`.
  - Therefore, this hook only allows zero-cost read-only discovery commands (`grok models`,
    `grok inspect`, `grok --version`, `grok --help`) directly on the `grok` binary, and requires
    all headless Grok work to go through the project's `<project>/.grok/grok-worker.py`.

Blocks a Bash tool call (exit code 2) when a command:
  1. calls headless `grok` directly instead of `python3 .grok/grok-worker.py`
  2. executes an untrusted `grok-worker.py` path outside `<project>/.grok/grok-worker.py`
  3. wraps `grok` in `eval`, command substitution `$(...)` / backticks, or an inline interpreter
     (`python3 -c`, `node -e`, `ruby -e`, `perl -e`, ...)
  4. omits `--mode read-only` or `--mode write` on `grok-worker.py`
  5. attempts to downgrade the sandbox in `read-only` mode (`--mode read-only` requires
     `--sandbox read-only`) or uses an unsupported `--sandbox` profile in `write` mode
     (only `strict`, `workspace`, and `read-only` are allowed)
  6. passes `--max-turns <N>` outside `1 <= N <= 120` or `--wall-timeout` outside `1..3600`
  7. is neither `run_in_background: true` nor given a Bash `timeout` >= 600000 ms
  8. calls `/usage` or `/cost` (which headless grok sends to the model as a paid prompt)
  9. runs while another worker holds the project directory lock or `<project>/.grok/worker.lock`
 10. points `grok-worker.py` away from the project root (`--cwd`, `cd`, `pushd`, `env -C`)
 11. hands `grok` to any other command (`timeout 60 grok`, `sudo grok`, `find -exec grok`,
     `watch 'grok -p ...'`, `G=grok`), except commands that only print or look up names
     (`which grok`, `grep grok`, `git log --grep grok`, ...)

Shell keywords (`then`, `do`, `{`, `!`), `exec`, and `env -S` are unwrapped before checking.

Limits: this is a static pre-check for an agent that follows the CLAUDE.md rules, not a sandbox.
It cannot see commands assembled at run time (`g=gr; ${g}ok -p ...`) or written to a script file
first (`bash run.sh`); the wrapper's OS sandbox and permission rules are the real boundary.
"""
import errno
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys

MIN_TIMEOUT_MS = 600000
MAX_TURNS_LIMIT = 120
MAX_WALL_TIMEOUT_SEC = 3600

ALLOWED_WRITE_SANDBOXES = {"strict", "workspace", "read-only"}
FORBIDDEN_SANDBOXES = {"off", "devbox", "none", ""}
PAID_SLASH_RE = re.compile(r"^\s*/(?:usage|cost)(?:\s|$)", re.I)

SHELL_BINARIES = {"sh", "bash", "zsh", "dash", "ksh"}
INTERPRETER_BINARIES = {
    "python", "python3", "python2", "pypy", "pypy3",
    "node", "nodejs", "deno", "bun",
    "perl", "ruby", "php", "lua", "tclsh", "wish", "expect", "osascript",
    "awk", "gawk", "nawk",
}
TRANSPARENT_WRAPPERS = {"env", "command", "exec", "nohup", "nice", "ionice", "chrt", "stdbuf", "time"}
# Wrapper options that take the next token as their value.
WRAPPER_VALUE_OPTS = {"env": {"-u", "--unset"}, "nice": {"-n", "--adjustment"}, "exec": {"-a"}}
# Shell keywords that can precede a command in the same segment (`then grok ...`, `! grok ...`).
RESERVED_WORDS = {"!", "{", "}", "if", "then", "elif", "else", "while", "until", "do"}
# Commands that only print, search, or look up names: `grok` in their arguments is data.
INERT_COMMANDS = {
    "which", "type", "whereis", "command", "hash", "man",
    "echo", "printf", "cat", "less", "more", "head", "tail", "wc", "ls", "file", "stat",
    "readlink", "realpath", "basename", "dirname", "test", "[", "[[",
    "grep", "egrep", "fgrep", "rg", "ag", "ack", "git", "diff", "jq",
    "ps", "pgrep", "pkill", "kill",
}
GROK_NAMES = {"grok", "grok.exe", "grok-worker.py"}
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(.*)$", re.DOTALL)
GROK_WORD_RE = re.compile(r"(?:^|[^A-Za-z0-9_-])(?:grok(?:\.exe)?|grok-worker(?:\.py)?)(?:$|[^A-Za-z0-9_-])", re.I)


def strip_posix_comments(cmd):
    """Strip unquoted POSIX shell comments (`#` at token start up to newline)."""
    out = []
    i, n = 0, len(cmd)
    in_single = False
    in_double = False
    at_token_start = True
    while i < n:
        c = cmd[i]
        if in_single:
            out.append(c)
            if c == "'":
                in_single = False
                at_token_start = False
            i += 1
        elif in_double:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(cmd[i + 1])
                i += 2
                continue
            if c == '"':
                in_double = False
                at_token_start = False
            i += 1
        else:
            if c == "\\" and i + 1 < n:
                if cmd[i + 1] == "\n":
                    # POSIX line continuation: backslash-newline is removed before tokenization
                    # and preserves whether we are currently at a token boundary.
                    i += 2
                    continue
                out.append(c)
                out.append(cmd[i + 1])
                at_token_start = False
                i += 2
                continue
            if c == "'":
                in_single = True
                at_token_start = False
                out.append(c)
                i += 1
            elif c == '"':
                in_double = True
                at_token_start = False
                out.append(c)
                i += 1
            elif c == "#" and at_token_start:
                while i < n and cmd[i] != "\n":
                    i += 1
                at_token_start = True
            else:
                out.append(c)
                at_token_start = c in " \t\r\n;&|()"
                i += 1
    return "".join(out)


def has_unquoted_expansion(cmd):
    """True if `cmd` has unquoted `$(`, backticks, `<(`, `>(`, or `<<`."""
    i, n = 0, len(cmd)
    in_single = False
    in_double = False
    while i < n:
        c = cmd[i]
        if in_single:
            if c == "'":
                in_single = False
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if in_double:
            if c == '"':
                in_double = False
            elif c == "`" or (c == "$" and i + 1 < n and cmd[i + 1] == "("):
                return True
            i += 1
            continue
        if c == "'":
            in_single = True
        elif c == '"':
            in_double = True
        elif c == "`":
            return True
        elif c == "$" and i + 1 < n and cmd[i + 1] == "(":
            return True
        elif c in "<>" and i + 1 < n and cmd[i + 1] in "(<":
            return True
        i += 1
    return False


def split_shell_segments(cmd):
    """Split a comment-stripped command on unquoted `;`, `|`, `&`, `\n`, `(`, `)`."""
    segments, buf = [], []
    i, n = 0, len(cmd)
    in_single = False
    in_double = False
    while i < n:
        c = cmd[i]
        if in_single:
            buf.append(c)
            if c == "'":
                in_single = False
            i += 1
        elif in_double:
            buf.append(c)
            if c == "\\" and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == '"':
                in_double = False
            i += 1
        else:
            if c == "\\" and i + 1 < n:
                buf.append(c)
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == "'":
                in_single = True
                buf.append(c)
                i += 1
            elif c == '"':
                in_double = True
                buf.append(c)
                i += 1
            elif c in ";&|\n()":
                seg = "".join(buf).strip()
                if seg:
                    segments.append(seg)
                buf = []
                i += 1
            else:
                buf.append(c)
                i += 1
    seg = "".join(buf).strip()
    if seg:
        segments.append(seg)
    return segments


def option_value(tokens, i, short, long):
    """If tokens[i] is `-X v`, `-Xv`, `--long v`, or `--long=v`, return (v, tokens used); else (None, 0)."""
    arg = tokens[i]
    if arg in (short, long):
        return (tokens[i + 1] if i + 1 < len(tokens) else ""), 2
    if arg.startswith(long + "="):
        return arg.split("=", 1)[1], 1
    if arg.startswith(short) and not arg.startswith("--"):
        return arg[len(short):], 1
    return None, 0


def peel_wrappers(tokens):
    """Peel leading ENV=val assignments, shell keywords, and transparent command wrappers.
    `env -S <string>` is split in place (as `env` itself does) and `env -C <dir>` is recorded.
    Returns (env_dict, remaining_tokens, chdir); raises ValueError on an unbalanced `env -S` string."""
    tokens = list(tokens)
    env_vars = {}
    chdir = None
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if ENV_ASSIGN_RE.match(tok):
            k, v = tok.split("=", 1)
            env_vars[k] = v
            i += 1
            continue
        if tok in RESERVED_WORDS:
            i += 1
            continue
        base = os.path.basename(tok)
        if base not in TRANSPARENT_WRAPPERS:
            break
        if base == "command":
            j = i + 1
            while j < len(tokens) and tokens[j].startswith("-") and tokens[j] != "--":
                if "v" in tokens[j] or "V" in tokens[j]:
                    return env_vars, tokens[i:], chdir  # `command -v grok` only looks the name up
                j += 1
        i += 1
        while i < len(tokens):
            arg = tokens[i]
            if arg == "--":
                i += 1
                break
            if base == "env":
                if ENV_ASSIGN_RE.match(arg):
                    k, v = arg.split("=", 1)
                    env_vars[k] = v
                    i += 1
                    continue
                script, used = option_value(tokens, i, "-S", "--split-string")
                if script is not None:
                    tokens[i:i + used] = shlex.split(script)
                    continue
                directory, used = option_value(tokens, i, "-C", "--chdir")
                if directory is not None:
                    chdir = os.path.join(chdir, directory) if chdir else directory
                    i += used
                    continue
            if arg.startswith("-"):
                i += 2 if arg in WRAPPER_VALUE_OPTS.get(base, ()) else 1
                continue
            break
    return env_vars, tokens[i:], chdir


def next_cwd(cwd, builtin, args):
    """Directory after `cd`/`pushd`/`popd ARGS` run in `cwd`; None when it cannot be known statically."""
    if builtin == "popd":
        return None
    i = 0
    while i < len(args) and args[i].startswith("-") and args[i] != "-":
        if args[i] == "--":
            i += 1
            break
        if builtin == "pushd" and args[i] == "-n":
            return cwd  # only edits the directory stack
        i += 1
    if i >= len(args):
        # Bare `cd` goes home; bare `pushd` swaps the top two stack entries.
        return os.path.realpath(os.path.expanduser("~")) if builtin == "cd" else None
    target = os.path.expanduser(args[i])
    if target == "-" or "$" in target or target.startswith("+"):
        return None
    if not os.path.isabs(target):
        if cwd is None:
            return None
        target = os.path.join(cwd, target)
    return os.path.realpath(target)


def names_grok(tok):
    """True if `tok` is the grok binary or wrapper (`grok`, `~/.grok/bin/grok`, `G=grok`)."""
    m = ENV_ASSIGN_RE.match(tok)
    value = m.group(1) if m else tok
    return os.path.basename(value.rstrip("/")).lower() in GROK_NAMES


def string_runs_grok(text, depth=0):
    """True if `text`, read as a command line, starts a command with grok (`'grok -p x'`)."""
    if depth > 4:
        return True
    for seg in split_shell_segments(strip_posix_comments(text)):
        try:
            _, core, _ = peel_wrappers(shlex.split(seg, posix=True, comments=False))
        except ValueError:
            if GROK_WORD_RE.search(seg):
                return True
            continue
        if not core:
            continue
        exe = os.path.basename(core[0])
        if names_grok(core[0]) or (is_interpreter_binary(exe) and any(names_grok(t) for t in core[1:])):
            return True
        script = extract_shell_c_script(core) if exe in SHELL_BINARIES else None
        if script and string_runs_grok(script, depth + 1):
            return True
    return False


def token_runs_grok(tok):
    """True if an argument names grok, or is a quoted command line that runs it."""
    if names_grok(tok):
        return True
    return any(c in tok for c in " \t\n;&|") and string_runs_grok(tok)


def extract_shell_c_script(tokens):
    """If `tokens` is `bash -c <script> ...` / `sh -lc <script> ...`, return `<script>`."""
    if not tokens:
        return None
    base = os.path.basename(tokens[0])
    if base not in SHELL_BINARIES:
        return None
    i, n = 1, len(tokens)
    while i < n:
        tok = tokens[i]
        if tok == "--":
            return None
        if tok.startswith("-") and not tok.startswith("--"):
            flags = tok[1:]
            if "c" in flags:
                return tokens[i + 1] if i + 1 < n else ""
            if any(f in flags for f in ("o", "O")) and i + 1 < n:
                i += 2
                continue
            i += 1
            continue
        if tok in ("--login", "--norc", "--noprofile", "--posix"):
            i += 1
            continue
        if tok in ("--rcfile", "--init-file", "-o", "+o") and i + 1 < n:
            i += 2
            continue
        break
    return None


def is_interpreter_binary(exe):
    return (
        exe in INTERPRETER_BINARIES
        or exe.startswith(("python3.", "python2.", "perl5", "ruby2", "ruby3", "php7", "php8"))
    )


def is_trusted_worker_path(script_token, effective_cwd, project_root):
    """True only if `script_token` resolves to `<project_root>/.grok/grok-worker.py`.
    `effective_cwd` is None when an earlier `popd` / `cd -` made the directory unknowable."""
    expected = os.path.join(os.path.realpath(project_root), ".grok", "grok-worker.py")
    path = os.path.expanduser(script_token)
    if not os.path.isabs(path):
        if effective_cwd is None:
            return False
        path = os.path.join(effective_cwd, path)
    return os.path.realpath(path) == expected


def is_safe_direct_grok_discovery(argv):
    """True only for zero-cost local discovery calls (`grok models`, `grok inspect`,
    `grok --version`, `grok --help`). All headless / interactive / subcommand calls return False."""
    if not argv:
        return False
    first = argv[0]
    if first in ("--version", "-v", "version", "--help", "-h", "help"):
        return all(a in ("--version", "-v", "--help", "-h") for a in argv[1:])
    if first in ("models", "inspect"):
        return all(a in ("--help", "-h") for a in argv[1:])
    return False


def validate_worker_argv(argv, env_vars, effective_cwd, project_root):
    """Inspect a `grok-worker.py` argv list (excluding `python3` and `.grok/grok-worker.py`)
    started from `effective_cwd`. Returns a list of problems."""
    problems = []
    modes = []
    prompts = []
    has_prompt_file = False
    max_turns_vals = []
    wall_timeouts = []
    sandboxes = []
    cwds = []
    has_allow_shell = False
    has_worktree = False

    VALUE_OPTS = {
        "--mode", "-p", "--prompt", "--prompt-file", "--tier", "--effort",
        "--max-turns", "-m", "--model", "--sandbox", "--resume", "--wall-timeout", "--cwd",
    }
    FLAG_OPTS = {"--allow-shell", "--dry-run", "-h", "--help"}

    i, n = 0, len(argv)
    while i < n:
        tok = argv[i]
        if tok.startswith("-") and "=" in tok:
            opt, val = tok.split("=", 1)
        else:
            opt, val = tok, None

        if opt in FLAG_OPTS:
            if opt == "--allow-shell":
                has_allow_shell = True
            i += 1
            continue
        if opt == "--worktree":
            has_worktree = True
            if val is None and i + 1 < n and not argv[i + 1].startswith("-"):
                i += 1
            i += 1
            continue
        if opt in VALUE_OPTS:
            if val is None:
                if i + 1 < n:
                    val = argv[i + 1]
                    i += 1
                else:
                    val = ""
            if opt == "--mode":
                modes.append(val)
            elif opt in ("-p", "--prompt"):
                prompts.append(val)
            elif opt == "--prompt-file":
                has_prompt_file = bool(val)
            elif opt == "--max-turns":
                max_turns_vals.append(val)
            elif opt == "--wall-timeout":
                wall_timeouts.append(val)
            elif opt == "--sandbox":
                sandboxes.append(val)
            elif opt == "--cwd":
                cwds.append(val)
            i += 1
            continue
        problems.append(f"unrecognized or disallowed grok-worker.py argument: `{tok}`")
        i += 1

    # The worker treats its working directory (or the last `--cwd`) as the project to lock and edit.
    target = effective_cwd
    if cwds:
        target = next_cwd(effective_cwd, "cd", ["--", cwds[-1]])
    if target != os.path.realpath(project_root):
        problems.append(
            f"run `grok-worker.py` from the project root {os.path.realpath(project_root)} "
            f"(it would run in {target or 'an unknown directory'}); do not redirect it with `--cwd`, `cd`, or `pushd`"
        )

    if len(modes) != 1 or modes[0] not in ("read-only", "write"):
        problems.append("pass exactly one `--mode read-only` or `--mode write` to `grok-worker.py`")
        mode = None
    else:
        mode = modes[0]

    if not prompts and not has_prompt_file:
        problems.append("pass `-p \"<prompt>\"` or `--prompt-file TASK.md` to `grok-worker.py`")
    for p in prompts:
        if PAID_SLASH_RE.match(p):
            problems.append('do not run `/usage` or `/cost` via `grok-worker.py`: it is a paid model prompt')
            break

    for mt in max_turns_vals:
        try:
            v = int(mt)
        except ValueError:
            v = -1
        if not (1 <= v <= MAX_TURNS_LIMIT):
            problems.append(f"`--max-turns` must be between 1 and {MAX_TURNS_LIMIT} (got {mt!r})")

    for wt in wall_timeouts:
        try:
            v = int(wt)
        except ValueError:
            v = -1
        if not (1 <= v <= MAX_WALL_TIMEOUT_SEC):
            problems.append(f"`--wall-timeout` must be between 1 and {MAX_WALL_TIMEOUT_SEC} (got {wt!r})")

    env_sb = env_vars.get("GROK_SANDBOX")
    if mode == "read-only":
        for sb in sandboxes:
            if sb != "read-only":
                problems.append(
                    f"read-only mode requires `--sandbox read-only` (cannot downgrade sandbox to {sb!r})"
                )
        if env_sb is not None and env_sb.strip() != "read-only":
            problems.append(f"read-only mode conflicts with GROK_SANDBOX={env_sb!r}")
        if has_allow_shell:
            problems.append("`--allow-shell` cannot be used with `--mode read-only`")
        if has_worktree:
            problems.append("`--worktree` cannot be used with `--mode read-only`")
    else:
        for sb in sandboxes:
            if sb not in ALLOWED_WRITE_SANDBOXES:
                problems.append(
                    f"unsupported `--sandbox {sb}`; allowed in write mode: strict, workspace, read-only"
                )
        if env_sb is not None and env_sb.strip() not in ALLOWED_WRITE_SANDBOXES:
            problems.append(f"unsafe GROK_SANDBOX={env_sb!r}")

    return problems


def analyze_command(raw_cmd, project_root, cwd, depth=0):
    """Return `(found_headless, problems)` for `raw_cmd` run in `cwd` (None if unknown)."""
    if depth > 4:
        return True, ["nested shell `-c` wrapper depth exceeded; invoke `python3 .grok/grok-worker.py` directly"]

    stripped = strip_posix_comments(raw_cmd)
    mentions_grok = bool(GROK_WORD_RE.search(stripped))
    if mentions_grok and has_unquoted_expansion(stripped):
        return True, [
            "do not use command substitution `$(...)`, backticks, or process substitution "
            "in a command that runs grok; invoke `python3 .grok/grok-worker.py` directly"
        ]

    segments = split_shell_segments(stripped)
    found_any = False
    problems = []
    effective_cwd = cwd

    for seg in segments:
        try:
            tokens = shlex.split(seg, posix=True, comments=False)
            env_vars, core, chdir = peel_wrappers(tokens)
        except ValueError:
            if GROK_WORD_RE.search(seg):
                return True, ["unbalanced quotes in command invoking grok"]
            continue
        if not core:
            # A bare assignment such as `G=grok` sets up a later `$G -p ...`.
            if any(names_grok(t) for t in tokens):
                found_any = True
                problems.append("do not store grok in a variable; invoke `python3 .grok/grok-worker.py` directly")
            continue
        seg_cwd = effective_cwd if chdir is None else next_cwd(effective_cwd, "cd", ["--", chdir])
        exe = os.path.basename(core[0])

        # Track `cd` / `pushd` / `popd` across chained segments (e.g. `cd sub && ...`);
        # anything that cannot be resolved statically makes the directory unknown.
        if exe in ("cd", "pushd", "popd"):
            effective_cwd = next_cwd(seg_cwd, exe, core[1:])
            continue

        # 1. `eval` or `xargs` around grok
        if exe in ("eval", "xargs") and GROK_WORD_RE.search(seg):
            found_any = True
            problems.append(f"do not wrap grok in `{exe}`; invoke `python3 .grok/grok-worker.py` directly")
            continue

        # 2. Shell `-c` wrapper (`bash -c "..."`, `sh -c "..."`, `zsh -c "..."`)
        if exe in SHELL_BINARIES:
            script = extract_shell_c_script(core)
            if script is not None:
                sub_found, sub_problems = analyze_command(script, project_root, seg_cwd, depth + 1)
                if sub_found:
                    found_any = True
                    problems.extend(sub_problems)
            elif GROK_WORD_RE.search(seg):
                found_any = True
                problems.append(
                    f"do not wrap grok in `{exe}` without a static command; "
                    "invoke `python3 .grok/grok-worker.py` directly"
                )
            continue

        # 3. `python3 .grok/grok-worker.py ...` or other interpreter invocations
        if is_interpreter_binary(exe):
            idx = 1
            if exe in ("python", "python3") or exe.startswith("python3."):
                while idx < len(core) and core[idx] in ("-u", "-B", "-E", "-I", "-s", "-S"):
                    idx += 1
                if idx < len(core) and os.path.basename(core[idx]) == "grok-worker.py":
                    found_any = True
                    if not is_trusted_worker_path(core[idx], seg_cwd, project_root):
                        problems.append(
                            f"untrusted wrapper path `{core[idx]}`; only the project's "
                            "`.grok/grok-worker.py` may be executed"
                        )
                    problems.extend(validate_worker_argv(core[idx + 1:], env_vars, seg_cwd, project_root))
                    continue
            # Any other interpreter invocation (`python3 -c`, `node -e`, `python3 /tmp/foo.py`, etc.)
            # that mentions `grok` or `grok-worker` is an indirect bypass attempt.
            if GROK_WORD_RE.search(seg):
                found_any = True
                problems.append(
                    f"do not invoke grok indirectly via `{exe}` (e.g. `{exe} -c` or external script); "
                    "run `python3 .grok/grok-worker.py --mode <read-only|write> ...` directly"
                )
            continue

        # 4. Direct `./.grok/grok-worker.py ...` or `/tmp/grok-worker.py ...`
        if exe == "grok-worker.py":
            found_any = True
            if not is_trusted_worker_path(core[0], seg_cwd, project_root):
                problems.append(
                    f"untrusted wrapper path `{core[0]}`; only the project's "
                    "`.grok/grok-worker.py` may be executed"
                )
            problems.extend(validate_worker_argv(core[1:], env_vars, seg_cwd, project_root))
            continue

        # 5. Direct `grok` binary: only zero-cost local discovery subcommands (`grok models`,
        #    `grok inspect`, `grok --version`, `grok --help`) are allowed; all headless or
        #    other direct calls are rejected so the wrapper's wall-clock timeout, atomic flock,
        #    worktree permissions, and forced sandbox cannot be bypassed.
        if exe.lower() in ("grok", "grok.exe"):
            if is_safe_direct_grok_discovery(core[1:]):
                continue
            found_any = True
            problems.append(
                "do not invoke `grok` directly for tasks; always run "
                "`python3 .grok/grok-worker.py --mode <read-only|write> --tier <1|2|3> -p \"<prompt>\"` "
                "so wall-clock timeout, atomic flock, worktree permissions, and forced sandbox are enforced"
            )
            continue

        # 6. Any other command that is handed grok (`timeout 60 grok`, `sudo grok`, `find -exec grok`,
        #    `watch 'grok -p x'`, `export G=grok`) could start it without the wrapper.
        if exe not in INERT_COMMANDS and any(token_runs_grok(t) for t in core):
            found_any = True
            problems.append(
                f"do not run grok through `{exe}`; invoke "
                "`python3 .grok/grok-worker.py --mode <read-only|write> ...` directly"
            )

    return found_any, problems


def pid_is_live_grok(pid):
    """True if `pid` is alive and its executable is `grok` or `python*`."""
    if not isinstance(pid, int) or pid <= 1 or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    try:
        comm = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        base = os.path.basename(comm).lower()
        return base.startswith("grok") or base.startswith("python")
    except Exception:
        return True


def grok_lock_active(project_dir):
    """Check the file-free project lock, then the legacy write-worker lock."""
    project_dir = os.path.realpath(project_dir)
    try:
        directory_fd = os.open(project_dir, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        directory_fd = None
    if directory_fd is not None:
        try:
            try:
                fcntl.flock(directory_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                if e.errno in (errno.EACCES, errno.EAGAIN):
                    return True
        finally:
            os.close(directory_fd)
    lock_path = os.path.join(project_dir, ".grok", "worker.lock")
    if not os.path.exists(lock_path):
        return False
    try:
        fd = os.open(lock_path, os.O_RDONLY)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            if e.errno in (errno.EACCES, errno.EAGAIN):
                return True
        else:
            try:
                raw = os.read(fd, 4096).decode("utf-8", errors="replace")
            except OSError:
                raw = ""
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                data = json.loads(raw)
            except Exception:
                return False
            if data.get("active") is False:
                return False
            return pid_is_live_grok(data.get("pid")) or pid_is_live_grok(data.get("child_pid"))
        return False
    finally:
        os.close(fd)


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(event, dict) or event.get("tool_name") != "Bash":
        return 0
    tool_input = event.get("tool_input") or {}
    command = tool_input.get("command") or ""
    if not command:
        return 0

    project_cwd = os.path.realpath(event.get("cwd") or tool_input.get("cwd") or os.getcwd())
    found_headless, problems = analyze_command(command, project_cwd, project_cwd)
    if not found_headless:
        return 0

    background = tool_input.get("run_in_background") is True
    try:
        timeout = int(tool_input.get("timeout") or 0)
    except (TypeError, ValueError):
        timeout = 0
    if not background and timeout < MIN_TIMEOUT_MS:
        problems.append(
            f"use `run_in_background: true` or set the Bash tool `timeout` to {MIN_TIMEOUT_MS} "
            "(grok prints nothing until it finishes)"
        )

    if grok_lock_active(project_cwd):
        problems.append(
            "another headless grok worker holds the project directory or `.grok/worker.lock` lock; "
            "wait for it to finish and check `git status` before retrying"
        )

    if problems:
        deduped = list(dict.fromkeys(problems))
        sys.stderr.write("grok-guard blocked this call:\n- " + "\n- ".join(deduped) + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
