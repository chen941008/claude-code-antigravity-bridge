#!/usr/bin/env python3
"""Optional Claude Code PreToolUse hook that hard-enforces the agy-bridge rules a prompt can't.

Blocks a Bash tool call that runs headless agy (`agy -p` / `--print` / `--prompt`) when:
  1. `--output-format json` is missing (Claude can't check status / denied_actions otherwise)
  2. it is neither `run_in_background` nor given a Bash `timeout` >= 600000 ms
  3. it runs in the foreground without `--print-timeout` (Claude Code does not kill a
     timed-out command, so agy must stop itself; verified with scripts/probe-bash-timeout.sh)
  4. another headless agy run from the same project directory is still alive (e.g. orphaned
     by an earlier timeout); runs started elsewhere are ignored when their cwd can be read

The instant `agy -p "/usage"` quota query is exempt (it runs no model).

Blocking = exit code 2 with the reason on stderr; Claude Code shows that reason to Claude.
Everything else passes through (exit 0). Any unexpected input also passes through, so a
bug here can never lock you out of the Bash tool.

The dirty-worktree check is intentionally NOT enforced: read-only delegations are allowed
on a dirty tree (CLAUDE.md rule 1), and a hook can't tell read-only from write tasks.
"""
import json
import os
import re
import shutil
import subprocess
import sys

MIN_TIMEOUT_MS = 600000

AGY_CMD = re.compile(r"(?:^|[\s/(`])agy(?:\.exe)?(?=\s)")
PRINT_FLAG = re.compile(r"\s(?:-p|--print|--prompt)(?=\s|=|$)")
JSON_FLAG = re.compile(r"\s--output-format(?:=|\s+)[\"']?json[\"']?(?=\s|$)")
PRINT_TIMEOUT_FLAG = re.compile(r"\s--print-timeout(?:=|\s+)\S+")
# Quoted strings are skipped so a prompt like "fix A; then B" is not split in the middle.
USAGE_QUERY = re.compile(r"""\s(?:-p|--print|--prompt)(?:=|\s+)["']?/usage["']?(?=\s|$)""")
SEGMENT_SPLIT = re.compile(r"""'[^']*'|"(?:[^"\\]|\\.)*"|(&&|\|\||[;|\n])""", re.DOTALL)


def split_shell_segments(command):
    segments, last = [], 0
    for m in SEGMENT_SPLIT.finditer(command):
        if m.group(1):  # a real separator, not one inside quotes
            segments.append(command[last:m.start()])
            last = m.end()
    segments.append(command[last:])
    return segments


def headless_agy_segments(command):
    return [s for s in split_shell_segments(command) if AGY_CMD.search(s) and PRINT_FLAG.search(s) and not USAGE_QUERY.search(s)]


def process_cwd(pid):
    """Best-effort working directory of a process, or None if it can't be determined."""
    try:
        return os.path.realpath(os.readlink(f"/proc/{pid}/cwd"))  # Linux
    except OSError:
        pass
    if shutil.which("lsof"):  # macOS
        out = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn", "-p", str(pid)],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                return os.path.realpath(line[1:])
    return None


def agy_already_running(project_dir):
    """True if a headless agy run started from this project (or an unknown dir) is alive."""
    if not shutil.which("pgrep"):
        return False  # Windows / minimal images: skip rather than guess
    # The hook runs before the new command starts, so any match is a previous run.
    pattern = r"(^|/)agy(\.exe)? .*(-p|--print|--prompt)( |=|$)"
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    project_dir = os.path.realpath(project_dir)
    for pid in out.split():
        if pid == str(os.getpid()):
            continue
        cwd = process_cwd(pid)
        # An unknown cwd falls back to the old machine-wide behavior (assume same project).
        if cwd is None or cwd == project_dir:
            return True
    return False


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    if event.get("tool_name") != "Bash":
        return 0
    tool_input = event.get("tool_input") or {}
    segments = headless_agy_segments(tool_input.get("command") or "")
    if not segments:
        return 0

    problems = []
    if not all(JSON_FLAG.search(s) for s in segments):
        problems.append("add `--output-format json` so status, response and denied_actions can be checked")
    background = tool_input.get("run_in_background") is True
    try:
        timeout = int(tool_input.get("timeout") or 0)
    except (TypeError, ValueError):
        timeout = 0
    if not background and timeout < MIN_TIMEOUT_MS:
        problems.append(
            f"set the Bash tool `timeout` to {MIN_TIMEOUT_MS} or use `run_in_background: true` "
            "(agy prints nothing until it finishes)"
        )
    if not background and not all(PRINT_TIMEOUT_FLAG.search(s) for s in segments):
        problems.append(
            "add `--print-timeout 540s` so agy stops itself before the Bash tool times out "
            "(Claude Code leaves a timed-out command running)"
        )
    if agy_already_running(event.get("cwd") or os.getcwd()):
        problems.append(
            "another headless agy run is still alive (maybe orphaned by a timeout); "
            "wait for it or ask the user, and check `git status` before retrying"
        )

    if problems:
        sys.stderr.write("agy-guard blocked this call:\n- " + "\n- ".join(problems) + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
