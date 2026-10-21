#!/usr/bin/env python3
"""Safe CLI wrapper for headless Grok Build (`grok`) invocations.

Why use a wrapper instead of raw shell commands?
  1. Controls the real `argv` passed to `execve` (`shell=False`), so shell comments (`#`),
     command substitution, and `bash -c` tricks can never strip or spoof safety flags.
  2. Enforces task-scoped toolsets and OS sandboxes:
     - `--mode read-only`: `--tools read_file,grep,list_dir`, disables write/edit/shell/subagent
       tools, and strictly requires `--sandbox read-only` (cannot be downgraded to `workspace`
       or `strict`).
     - `--mode write`: disables `run_terminal_cmd` by default (unless `--allow-shell` is passed
       and `.grok/config.toml` has an explicit `Bash(...)` allow rule), runs under
       `--sandbox strict` (or `workspace` / `read-only`), and provisions isolated git worktree
       permissions before launching `grok`.
  3. Enforces both a bounded `--max-turns` (1..120) and a real wall-clock timeout
     (`--wall-timeout`, default 540s) that kills the entire child process group (`os.killpg`).
  4. Serializes runs with an atomic directory lock (`fcntl.flock`) without creating files for
     read-only tasks. Write tasks also keep the persistent `<project>/.grok/worker.lock` inode.
  5. If the wrapper itself is killed (even with SIGKILL), a watchdog in its own session ends
     `grok`'s process group and keeps the project locked until it is gone.
"""
import argparse
import errno
import fcntl
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

try:
    import tomllib
except ImportError:
    tomllib = None

MAX_TURNS_LIMIT = 120
MAX_WALL_TIMEOUT_SEC = 3600
DEFAULT_WALL_TIMEOUT_SEC = 540

TIER_DEFAULTS = {
    1: ("low", 30),
    2: ("medium", 60),
    3: ("high", 100),
}

VALID_EFFORTS = ("none", "minimal", "low", "medium", "high", "xhigh", "max")
ALLOWED_WRITE_SANDBOXES = ("strict", "workspace", "read-only")
READ_ONLY_TOOLS = "read_file,grep,list_dir"
READ_ONLY_DISALLOWED = "run_terminal_cmd,write,search_replace,StrReplace,EditNotebook,Delete,Agent"
PAID_SLASH_RE = re.compile(r"^\s*/(?:usage|cost)(?:\s|$)", re.I)


def die(msg, code=2):
    sys.stderr.write(f"grok-worker error: {msg}\n")
    sys.exit(code)


def grok_home_dir():
    return os.environ.get("GROK_HOME") or os.path.expanduser("~/.grok")


def parse_trusted_folders(text):
    """Parse `trusted_folders.toml` and return `{folder_path: bool}`."""
    if tomllib is not None:
        data = tomllib.loads(text)
        folders = data.get("folders", {})
        if not isinstance(folders, dict):
            raise ValueError("'folders' in trusted_folders.toml must be a table")
        out = {}
        for k, v in folders.items():
            if isinstance(v, dict) and "trusted" in v:
                if not isinstance(v["trusted"], bool):
                    raise ValueError(f"folders.{k!r}.trusted must be a boolean")
                out[k] = v["trusted"]
        return out

    # Fallback parser for Python 3.9/3.10 where tomllib is not in stdlib.
    out = {}
    current_folder = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            if not line.endswith("]"):
                raise ValueError(f"unclosed table header: {raw_line!r}")
            inner = line[1:-1].strip()
            m = re.match(r'^folders\s*\.\s*("(?:[^"\\]|\\.)*"|\'[^\']*\')\s*$', inner)
            if m:
                tok = m.group(1)
                current_folder = json.loads(tok) if tok.startswith('"') else tok[1:-1]
            else:
                current_folder = None
            continue
        if current_folder is not None:
            m = re.match(r"^trusted\s*=\s*(true|false)\s*(?:#.*)?$", line)
            if m:
                out[current_folder] = (m.group(1) == "true")
            elif re.match(r"^trusted\s*=", line):
                raise ValueError(f"invalid boolean for trusted: {raw_line!r}")
    return out


def check_or_register_trust(folder_path, register_if_missing=False):
    """Check `trusted_folders.toml` for `folder_path`.
    If explicitly `trusted = false`, abort. If `register_if_missing` is True, add `trusted = true`.
    """
    trust_file = os.path.join(grok_home_dir(), "trusted_folders.toml")
    text = ""
    folders = {}
    if os.path.exists(trust_file):
        try:
            with open(trust_file, encoding="utf-8-sig") as f:
                text = f.read()
            folders = parse_trusted_folders(text)
        except Exception as e:
            die(f"could not parse {trust_file}: {e}")

    real_path = os.path.realpath(folder_path).rstrip("/")
    for candidate in dict.fromkeys([real_path, folder_path.rstrip("/")]):
        if candidate in folders and folders[candidate] is False:
            die(
                f"folder {candidate!r} is explicitly marked `trusted = false` in {trust_file}; "
                "preserving user decision (authorize manually before running headless grok)"
            )

    if register_if_missing and folders.get(real_path) is not True:
        os.makedirs(os.path.dirname(trust_file), exist_ok=True)
        header = f"[folders.{json.dumps(real_path, ensure_ascii=False)}]"
        nl = "\r\n" if "\r\n" in text else "\n"
        body = text
        if body and not body.endswith(("\n", "\r\n")):
            body += nl
        if body:
            body += nl
        body += f"{header}{nl}trusted = true{nl}decided_at = {int(time.time())}{nl}"
        tmp = trust_file + f".tmp-{os.getpid()}"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(body)
        os.replace(tmp, trust_file)


def find_git_main_repo(work_dir):
    """If `work_dir` is a linked Git worktree, return the physical path of the main repository."""
    dot_git = os.path.join(work_dir, ".git")
    if os.path.isfile(dot_git):
        try:
            content = open(dot_git, encoding="utf-8").read().strip()
        except OSError:
            content = ""
        if content.startswith("gitdir:"):
            gitdir = content[len("gitdir:"):].strip()
            if not os.path.isabs(gitdir):
                gitdir = os.path.normpath(os.path.join(work_dir, gitdir))
            commondir_file = os.path.join(gitdir, "commondir")
            if os.path.isfile(commondir_file):
                try:
                    rel_common = open(commondir_file, encoding="utf-8").read().strip()
                    common_git = os.path.realpath(os.path.join(gitdir, rel_common))
                    if os.path.basename(common_git) == ".git":
                        return os.path.realpath(os.path.dirname(common_git))
                except OSError:
                    pass
            # Fallback: <main_repo>/.git/worktrees/<name>
            parent = os.path.dirname(gitdir)
            if os.path.basename(parent) == "worktrees":
                common_git = os.path.dirname(parent)
                if os.path.basename(common_git) == ".git":
                    return os.path.realpath(os.path.dirname(common_git))
    return None


def git_output(directory, *args):
    """Run a read-only Git query without refreshing the index on disk."""
    try:
        res = subprocess.run(
            ["git", "-C", directory, *args], capture_output=True, timeout=30,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
    except (OSError, subprocess.SubprocessError) as e:
        die(f"could not verify Git repository at {directory!r}: {e}")
    if res.returncode != 0:
        die(f"could not verify Git repository at {directory!r}: {os.fsdecode(res.stderr).strip()}")
    return res.stdout


def validate_worktree(source_repo_dir, worktree_dir, isolated=False):
    """Require the same Git common directory AND an exact registered physical path."""
    src_real = os.path.realpath(source_repo_dir)
    wt_real = os.path.realpath(worktree_dir)

    def common_dir(directory):
        common = os.fsdecode(git_output(directory, "rev-parse", "--git-common-dir")).rstrip("\n")
        return os.path.realpath(os.path.join(directory, common))

    if common_dir(src_real) != common_dir(wt_real):
        die(f"worktree {wt_real!r} must belong to the same repository as {src_real!r}")
    # -z avoids Git's quoted path syntax and handles whitespace/newlines in paths.
    records = git_output(src_real, "worktree", "list", "--porcelain", "-z")
    registered = {
        os.path.realpath(os.fsdecode(field[len(b"worktree "):]))
        for field in records.split(b"\0") if field.startswith(b"worktree ")
    }
    if wt_real not in registered:
        die(f"{wt_real!r} is not a registered worktree of {src_real!r}")
    if isolated and wt_real == src_real:
        die("--worktree must select an isolated worktree, not the source working directory")
    return wt_real


def resolve_existing_worktree(project_dir, wt_arg):
    if wt_arg == "__AUTO__":
        return None
    candidate = os.path.abspath(os.path.join(project_dir, wt_arg))
    if os.path.lexists(candidate):
        return validate_worktree(project_dir, candidate, isolated=True)
    return None


def existing_worktree_config(worktree_dir, source_repo_dir=None):
    """Validate an existing config without rewriting or broadening any of its rules."""
    grok_dir = os.path.join(worktree_dir, ".grok")
    if os.path.commonpath([worktree_dir, os.path.realpath(grok_dir)]) != worktree_dir:
        die(f"worktree configuration directory escapes the worktree: {grok_dir}")
    config = os.path.join(grok_dir, "config.toml")
    if not os.path.lexists(config):
        return False
    if os.path.islink(config) or not os.path.isfile(config):
        die(f"existing worktree config must be a regular file, not a symlink: {config}")
    if tomllib is None:
        # Without a TOML parser, accept only the exact config this wrapper provisions from the source.
        try:
            with open(config, encoding="utf-8", newline="") as f:
                own = source_repo_dir is not None and f.read() == inherited_config_text(
                    source_repo_dir, worktree_dir, required=False)
        except (OSError, UnicodeError):
            own = False
        if own:
            return True
        die(f"cannot safely validate existing worktree config {config}; use Python 3.11+ (file preserved)")
    try:
        with open(config, encoding="utf-8-sig") as f:
            parsed = tomllib.loads(f.read())
        permission = parsed.get("permission", {})
        if not isinstance(permission, dict):
            raise ValueError("permission must be a table")
        for key in ("allow", "deny", "ask"):
            if key in permission and (
                not isinstance(permission[key], list)
                or not all(isinstance(rule, str) for rule in permission[key])
            ):
                raise ValueError(f"permission.{key} must be an array of strings")
    except (OSError, ValueError) as e:
        die(f"cannot safely use existing worktree config {config}: {e} (file preserved)")
    return True


def inherited_config_text(source_repo_dir, worktree_dir, required=True):
    """Return the source config with its Write/Edit allow rules retargeted at `worktree_dir`.
    If the source config is missing or lacks those rules, die (or return None if not `required`)."""
    src_real = os.path.realpath(source_repo_dir).rstrip("/")
    wt_real = os.path.realpath(worktree_dir).rstrip("/")
    src_cfg = os.path.join(src_real, ".grok", "config.toml")
    if not os.path.isfile(src_cfg):
        if not required:
            return None
        die(
            f"cannot provision worktree {wt_real}: source repository is missing {src_cfg} "
            "(run `bash setup-grok.sh` in the main repository first)"
        )
    try:
        with open(src_cfg, encoding="utf-8-sig") as f:
            src_text = f.read()
    except (OSError, UnicodeError) as e:
        if not required:
            return None
        die(f"could not read {src_cfg}: {e}")

    # Rewrite the source repo's Write/Edit allow rules to target the worktree's physical path.
    wt_text = src_text.replace(f"Write({src_real}/**)", f"Write({wt_real}/**)").replace(
        f"Edit({src_real}/**)", f"Edit({wt_real}/**)"
    )
    if f"Write({wt_real}/**)" not in wt_text or f"Edit({wt_real}/**)" not in wt_text:
        if not required:
            return None
        die(f"source {src_cfg} does not contain expected Write/Edit allow rules for {src_real}")
    return wt_text


def worktree_config_text(source_repo_dir, worktree_dir):
    """Return inherited config only if the worktree has none; otherwise preserve it."""
    src_real = os.path.realpath(source_repo_dir).rstrip("/")
    wt_real = os.path.realpath(worktree_dir).rstrip("/")
    check_or_register_trust(src_real, register_if_missing=False)
    check_or_register_trust(wt_real, register_if_missing=False)
    if existing_worktree_config(wt_real, src_real):
        return None
    return inherited_config_text(src_real, wt_real)


def provision_worktree_permissions(source_repo_dir, worktree_dir):
    """Provision permissions only after proving repository membership and checking trust."""
    wt_real = validate_worktree(source_repo_dir, worktree_dir)
    wt_text = worktree_config_text(source_repo_dir, wt_real)
    wt_grok_dir = os.path.join(wt_real, ".grok")
    if os.path.commonpath([wt_real, os.path.realpath(wt_grok_dir)]) != wt_real:
        die(f"worktree configuration directory escapes the worktree: {wt_grok_dir}")
    os.makedirs(wt_grok_dir, exist_ok=True)
    wt_gitignore = os.path.join(wt_grok_dir, ".gitignore")
    if not os.path.exists(wt_gitignore):
        with open(wt_gitignore, "w", encoding="utf-8") as f:
            f.write("*\n")

    if wt_text is not None:
        wt_cfg = os.path.join(wt_grok_dir, "config.toml")
        fd, tmp_cfg = tempfile.mkstemp(prefix="config-", suffix=".tmp", dir=wt_grok_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                f.write(wt_text)
            try:
                # Atomic create-only publish: a config that appears during initialization wins.
                os.link(tmp_cfg, wt_cfg)
            except FileExistsError:
                existing_worktree_config(wt_real, source_repo_dir)
        finally:
            os.unlink(tmp_cfg)

    check_or_register_trust(wt_real, register_if_missing=True)
    return wt_real


def create_or_resolve_worktree(project_dir, wt_arg, grok_bin):
    """Create or locate an isolated worktree for `--worktree` and provision its `.grok/config.toml`."""
    existing = resolve_existing_worktree(project_dir, wt_arg)
    if existing is not None:
        return provision_worktree_permissions(project_dir, existing)

    # 1. Try `grok worktree create [name]` (creates the worktree the way `grok -w` does).
    cmd = [grok_bin, "worktree", "create"]
    if wt_arg != "__AUTO__":
        cmd.append(wt_arg)
    try:
        res = subprocess.run(cmd, cwd=project_dir, capture_output=True, text=True, timeout=30)
        if res.returncode == 0 and res.stdout.strip():
            last_line = os.path.join(project_dir, res.stdout.strip().splitlines()[-1].strip())
            if os.path.isdir(last_line):
                validate_worktree(project_dir, last_line, isolated=True)
                return provision_worktree_permissions(project_dir, last_line)
    except (OSError, subprocess.SubprocessError):
        pass

    # 2. Fallback to standard `git worktree add --detach` inside `<project>/.grok/worktrees/<label>`.
    # Unlike Grok's native creation, this cannot carry dirty changes. Fail rather than lose context.
    if git_output(project_dir, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"):
        die(
            "Grok worktree creation failed or returned no usable path; Git fallback refuses "
            "uncommitted or untracked changes because it would create a clean HEAD worktree. "
            "Create a worktree containing the required changes and pass its path to --worktree."
        )
    label = f"wt-{int(time.time())}" if wt_arg == "__AUTO__" else re.sub(r"[^A-Za-z0-9._-]", "-", wt_arg)
    if label in (".", ".."):
        die(f"invalid --worktree name: {wt_arg!r}")
    wt_base = os.path.join(project_dir, ".grok", "worktrees")
    os.makedirs(wt_base, exist_ok=True)
    wt_dest = os.path.join(wt_base, label)
    if os.path.lexists(wt_dest):
        validate_worktree(project_dir, wt_dest, isolated=True)
    else:
        res = subprocess.run(
            ["git", "worktree", "add", "--detach", wt_dest, "HEAD"],
            cwd=project_dir,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if res.returncode != 0:
            die(f"failed to create git worktree {wt_dest!r}: {res.stderr.strip() or res.stdout.strip()}")
    return provision_worktree_permissions(project_dir, wt_dest)


def read_project_prompt(project_dir, prompt_path):
    """Read only a regular file inside the project, with no symlink races during traversal."""
    real_path = os.path.realpath(prompt_path)
    if os.path.commonpath([project_dir, real_path]) != project_dir:
        die(f"--prompt-file must stay inside the authorized project {project_dir}: {prompt_path}")
    fd = None
    try:
        fd = os.open(project_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parts = os.path.relpath(real_path, project_dir).split(os.sep)
        for part in parts[:-1]:
            child_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child_fd
        prompt_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(prompt_fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                die(f"--prompt-file must be a regular file inside the project: {prompt_path}")
            return f.read()
    except OSError as e:
        die(f"could not safely read --prompt-file inside the project: {e}")
    finally:
        if fd is not None:
            os.close(fd)


def stage_worktree_prompt(argv, worktree_dir, content):
    """Give the worker an independent prompt inside its sandbox; never overwrite TASK.md."""
    index = argv.index("--prompt-file") + 1
    source = argv[index]
    # Grok treats .json prompt files as content blocks, so keep the input format.
    suffix = os.path.splitext(source)[1] or ".md"
    snapshot = None
    try:
        fd, snapshot = tempfile.mkstemp(
            prefix="worker-prompt-", suffix=suffix, dir=os.path.join(worktree_dir, ".grok"),
        )
        with os.fdopen(fd, "wb") as dst:
            dst.write(content)
    except OSError as e:
        if snapshot is not None:
            os.unlink(snapshot)
        die(f"could not stage --prompt-file in worktree: {e}")
    argv[index] = snapshot
    return snapshot


def has_bash_allow_rule(project_dir):
    """True if <project>/.grok/config.toml contains at least one Bash(...) allow rule."""
    cfg = os.path.join(project_dir, ".grok", "config.toml")
    if not os.path.exists(cfg):
        return False
    try:
        text = open(cfg, encoding="utf-8-sig").read()
    except OSError:
        return False
    if tomllib is not None:
        try:
            allow = tomllib.loads(text).get("permission", {}).get("allow", [])
            return any(isinstance(r, str) and r.startswith("Bash") for r in allow)
        except Exception:
            return False
    # Python < 3.11: find the [permission] table's `allow = [...]` array, inline or multi-line.
    table = re.search(r"^\s*\[permission\]\s*$(.*?)(?=^\s*\[|\Z)", text, re.M | re.S)
    allow = table and re.search(r"^\s*allow\s*=\s*\[(.*?)\]\s*$", table.group(1), re.M | re.S)
    return bool(allow) and any(
        rule.startswith("Bash") for rule in re.findall(r'"((?:[^"\\]|\\.)*)"', allow.group(1))
    )


def build_parser():
    p = argparse.ArgumentParser(
        prog="grok-worker.py",
        description="Safe argv-enforcing wrapper for headless Grok Build (`grok`).",
    )
    p.add_argument(
        "--mode",
        required=True,
        choices=("read-only", "write"),
        help="Task mode: 'read-only' (locks tools + read-only sandbox) or 'write' (strict sandbox).",
    )
    prompt_group = p.add_mutually_exclusive_group(required=True)
    prompt_group.add_argument("-p", "--prompt", help="Single-turn prompt text.")
    prompt_group.add_argument("--prompt-file", help="Prompt file inside --cwd's project (symlink escapes and external paths are rejected).")
    p.add_argument(
        "--tier",
        type=int,
        choices=(1, 2, 3),
        default=1,
        help="Workload tier (sets default --effort and --max-turns: 1=low/30, 2=medium/60, 3=high/100).",
    )
    p.add_argument("--effort", choices=VALID_EFFORTS, help="Override reasoning effort level.")
    p.add_argument("--max-turns", type=int, help=f"Override turn cap (1..{MAX_TURNS_LIMIT}).")
    p.add_argument("-m", "--model", help="Optional model ID from `grok models`.")
    p.add_argument(
        "--sandbox",
        help="Sandbox profile ('read-only' required for read-only mode; 'strict'/'workspace'/'read-only' for write mode).",
    )
    p.add_argument(
        "--worktree",
        nargs="?",
        const="__AUTO__",
        help="Run write task in an isolated git worktree with provisioned .grok/config.toml.",
    )
    p.add_argument("--resume", help="Resume an existing session by sessionId.")
    p.add_argument(
        "--allow-shell",
        action="store_true",
        help="Allow the shell tool in write mode (requires a Bash(...) allow rule in .grok/config.toml).",
    )
    p.add_argument(
        "--wall-timeout",
        type=int,
        default=DEFAULT_WALL_TIMEOUT_SEC,
        help=f"Wall-clock timeout in seconds (1..{MAX_WALL_TIMEOUT_SEC}, default {DEFAULT_WALL_TIMEOUT_SEC}).",
    )
    p.add_argument("--cwd", default=os.getcwd(), help="Project working directory.")
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate and print the execution plan as JSON without creating files, granting trust, or starting grok.",
    )
    return p


def build_grok_argv(args, project_dir, config_source=None):
    default_effort, default_turns = TIER_DEFAULTS[args.tier]
    effort = args.effort or default_effort
    max_turns = args.max_turns if args.max_turns is not None else default_turns

    if not (1 <= max_turns <= MAX_TURNS_LIMIT):
        die(f"--max-turns must be between 1 and {MAX_TURNS_LIMIT} (got {max_turns})")
    if not (1 <= args.wall_timeout <= MAX_WALL_TIMEOUT_SEC):
        die(f"--wall-timeout must be between 1 and {MAX_WALL_TIMEOUT_SEC} seconds (got {args.wall_timeout})")

    prompt_content = None
    if args.prompt is not None:
        if not args.prompt.strip():
            die("prompt must not be empty")
        if PAID_SLASH_RE.match(args.prompt):
            die('do not run `/usage` or `/cost` in headless mode: grok sends it to the model as a paid prompt')
        prompt_flags = ["-p", args.prompt]
    else:
        prompt_path = os.path.abspath(os.path.join(project_dir, args.prompt_file))
        prompt_content = read_project_prompt(project_dir, prompt_path)
        try:
            first_line = prompt_content.decode("utf-8").split("\n", 1)[0]
        except UnicodeError as e:
            die(f"could not read --prompt-file: {e}")
        if PAID_SLASH_RE.match(first_line):
            die('do not run `/usage` or `/cost` via --prompt-file: grok sends it to the model as a paid prompt')
        prompt_flags = ["--prompt-file", prompt_path]

    env_sandbox = os.environ.get("GROK_SANDBOX")
    if args.mode == "read-only":
        sandbox = args.sandbox if args.sandbox is not None else "read-only"
        if sandbox != "read-only":
            die("read-only mode requires `--sandbox read-only` (cannot downgrade OS sandbox in read-only mode)")
        if env_sandbox is not None and env_sandbox.strip() != "read-only":
            die(f"read-only mode conflicts with environment GROK_SANDBOX={env_sandbox!r}")
        if args.allow_shell:
            die("--allow-shell cannot be used with --mode read-only")
        if args.worktree is not None:
            die("--worktree cannot be used with --mode read-only")
        tool_flags = [
            "--tools", READ_ONLY_TOOLS,
            "--disallowed-tools", READ_ONLY_DISALLOWED,
        ]
    else:
        sandbox = args.sandbox if args.sandbox is not None else "strict"
        if sandbox not in ALLOWED_WRITE_SANDBOXES:
            die(
                f"unsupported --sandbox {sandbox!r} in write mode; "
                f"allowed profiles: {', '.join(ALLOWED_WRITE_SANDBOXES)}"
            )
        if env_sandbox is not None and env_sandbox.strip() not in ALLOWED_WRITE_SANDBOXES:
            die(f"unsafe environment GROK_SANDBOX={env_sandbox!r}")
        if args.worktree is not None and args.worktree != "__AUTO__" and args.worktree.startswith("-"):
            die(f"invalid --worktree name: {args.worktree!r}")
        if args.allow_shell:
            if not has_bash_allow_rule(config_source or project_dir):
                die(
                    "--allow-shell requires at least one 'Bash(...)' rule in "
                    f"{os.path.join(project_dir, '.grok', 'config.toml')} under [permission] allow"
                )
            tool_flags = []
        else:
            tool_flags = ["--disallowed-tools", "run_terminal_cmd"]

    grok_bin = shutil.which("grok") or "grok"
    argv = [
        grok_bin,
        *prompt_flags,
        "--output-format", "json",
        "--permission-mode", "dontAsk",
        "--max-turns", str(max_turns),
        "--effort", effort,
        "--sandbox", sandbox,
        *tool_flags,
    ]
    if args.model:
        if args.model.startswith("-"):
            die(f"invalid --model value: {args.model!r}")
        argv.extend(["-m", args.model])
    if args.resume:
        if args.resume.startswith("-"):
            die(f"invalid --resume value: {args.resume!r}")
        argv.extend(["--resume", args.resume])
    return argv, sandbox, grok_bin, prompt_content


def write_lock_state(fd, state):
    if fd is None:
        return
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, (json.dumps(state) + "\n").encode("utf-8"))
    try:
        os.fsync(fd)
    except OSError:
        pass


def read_lock_holder(lock_path):
    try:
        with open(lock_path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def acquire_worker_locks(project_dir, mode):
    """Share a directory admission lock across modes; read-only never creates project files."""
    directory_fd = None
    worker_fd = None
    lock_path = os.path.join(project_dir, ".grok", "worker.lock")
    try:
        directory_fd = os.open(project_dir, os.O_RDONLY | os.O_DIRECTORY)
        fcntl.flock(directory_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if mode == "write":
            grok_dir = os.path.dirname(lock_path)
            os.makedirs(grok_dir, exist_ok=True)
            gitignore_path = os.path.join(grok_dir, ".gitignore")
            if not os.path.exists(gitignore_path):
                with open(gitignore_path, "w", encoding="utf-8") as f:
                    f.write("*\n")
            worker_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        elif os.path.isfile(lock_path):
            # Coordinate with an already-running older wrapper without modifying its state.
            worker_fd = os.open(lock_path, os.O_RDONLY)
        if worker_fd is not None:
            fcntl.flock(worker_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return directory_fd, worker_fd
    except OSError as e:
        for fd in (worker_fd, directory_fd):
            if fd is not None:
                os.close(fd)
        if e.errno in (errno.EACCES, errno.EAGAIN):
            holder = read_lock_holder(lock_path)
            die(
                f"another headless grok worker is already running in {project_dir} "
                f"(pid={holder.get('pid')}, child_pid={holder.get('child_pid')}, mode={holder.get('mode')}); "
                "wait for it to finish and check `git status` before retrying"
            )
        die(f"could not acquire worker lock for {project_dir}: {e}")


def kill_process_group(pgid):
    """Terminate the entire process group gracefully, then forcefully."""
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        pass
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return
        except OSError:
            break
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass


def start_watchdog():
    """Fork a watchdog that ends grok's process group if this wrapper dies without cleaning up.

    It runs in its own session, so a SIGKILL aimed at the wrapper or its process group leaves it
    alive, and it shares the wrapper's lock descriptors, so the project stays locked until grok is
    gone. The wrapper writes grok's pgid, then `done` once grok has exited; EOF without `done`
    means the wrapper vanished mid-run. Returns (lifeline write fd, watchdog pid).
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid:
        os.close(read_fd)
        return write_fd, pid
    try:
        os.close(write_fd)
        os.setsid()
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_DFL)
        # Never hold the caller's stdout/stderr open, or the Bash tool would wait on the watchdog.
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        message = b""
        while True:
            chunk = os.read(read_fd, 64)
            if not chunk:
                break
            message += chunk
        words = message.split()
        if words and words[-1] != b"done":
            kill_process_group(int(words[0]))
    finally:
        os._exit(0)


def stop_watchdog(lifeline, watchdog_pid):
    """Tell the watchdog that grok has exited, then reap it."""
    try:
        os.write(lifeline, b"done\n")
    except OSError:
        pass
    os.close(lifeline)
    try:
        os.waitpid(watchdog_pid, 0)
    except ChildProcessError:
        pass


def main():
    parser = build_parser()
    args = parser.parse_args()
    project_dir = os.path.realpath(args.cwd)
    if not os.path.isdir(project_dir):
        die(f"working directory does not exist: {project_dir}")

    # If `project_dir` is a linked Git worktree without its own `.grok/config.toml`,
    # plan inheritance now; defer all provisioning until arguments are valid and dry-run has returned.
    config_source = project_dir
    cfg_path = os.path.join(project_dir, ".grok", "config.toml")
    if args.mode == "write" and not os.path.isfile(cfg_path):
        main_repo = find_git_main_repo(project_dir)
        if main_repo and os.path.isfile(os.path.join(main_repo, ".grok", "config.toml")):
            validate_worktree(main_repo, project_dir)
            config_source = main_repo

    check_or_register_trust(project_dir, register_if_missing=False)
    wt_preview = None
    effective_config = config_source
    if args.mode == "write" and args.worktree is not None:
        wt_preview = resolve_existing_worktree(project_dir, args.worktree)
        if wt_preview is not None and existing_worktree_config(wt_preview, config_source):
            effective_config = wt_preview
    argv, sandbox, grok_bin, prompt_content = build_grok_argv(args, project_dir, config_source=effective_config)
    if config_source != project_dir:
        worktree_config_text(config_source, project_dir)
    if wt_preview is not None:
        worktree_config_text(config_source, wt_preview)
    elif args.worktree is not None:
        # A new worktree inherits this project's config: check it now, before any side effect.
        inherited_config_text(config_source, project_dir)
    lock_path = project_dir if args.mode == "read-only" else os.path.join(project_dir, ".grok", "worker.lock")

    if args.dry_run:
        operations = []
        if config_source != project_dir:
            operations.append("inherit project worktree config and register trust")
        if args.worktree is not None:
            wt_preview = wt_preview or f"<worktree:{args.worktree}>"
            operations.append("resolve/create registered worktree; preserve existing config, otherwise inherit config; register trust; Git fallback requires a clean source")
            if args.prompt_file is not None:
                index = argv.index("--prompt-file") + 1
                operations.append(f"copy prompt from {argv[index]} into the worktree; remove snapshot after execution")
                suffix = os.path.splitext(argv[index])[1] or ".md"
                argv[index] = os.path.join(wt_preview, ".grok", f"<prompt-snapshot>{suffix}")
        print(json.dumps({
            "argv": argv,
            "cwd": wt_preview or project_dir,
            "project_dir": project_dir,
            "sandbox": sandbox,
            "worktree": args.worktree,
            "lock_path": lock_path,
            "lock_kind": "project-directory" if args.mode == "read-only" else "project-directory+worker-file",
            "wall_timeout": args.wall_timeout,
            "planned_operations": operations,
        }))
        return 0

    if not shutil.which("grok"):
        die("'grok' executable not found on PATH (run setup-grok.sh first)")

    directory_lock_fd, lock_fd = acquire_worker_locks(project_dir, args.mode)
    state_fd = lock_fd if args.mode == "write" else None

    proc = None
    prompt_snapshot = None
    lifeline = watchdog_pid = None

    def handle_signal(signum, _frame):
        if proc is not None and proc.poll() is None:
            kill_process_group(proc.pid)
        sys.exit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, handle_signal)
        except OSError:
            pass

    try:
        if config_source != project_dir:
            provision_worktree_permissions(config_source, project_dir)
        exec_cwd = project_dir
        if args.worktree is not None:
            exec_cwd = create_or_resolve_worktree(project_dir, args.worktree, grok_bin)
            if args.prompt_file is not None:
                prompt_snapshot = stage_worktree_prompt(argv, exec_cwd, prompt_content)
            if args.allow_shell and not has_bash_allow_rule(exec_cwd):
                die(f"--allow-shell requires a Bash(...) allow rule in the target worktree config: {exec_cwd}")

        write_lock_state(state_fd, {
            "active": True,
            "pid": os.getpid(),
            "child_pid": None,
            "pgid": None,
            "started_at": int(time.time()),
            "cwd": exec_cwd,
            "project_dir": project_dir,
            "mode": args.mode,
            "status": "starting",
        })
        child_env = os.environ.copy()
        child_env["GROK_SANDBOX"] = sandbox
        lifeline, watchdog_pid = start_watchdog()
        proc = subprocess.Popen(
            argv,
            cwd=exec_cwd,
            env=child_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            shell=False,
            start_new_session=True,
        )
        try:
            os.write(lifeline, f"{proc.pid}\n".encode())
        except OSError:
            pass
        write_lock_state(state_fd, {
            "active": True,
            "pid": os.getpid(),
            "child_pid": proc.pid,
            "pgid": proc.pid,
            "started_at": int(time.time()),
            "cwd": exec_cwd,
            "project_dir": project_dir,
            "mode": args.mode,
            "status": "running",
        })
        try:
            stdout, stderr = proc.communicate(timeout=args.wall_timeout)
        except subprocess.TimeoutExpired:
            kill_process_group(proc.pid)
            try:
                stdout, stderr = proc.communicate(timeout=2)
            except Exception:
                stdout, stderr = "", ""
            msg = (
                f"[grok-worker] wall-clock timeout after {args.wall_timeout}s; "
                f"killed process group {proc.pid}. Review `git diff` / `git status` before retrying."
            )
            if stderr:
                sys.stderr.write(stderr)
                if not stderr.endswith("\n"):
                    sys.stderr.write("\n")
            sys.stderr.write(msg + "\n")
            sys.stdout.write(json.dumps({
                "type": "error",
                "stopReason": "wall_timeout",
                "message": msg,
                "cwd": exec_cwd,
            }) + "\n")
            return 124

        if stdout:
            sys.stdout.write(stdout)
        if stderr:
            sys.stderr.write(stderr)
        return proc.returncode
    finally:
        # Never leave grok running behind an error (e.g. a failed lock-state write after Popen).
        if proc is not None and proc.poll() is None:
            kill_process_group(proc.pid)
        if prompt_snapshot is not None:
            try:
                os.unlink(prompt_snapshot)
            except OSError:
                pass
        # Keep the lock file on disk (never unlink) so concurrent openers never lock a replaced inode.
        try:
            write_lock_state(state_fd, {
                "active": False,
                "pid": None,
                "child_pid": None,
                "pgid": None,
                "finished_at": int(time.time()),
                "cwd": project_dir,
                "mode": args.mode,
                "status": "idle",
            })
        except OSError:
            pass
        for fd in (lock_fd, directory_lock_fd):
            if fd is not None:
                try:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                except OSError:
                    pass
                os.close(fd)
        if lifeline is not None:
            stop_watchdog(lifeline, watchdog_pid)


if __name__ == "__main__":
    sys.exit(main())
