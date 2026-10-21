#!/usr/bin/env python3
"""Offline Grok worker regressions using real Git repositories and a recording CLI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
WORKER = Path(os.environ.get("GROK_WORKER_SCRIPT", ROOT / "scripts/grok-worker.py"))
# Without tomllib the worker can only trust worktree configs it provisioned itself.
HAS_TOMLLIB = sys.version_info >= (3, 11)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="grok-worker-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("GIT_") and k != "GROK_SANDBOX"}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_OPTIONAL_LOCKS="0")
        self.repo = self.base / "source"
        self.init_repo(self.repo)
        self.home = self.base / "grok-home"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.record = self.base / "record.json"
        fake = self.bin / "grok"
        fake.write_text("""#!/usr/bin/env python3
import json, os
from pathlib import Path
import signal, subprocess, sys, time
if os.environ.get('FAKE_IGNORE_TERM'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if sys.argv[1:3] == ['worktree', 'create']:
    mode = os.environ.get('FAKE_WORKTREE', 'fail')
    if mode == 'fail':
        sys.exit(1)
    target = os.environ['FAKE_TARGET']
    if mode == 'create':
        subprocess.run(['git', 'worktree', 'add', '--detach', target, 'HEAD'], check=True, capture_output=True)
        if os.environ.get('FAKE_REPLACE_PROMPT'):
            prompt = Path(os.environ['FAKE_REPLACE_PROMPT'])
            prompt.unlink()
            prompt.symlink_to(os.environ['FAKE_OUTSIDE_PROMPT'])
    print(target)
    sys.exit(0)
argv = sys.argv[1:]
data = {'argv': argv, 'cwd': os.getcwd(), 'pid': os.getpid()}
if '--prompt-file' in argv:
    prompt = Path(argv[argv.index('--prompt-file') + 1]).resolve()
    data.update(prompt_path=str(prompt), prompt=prompt.read_text(),
                inside_cwd=Path.cwd() in prompt.parents)
Path(os.environ['FAKE_RECORD']).write_text(json.dumps(data))
if os.environ.get('FAKE_RELEASE'):
    deadline = time.monotonic() + 10
    while not Path(os.environ['FAKE_RELEASE']).exists() and time.monotonic() < deadline:
        time.sleep(0.01)
print(json.dumps({'text': 'ok'}))
sys.exit(int(os.environ.get('FAKE_AGENT_EXIT', '0')))
""", encoding="utf-8")
        fake.chmod(0o755)
        self.env.update(GROK_HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        FAKE_RECORD=str(self.record))
        cfg = self.repo / ".grok"
        cfg.mkdir()
        (cfg / ".gitignore").write_text("*\n")
        (cfg / "config.toml").write_text(
            '[permission]\nallow = ' + json.dumps([
                f"Write({self.repo}/**)", f"Edit({self.repo}/**)", "Bash(git status)",
            ]) + "\n")

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], check=True,
                              capture_output=True, text=True, env=getattr(self, "env", None))

    def init_repo(self, path):
        path.mkdir()
        self.git(path, "init", "-q")
        (path / "code.txt").write_text("committed\n")
        self.git(path, "add", "code.txt")
        self.git(path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "initial")

    def linked(self, name="linked"):
        target = self.base / name
        self.git(self.repo, "worktree", "add", "--detach", str(target), "HEAD")
        return target

    def run_worker(self, *args, cwd=None, env=None, mode="write"):
        return subprocess.run([sys.executable, str(WORKER), "--mode", mode,
                               "--cwd", str(cwd or self.repo), *args],
                              env={**self.env, **(env or {})}, capture_output=True,
                              text=True, timeout=20)

    def snapshot(self):
        return {str(p.relative_to(self.base)): ("dir" if p.is_dir() else p.read_bytes())
                for p in self.base.rglob("*") if not p.is_symlink()}

    def assert_rejected(self, result, message):
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.record.exists(), "model invocation must not start")

    def test_unrelated_repo_rejected_without_grants(self):
        other = self.base / "unrelated"
        self.init_repo(other)
        for dry in (True, False):
            with self.subTest(dry_run=dry):
                before = self.snapshot()
                result = self.run_worker("--worktree", "../unrelated", "-p", "edit",
                                         *(["--dry-run"] if dry else []))
                self.assert_rejected(result, "same repository")
                self.assertEqual(before, self.snapshot())

    def test_native_output_cannot_grant_unrelated_repo(self):
        other = self.base / "unrelated"
        self.init_repo(other)
        result = self.run_worker("--worktree", "feature", "-p", "edit", env={
            "FAKE_WORKTREE": "print", "FAKE_TARGET": str(other)})
        self.assert_rejected(result, "same repository")
        self.assertFalse((other / ".grok").exists())
        self.assertFalse(self.home.exists())

    def test_fallback_destination_cannot_grant_unrelated_repo(self):
        target = self.repo / ".grok/worktrees/feature"
        target.parent.mkdir(parents=True)
        self.init_repo(target)
        result = self.run_worker("--worktree", "feature", "-p", "edit")
        self.assert_rejected(result, "same repository")
        self.assertFalse((target / ".grok").exists())
        self.assertFalse(self.home.exists())

    def test_common_dir_alone_does_not_prove_registration(self):
        real = self.linked()
        impostor = self.base / "impostor"
        impostor.mkdir()
        (impostor / ".git").write_bytes((real / ".git").read_bytes())
        result = self.run_worker("--worktree", str(impostor), "-p", "edit", "--dry-run")
        self.assert_rejected(result, "registered worktree")
        self.assertFalse((impostor / ".grok").exists())

    def test_source_directory_is_not_an_isolated_worktree(self):
        result = self.run_worker("--worktree", ".", "-p", "edit", "--dry-run")
        self.assert_rejected(result, "isolated")

    def test_unregistered_linked_cwd_cannot_inherit_permissions(self):
        real = self.linked()
        impostor = self.base / "impostor"
        impostor.mkdir()
        (impostor / ".git").write_bytes((real / ".git").read_bytes())
        before = self.snapshot()
        result = self.run_worker("-p", "edit", "--dry-run", cwd=impostor)
        self.assert_rejected(result, "registered worktree")
        self.assertEqual(before, self.snapshot())

    def test_registered_worktree_through_symlink_is_accepted(self):
        target = self.linked("linked with space")
        alias = self.base / "alias"
        alias.symlink_to(target, target_is_directory=True)
        result = self.run_worker("--worktree", str(alias), "-p", "edit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["cwd"], str(target))
        self.assertIn(f"Write({target}/**)", (target / ".grok/config.toml").read_text())

    def test_dry_run_existing_worktree_has_no_side_effects(self):
        target = self.linked()
        before = self.snapshot()
        result = self.run_worker("--worktree", str(target), "-p", "edit", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["cwd"], str(target))
        self.assertEqual(before, self.snapshot())

    def test_dry_run_new_and_auto_worktrees_do_not_call_grok(self):
        for flags in (("--worktree", "new-feature"), ("--worktree",)):
            with self.subTest(flags=flags):
                before = self.snapshot()
                result = self.run_worker(*flags, "-p", "edit", "--dry-run", env={
                    "FAKE_WORKTREE": "create", "FAKE_TARGET": str(self.base / "unexpected"),
                })
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(before, self.snapshot())

    def test_dry_run_from_linked_cwd_can_use_inherited_shell_rule_without_writes(self):
        target = self.linked()
        before = self.snapshot()
        result = self.run_worker("--allow-shell", "-p", "edit", "--dry-run", cwd=target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, self.snapshot())

    def test_invalid_arguments_from_linked_cwd_do_not_provision(self):
        target = self.linked()
        before = self.snapshot()
        result = self.run_worker("--max-turns", "0", "-p", "edit", cwd=target)
        self.assert_rejected(result, "--max-turns")
        self.assertEqual(before, self.snapshot())

    def test_explicitly_untrusted_worktree_rejected_before_writes(self):
        target = self.linked()
        self.home.mkdir()
        (self.home / "trusted_folders.toml").write_text(
            f'[folders.{json.dumps(str(target))}]\ntrusted = false\n')
        before = self.snapshot()
        result = self.run_worker("--worktree", str(target), "-p", "edit", "--dry-run")
        self.assert_rejected(result, "trusted = false")
        self.assertEqual(before, self.snapshot())

    def test_prompt_snapshot_is_inside_worktree_and_preserves_existing_task(self):
        target = self.linked()
        prompt = self.repo / "TASK.md"
        prompt.write_text("independent input\n你好\n")
        (target / "TASK.md").write_text("existing worker input\n")
        result = self.run_worker("--worktree", str(target), "--prompt-file", "TASK.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertTrue(record["inside_cwd"], record)
        self.assertEqual(record["prompt"], prompt.read_text())
        self.assertEqual((target / "TASK.md").read_text(), "existing worker input\n")
        self.assertFalse(Path(record["prompt_path"]).exists(), "temporary prompt must be cleaned up")

    def test_new_worktree_prompt_uses_snapshot(self):
        prompt = self.repo / "TASK.md"
        prompt.write_text("project task\n")
        target = self.base / "native"
        result = self.run_worker("--worktree", "feature", "--prompt-file", str(prompt), env={
            "FAKE_WORKTREE": "create", "FAKE_TARGET": str(target)})
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertTrue(record["inside_cwd"], record)
        self.assertEqual(record["prompt"], prompt.read_text())

    def test_failed_agent_still_removes_prompt_snapshot(self):
        target = self.linked()
        prompt = self.repo / "TASK.md"
        prompt.write_text("task\n")
        result = self.run_worker("--worktree", str(target), "--prompt-file", "TASK.md",
                                 env={"FAKE_AGENT_EXIT": "7"})
        self.assertEqual(result.returncode, 7, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertTrue(record["inside_cwd"], record)
        self.assertFalse(Path(record["prompt_path"]).exists())
        self.assertEqual(prompt.read_text(), "task\n")

    def test_json_prompt_keeps_content_block_format(self):
        target = self.linked()
        prompt = self.repo / "task.json"
        prompt.write_text('[{"type":"text","text":"task"}]\n')
        result = self.run_worker("--worktree", str(target), "--prompt-file", str(prompt))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(Path(record["prompt_path"]).suffix, ".json")
        self.assertEqual(record["prompt"], prompt.read_text())

    def test_dry_run_prompt_plan_matches_target_and_writes_nothing(self):
        target = self.linked()
        (self.repo / "TASK.md").write_text("task\n")
        before = self.snapshot()
        result = self.run_worker("--worktree", str(target), "--prompt-file", "TASK.md", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        path = Path(plan["argv"][plan["argv"].index("--prompt-file") + 1])
        self.assertIn(target, path.parents)
        self.assertEqual(before, self.snapshot())

    def test_fallback_clean_source_creates_head_worktree(self):
        result = self.run_worker("--worktree", "feature", "-p", "edit")
        self.assertEqual(result.returncode, 0, result.stderr)
        target = Path(json.loads(self.record.read_text())["cwd"])
        self.assertEqual(self.git(target, "rev-parse", "HEAD").stdout,
                         self.git(self.repo, "rev-parse", "HEAD").stdout)

    def test_fallback_with_project_prompt_uses_snapshot(self):
        prompt = self.repo / ".grok/task.md"
        prompt.write_text("project task\n")
        result = self.run_worker("--worktree", "feature", "--prompt-file", str(prompt))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertTrue(record["inside_cwd"], record)
        self.assertEqual(record["prompt"], prompt.read_text())

    def test_existing_worktree_security_config_is_preserved_byte_for_byte(self):
        target = self.linked()
        (target / ".grok").mkdir()
        config = target / ".grok/config.toml"
        original = (b'\xef\xbb\xbf# Worktree-specific restrictions\r\n'
                    b'[permission]\r\nallow = []\r\ndeny = ["Write(**/confidential/**)"]\r\n'
                    b'[ui]\r\npermission_mode = "plan"\r\n')
        config.write_bytes(original)
        for dry in (True, False):
            with self.subTest(dry_run=dry):
                result = self.run_worker("--worktree", str(target), "-p", "edit",
                                         *(["--dry-run"] if dry else []))
                if HAS_TOMLLIB:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assert_rejected(result, "Python 3.11+")
                self.assertEqual(config.read_bytes(), original)

    def test_provisioned_worktree_can_be_reused(self):
        for run in (1, 2):
            with self.subTest(run=run):
                result = self.run_worker("--worktree", "feature", "-p", "edit")
                self.assertEqual(result.returncode, 0, result.stderr)
        target = Path(json.loads(self.record.read_text())["cwd"])
        self.assertIn(f"Write({target}/**)", (target / ".grok/config.toml").read_text())

    def test_killed_wrapper_does_not_leave_grok_running_unlocked(self):
        release = self.base / "release"
        first = subprocess.Popen(
            [sys.executable, str(WORKER), "--mode", "write", "--cwd", str(self.repo), "-p", "wait"],
            env={**self.env, "FAKE_RELEASE": str(release), "FAKE_IGNORE_TERM": "1"},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        grok_pid = None
        try:
            deadline = time.monotonic() + 5
            while not self.record.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            grok_pid = json.loads(self.record.read_text())["pid"]
            self.record.unlink()
            first.kill()  # SIGKILL: none of the wrapper's own cleanup runs
            first.wait(timeout=5)
            # grok ignores SIGTERM, so the watchdog needs ~3s to SIGKILL it; the lock must hold meanwhile.
            second = self.run_worker("-p", "review", mode="read-only")
            self.assertEqual(second.returncode, 2, second.stderr)
            self.assertIn("another headless grok worker", second.stderr)
            deadline = time.monotonic() + 10
            while pid_alive(grok_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(pid_alive(grok_pid), "watchdog must end grok's process group")
            # The watchdog releases the lock as it exits, right after grok is gone.
            deadline = time.monotonic() + 5
            third = self.run_worker("-p", "review", mode="read-only")
            while third.returncode != 0 and time.monotonic() < deadline:
                time.sleep(0.1)
                third = self.run_worker("-p", "review", mode="read-only")
            self.assertEqual(third.returncode, 0, third.stderr)
        finally:
            release.touch()
            if grok_pid is not None and pid_alive(grok_pid):
                os.kill(grok_pid, 9)

    def test_invalid_existing_worktree_config_is_rejected_without_changes(self):
        target = self.linked()
        (target / ".grok").mkdir()
        config = target / ".grok/config.toml"
        for content in ('[permission\n', '[permission]\ndeny = "Write(*)"\n',
                        '[permission]\nallow = [false]\n'):
            with self.subTest(content=content):
                config.write_text(content)
                before = self.snapshot()
                result = self.run_worker("--worktree", str(target), "-p", "edit")
                self.assert_rejected(result, "config")
                self.assertEqual(before, self.snapshot())

    def test_allow_shell_uses_existing_target_rules(self):
        target = self.linked()
        (target / ".grok").mkdir()
        config = target / ".grok/config.toml"
        config.write_text('[permission]\nallow = []\ndeny = ["Bash(*)"]\n')
        before = self.snapshot()
        result = self.run_worker("--worktree", str(target), "--allow-shell", "-p", "test")
        self.assert_rejected(result, "Bash" if HAS_TOMLLIB else "Python 3.11+")
        self.assertEqual(before, self.snapshot())

    def test_config_created_during_initialization_is_not_overwritten(self):
        target = self.linked()
        scope = {"__name__": "worker_under_test"}
        exec(compile(WORKER.read_text(), str(WORKER), "exec"), scope)
        original = b'[permission]\nallow = []\ndeny = ["Write(**/confidential/**)"]\n'
        real_link = os.link

        def concurrent_config(source, destination):
            Path(destination).write_bytes(original)
            return real_link(source, destination)

        with mock.patch.dict(os.environ, self.env, clear=True):
            with mock.patch.object(os, "link", side_effect=concurrent_config):
                if HAS_TOMLLIB:
                    scope["provision_worktree_permissions"](str(self.repo), str(target))
                else:
                    # A config the wrapper cannot validate is refused, never overwritten.
                    with self.assertRaises(SystemExit):
                        scope["provision_worktree_permissions"](str(self.repo), str(target))
        self.assertEqual((target / ".grok/config.toml").read_bytes(), original)
        self.assertEqual(list((target / ".grok").glob("config-*.tmp")), [])

    def test_read_only_linked_cwd_does_not_initialize_permissions_or_trust(self):
        target = self.linked()
        original = (self.repo / ".grok/config.toml").read_bytes()
        result = self.run_worker("-p", "review", cwd=target, mode="read-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((target / ".grok/config.toml").exists())
        self.assertFalse((target / ".grok/.gitignore").exists())
        self.assertFalse((target / ".grok").exists())
        self.assertFalse((self.home / "trusted_folders.toml").exists())
        self.assertEqual((self.repo / ".grok/config.toml").read_bytes(), original)
        record = json.loads(self.record.read_text())
        self.assertIn("read_file,grep,list_dir", record["argv"])
        self.assertEqual(record["argv"][record["argv"].index("--sandbox") + 1], "read-only")

    def test_read_only_does_not_require_or_copy_main_permission_config(self):
        target = self.linked()
        (self.repo / ".grok/config.toml").write_text('[broken\n')
        result = self.run_worker("-p", "review", cwd=target, mode="read-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((target / ".grok/config.toml").exists())
        self.assertFalse((self.home / "trusted_folders.toml").exists())

    def test_read_only_preserves_existing_config_trust_and_lock_state(self):
        target = self.linked()
        result = self.run_worker("--worktree", str(target), "-p", "edit")
        self.assertEqual(result.returncode, 0, result.stderr)
        files = [target / ".grok/config.toml", target / ".grok/.gitignore",
                 self.home / "trusted_folders.toml"]
        # Create an idle legacy lock in the target; read-only may lock it but must not rewrite it.
        lock = target / ".grok/worker.lock"
        lock.write_text('{"active": false, "sentinel": "preserve"}\n')
        files.append(lock)
        original = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files}
        result = self.run_worker("-p", "review", cwd=target, mode="read-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(original, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in files})

    def test_directory_lock_blocks_both_modes_and_guard_without_read_only_files(self):
        for first_mode, second_mode in (("read-only", "write"), ("write", "read-only")):
            with self.subTest(first_mode=first_mode):
                target = self.linked("linked-" + first_mode)
                if self.record.exists():
                    self.record.unlink()
                release = self.base / ("release-" + first_mode)
                first = subprocess.Popen([
                    sys.executable, str(WORKER), "--mode", first_mode, "--cwd", str(target), "-p", "wait",
                ], env={**self.env, "FAKE_RELEASE": str(release)}, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 5
                    while not self.record.exists() and first.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(self.record.exists(), "first worker did not launch")
                    second = self.run_worker("-p", "review", cwd=target, mode=second_mode)
                    self.assertEqual(second.returncode, 2, second.stderr)
                    self.assertIn("another headless grok worker", second.stderr)
                    event = {"tool_name": "Bash", "cwd": str(target), "tool_input": {
                        "command": "python3 .grok/grok-worker.py --mode read-only -p review", "timeout": 600000,
                    }}
                    guard = subprocess.run([sys.executable, str(ROOT / "extras/claude-hook/grok_guard.py")],
                                           input=json.dumps(event), env=self.env, capture_output=True, text=True)
                    self.assertEqual(guard.returncode, 2, guard.stderr)
                    if first_mode == "read-only":
                        self.assertFalse((target / ".grok").exists())
                    release.touch()
                    stdout, stderr = first.communicate(timeout=5)
                    self.assertEqual(first.returncode, 0, stderr + stdout)
                finally:
                    release.touch()
                    if first.poll() is None:
                        first.terminate()
                        first.communicate(timeout=5)

    def test_external_prompt_paths_are_rejected_before_reading_or_staging(self):
        target = self.linked()
        outside = self.base / "outside-task.txt"
        outside.write_bytes(b'\xffmock sensitive content')
        link = self.repo / "linked-task.txt"
        link.symlink_to(outside)
        directory_link = self.repo / "outside-dir"
        directory_link.symlink_to(self.base, target_is_directory=True)
        paths = [str(outside), "../outside-task.txt", str(link), "outside-dir/outside-task.txt"]
        for path in paths:
            for dry in (True, False):
                with self.subTest(path=path, dry=dry):
                    before = self.snapshot()
                    result = self.run_worker("--worktree", str(target), "--prompt-file", path,
                                             *(["--dry-run"] if dry else []))
                    self.assert_rejected(result, "project")
                    self.assertEqual(before, self.snapshot())

    def test_external_prompt_is_also_rejected_without_worktree_in_both_modes(self):
        outside = self.base / "outside-task.txt"
        outside.write_text("must not reach the model\n")
        for mode in ("write", "read-only"):
            with self.subTest(mode=mode):
                before = self.snapshot()
                result = self.run_worker("--prompt-file", str(outside), mode=mode)
                self.assert_rejected(result, "project")
                self.assertEqual(before, self.snapshot())

    def test_prompt_snapshot_uses_validated_content_if_source_symlink_changes(self):
        prompt = self.repo / "TASK.md"
        prompt.write_text("authorized task\n")
        outside = self.base / "outside.txt"
        outside.write_text("sensitive content\n")
        target = self.base / "native"
        result = self.run_worker("--worktree", "feature", "--prompt-file", str(prompt), env={
            "FAKE_WORKTREE": "create", "FAKE_TARGET": str(target),
            "FAKE_REPLACE_PROMPT": str(prompt), "FAKE_OUTSIDE_PROMPT": str(outside),
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["prompt"], "authorized task\n")

    def test_fallback_rejects_unstaged_staged_and_untracked_changes(self):
        for state in ("unstaged", "staged", "untracked"):
            with self.subTest(state=state):
                self.git(self.repo, "reset", "--hard", "HEAD")
                untracked = self.repo / "untracked.txt"
                if untracked.exists():
                    untracked.unlink()
                changed = untracked if state == "untracked" else self.repo / "code.txt"
                changed.write_text("must not be lost\n")
                if state == "staged":
                    self.git(self.repo, "add", "code.txt")
                before = self.git(self.repo, "status", "--porcelain").stdout
                result = self.run_worker("--worktree", "feature", "-p", "edit")
                self.assert_rejected(result, "uncommitted")
                self.assertEqual(changed.read_text(), "must not be lost\n")
                self.assertEqual(before, self.git(self.repo, "status", "--porcelain").stdout)
                self.assertFalse((self.repo / ".grok/worktrees").exists())


if __name__ == "__main__":
    unittest.main()
