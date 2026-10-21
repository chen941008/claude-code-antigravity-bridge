English | [繁體中文](./README.zh-TW.md)

# Delegating Tasks from Claude Code to Antigravity CLI (`agy`) Without Third-Party MCPs

> **Unofficial Guide.** Based on Google Antigravity official documentation (as of 2026-10-20) and cross-platform real-world testing. Not affiliated with Google or Anthropic.

## Overview

If you subscribe to both Claude (Claude Code) and Google AI Pro (Antigravity), you can use Claude Code as the "Manager" (planning, architecture, verification) and delegate **high-volume, well-specified tasks** (batch refactoring, unit tests, repo-wide searches, code reviews) to Antigravity. This consumes your Google AI Pro quota while preserving your Claude Code limits.

### Why Not Use a Third-Party MCP Server?

- Most community `agy` MCP wrappers are single-maintainer repos with minimal code auditing.
- Installing via `npx -y` pulls the latest remote package on every startup, introducing supply-chain risks.
- Many wrappers hardcode `--dangerously-skip-permissions` to prevent headless hangs, bypassing all tool-call safety checks.

Because the official `agy` CLI natively supports headless mode (`agy -p`), Claude Code can invoke it directly via Bash. **Zero third-party middleware, full visibility into every command.**

```text
User ──> Claude Code ──(Bash)──> agy -p "task" --output-format json ──> Antigravity Agent
          │ Plan, judge, verify                                          │ Read/write files, run allowlisted cmds
          └──────────── Parse JSON result & verify changes     ◀────────┘
```

---

## Quick Start (Automated Setup)

Run the setup script inside your **project root directory** to automatically install `agy`, merge safe allow/deny rules into `settings.json` (strictly formatted as UTF-8 without BOM), trust the current workspace, and append dynamic delegation rules to both `CLAUDE.md` (for **Claude Code**) and `AGENTS.md` (for **OpenAI Codex CLI, OpenCode, Grok, Cursor, Windsurf, Cline, GitHub Copilot**). To generate only one file, pass `--claude-only` or `--agents-only` (or set `AGY_BRIDGE_TARGETS=CLAUDE.md` / `AGENTS.md`).

### At a Glance: What Is Global, What Is Per Project?

| | Where | How often |
| --- | --- | --- |
| Sign in to `agy` (Step 2) | Your computer (cached credentials) | **Once** |
| Allow/deny rules and trusted folders | One global file: `~/.gemini/antigravity-cli/settings.json` (Windows: `C:\Users\<you>\.gemini\antigravity-cli\settings.json`). Each project you set up adds its own folder to it; existing entries are kept. | Each project |
| Delegation rules for your AI Agent | `CLAUDE.md` (Claude Code) and `AGENTS.md` (Codex CLI, OpenCode/Grok, Cursor, Windsurf, Cline, Copilot) in **that project's root**. | Each project |

So for every new project: `cd` into its root and run the setup script once (Step 1). Skip Steps 2 and 3, they are one-time. A project you never ran setup in has no delegation rules, and `agy` is not allowed to write there.

### Step 1: Run the Setup Script

#### Option A: Remote One-Liner, pinned to `v1.3.0` (No system permission changes required)

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.ps1 | iex
```

> [!CAUTION]
> Piping a remote script into your shell runs it with your privileges. Since this guide exists to avoid unaudited code, read the script first (or use Option B), and note that `setup.sh` requires `python3` to merge `settings.json`.

The URLs above point at the fixed tag `v1.3.0`, not the moving `main` branch, so the code you run cannot change underneath you. To also check what you downloaded, compare its SHA-256 with the values below (this protects against tampering in transit; if you don't trust the repository itself, read the script):

| File | SHA-256 (`v1.3.0`) |
| --- | --- |
| `setup.sh` | `b8100ee6073ddb1df1c3b3e434096a54aa526eda1b76152092c3512a02a332e8` |
| `setup.ps1` | `43a9b5cfef519a0480acde37524b1c540364068c0fe440dac6b39ba8c6f885b4` |

```bash
# macOS / Linux / WSL
curl -fsSLO https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.sh
sha256sum setup.sh        # macOS: shasum -a 256 setup.sh
bash setup.sh
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.ps1 -OutFile setup.ps1
(Get-FileHash .\setup.ps1 -Algorithm SHA256).Hash
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

> [!NOTE]
> Safety checks built into the scripts: they refuse to run in your home directory or a drive/filesystem root (the current directory becomes a writable workspace for `agy`), ask for confirmation in a non-git folder (set `AGY_BRIDGE_FORCE=1` to skip the prompt in non-interactive runs), and never overwrite a `settings.json` they cannot parse; they save a `settings.json.bak-<timestamp>` and stop instead.

#### Option B: Running Locally (If you cloned this repository)

To avoid `chmod` on Linux/macOS or `PSSecurityException (UnauthorizedAccess)` on Windows, invoke the interpreter directly:

**macOS / Linux / WSL:**

```bash
bash setup.sh
```

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

> [!NOTE]
>
> - During installation, the official Google installer may print `ERROR: logging before google.Init...` to the console. These are harmless internal Go debug logs; as long as you see `installed/placed successfully`, the installation succeeded.
> - Native Windows and WSL do not share binaries or credentials. Run the respective script in each environment. See [Platform & Troubleshooting Guide](./docs/TROUBLESHOOTING.md).

### Step 2: Interactive Login (One-Time Setup)

Headless mode relies on cached credentials. Run `agy` interactively once (restart your terminal first if `agy` is not found in your active PATH; in the VS Code integrated terminal, fully quit and reopen VS Code, because opening a new terminal tab does not reload PATH):

```bash
agy
```

1. Press **`Enter`** to accept the Terms of Service (`> [x] Yes, I agree...`).
2. Complete the Google OAuth login in your browser using your Google AI Pro account.
3. _(Recommended)_ Type `/model` to set your default model to a quota-saving option (e.g., `Gemini 3.8 Flash (Low)` or `Medium`). Tier 1 routine tasks will use this default automatically.
4. **CRITICAL:** Type `/exit` to quit the interactive TUI and return to your system shell.

> [!WARNING]
> Do not paste headless `agy -p` commands inside the `agy` interactive prompt (`>`). If you do, the agent will get confused, run `agy --help` inside the chat, and explain the command to you instead of returning raw JSON. Always `/exit` back to your system shell first.

### Step 3: Verify Headless Mode

From your normal terminal prompt (`$`, `%`, or `PS >`), test JSON output:

```bash
agy -p "Explain git status in one sentence" --output-format json
```

Once you see `"status": "SUCCESS"`, launch `claude` and start delegating tasks:

```text
> Write unit tests for all modules under src/api/. Delegate this batch work to agy according to CLAUDE.md.
```

### Step 4 (Optional): Check the Installation

From your project root, run the self-check. It never calls a model, so it costs no quota. It confirms that `agy` is on PATH, that `settings.json` is valid and has the rules for this project, that `CLAUDE.md` and `AGENTS.md` have the current rules block, and prints your quota groups:

```bash
# macOS / Linux / WSL (the repo's scripts/ folder; or download verify.sh from the same tag as setup.sh)
bash scripts/verify.sh
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

Every line is `PASS`, `WARN` or `FAIL`; the exit code is the number of `FAIL` lines. Paste the output into a bug report if something is off. The same script runs in CI on Ubuntu, macOS and Windows (PowerShell 5.1 and 7) after every push.

### Using It Across Agents (Claude Code, Codex CLI, OpenCode/Grok, Cursor), and Removing It

Start `claude`, `codex`, `opencode`, or your `AGENTS.md`-compatible IDE agent inside a project you ran setup in. Claude Code reads `CLAUDE.md`, while Codex CLI, OpenCode (Grok / DeepSeek / etc.), Cursor, Windsurf, Cline, and Copilot read `AGENTS.md`. Bulk work (many-file edits, unit tests, repo-wide searches, code reviews) is a good fit; architecture decisions and small edits stay with your outer agent. It is guidance, not a guarantee: to be sure, say so explicitly, e.g. "Delegate this to agy according to CLAUDE.md / AGENTS.md". By default `agy` may only run read-only commands such as `ls` and `git status`; see the "How to Add CLI Skills" tutorial below to allow more.

> [!IMPORTANT]
> **Cross-Agent Pitfalls Already Handled in `v6` Rules (and What to Watch For):**
> 1. **OpenAI Codex CLI Sandbox (`workspace-write`):** Codex runs shell commands in an offline Seatbelt/Landlock sandbox by default, which blocks `agy` from reaching Google's API and writing session/auth state to `~/.gemini/antigravity-cli`. The `v5` rules instruct Codex to request escalated permissions (`sandbox_permissions: "require_escalated"`) for `agy` calls; approve the prompt when Codex asks, or run Codex with network/home access enabled for `agy`.
> 2. **Self-Recursion Prevention:** Because `agy` runs in the same project root, it could read `AGENTS.md` / `CLAUDE.md` itself. Both `permissions.allow` (which omits `command(agy)`) and an explicit orchestrator-only header in `v5` prevent `agy` from recursively calling itself.
> 3. **Shell Quoting on Windows PowerShell vs Bash:** Agents on Windows (Codex, Cursor) often invoke PowerShell instead of Bash. Rule 2 instructs agents to write multi-line or quote-heavy specs to `TASK.md` first rather than escaping inline strings.

To remove it from a project: delete the block between `<!-- agy-bridge:start ... -->` and `<!-- agy-bridge:end -->` in that project's `CLAUDE.md` and `AGENTS.md`, then delete the project's folder from `permissions.allow` (the `write_file(...)` entry) and from `trustedWorkspaces` in the global `settings.json`. There is no automatic uninstall.

If `scripts/verify.*` or the setup script warns about an older, unmarked section in `CLAUDE.md`, see [Q5](#q5-i-ran-an-older-version-of-the-setup-script-how-do-i-get-the-updated-rules): delete that old section once and re-run setup.

---

## Architectural Best Practices: Where to Install "Skills"?

In this Manager-Worker architecture, split your tool integrations based on their role:

1. **API / MCP Server Skills -> Install on Claude Code**
   - **Examples:** GitHub MCP (reading PRs/issues), Jira (fetching tickets), PostgreSQL (querying database schema), Slack.
   - **Why:** Claude is the brain. It safely fetches external context via API, distills the requirements into a local `TASK.md`, and delegates the coding to `agy`. `agy` never needs access to your external credentials or database tokens.
2. **System CLI Tool Skills -> Install on OS & Allowlist in `agy`**
   - **Examples:** `jq` (JSON processor), `ripgrep` (`rg` for fast search), `cargo` / `go` / `pytest` / `cmake` (build & test runners).
   - **Why:** These are local execution tools for the worker. `agy` can invoke any system CLI tool as a skill in headless mode _only if_ it is explicitly allowlisted in `settings.json`.

### Tutorial: Allowing More Commands Safely (CLI Skills & Tests)

In headless mode (`agy -p`), `agy` cannot display interactive permission prompts:

- **File reads** are allowed. **File writes** need a `write_file(...)` allow rule even inside `trustedWorkspaces` (tested). The setup script adds one scoped to your project directory; `write_file(*)` would also allow writes outside the project, so avoid it.
- **Shell commands** default to `Ask` and are **soft-denied** in headless mode (skipped and logged to `stderr`, even though the exit code is `0`).

#### 1. What Is Allowed by Default?
`setup.sh` and `setup.ps1` configure safe defaults that inspect project structure without printing file contents or running arbitrary code:
- **Directory listing:** `ls`, `dir`, `Get-ChildItem`, `tree`
- **Location & tool lookup:** `pwd`, `Get-Location`, `which`, `where.exe`, `Get-Command`, `Test-Path`
- **Git operations:** `git` (allows `git status`, `git diff`, `git ls-files`, `git log`)
- **Project file writing:** restricted to your project root.

During setup, the script automatically scans for project files (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `pom.xml`, `Makefile`, `.sln`/`.csproj`) and prompts once to allow your test runner (`npm test`, `pytest`, `cargo test`, etc.).

#### 2. Adding Commands with the Safe Helper (Recommended)
Claude Code and external agents **cannot** approve permission prompts inside `agy`. To grant `agy` the skill to run tools like `rg` (ripgrep), `jq`, or project test runners without manually editing JSON (avoiding UTF-8 BOM, trailing commas, or syntax errors), use `scripts/allow.sh` / `scripts/allow.ps1`:

```bash
# macOS / Linux / WSL
bash scripts/allow.sh "npm test" pytest
bash scripts/allow.sh --list
bash scripts/allow.sh --remove pytest

# Windows (PowerShell)
.\scripts\allow.ps1 "npm test" pytest
.\scripts\allow.ps1 --list
.\scripts\allow.ps1 --remove pytest
```

Without cloning the repository (one-line command):
```bash
# macOS / Linux / WSL
curl -fsSL https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/scripts/allow.sh | bash -s -- "npm test"

# Windows (PowerShell)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/scripts/allow.ps1))) "npm test"
```

**Built-in Safety Checks:**
- **Refuses dangerous commands:** Blocks file deletion (`rm`, `del`, `Remove-Item`), privilege escalation (`sudo`, `runas`), remote download/execution (`curl`, `wget`, `irm`), and `agy` (prevents runaway self-recursion).
- **Refuses shell operators:** Blocks compound commands with `|`, `&&`, `;`, `>`, or `$()`, which headless permission checks block anyway.
- **Refuses bare interpreters:** Forbids broad execution commands (`python`, `bash`, `node`) on their own, while allowing specific subcommands (`python -m pytest`).
- **Cautions on file content readers:** Warns before allowlisting `cat`, `rg`, `jq`, `Get-Content`, `Select-String`, because `read_file(.env)` in `deny` only stops `agy`'s built-in file reader tool, not shell commands. Use `--yes` to confirm without a terminal.

#### 3. Autonomous Mode vs Standard Safe Mode
If you want `agy` to run completely unattended without prompting or soft-denying build tools and test runners:

- **Activate Autonomous Mode (`command(*)`)**:
  ```bash
  # macOS / Linux / WSL
  bash scripts/allow.sh --autonomous
  # or pass flag during initial setup: bash setup.sh --autonomous

  # Windows (PowerShell)
  .\scripts\allow.ps1 --autonomous
  # or pass flag during initial setup: .\setup.ps1 --autonomous
  ```
  Grants `agy` freedom to run general CLI tools, build runners, and test suites automatically in headless mode. High-risk commands (`rm -rf`, `sudo`, `git push -f`, reading `.env`, calling `agy` itself) remain **strictly blocked** by `permissions.deny` because Antigravity enforces `Deny > Ask > Allow`.

- **Restore Strict Safe Mode**:
  ```bash
  # macOS / Linux / WSL
  bash scripts/allow.sh --strict

  # Windows (PowerShell)
  .\scripts\allow.ps1 --strict
  ```
  Removes `command(*)` and restores granular, explicit allowlisting.

#### 4. Manual Configuration (`settings.json`)
If you prefer editing manually, open `~/.gemini/antigravity-cli/settings.json` (Windows: `$HOME\.gemini\antigravity-cli\settings.json`):

```json
{
  "colorScheme": "tokyo night",
  "model": "Gemini 3.8 Flash (Medium)",
  "permissions": {
    "allow": [
      "write_file(/path/to/your/project/)",
      "command(ls)",
      "command(git status)",
      "command(git diff)",
      "command(git log)",
      "command(pytest)",
      "command(make)",
      "command(cargo test)",
      "command(jq)",
      "command(rg)",
      "command(regex:npm run (build|lint|test))"
    ],
    "deny": [
      "command(rm -rf)",
      "command(sudo)",
      "command(git push --force)",
      "command(git push -f)",
      "write_file(.git/)",
      "read_file(.env)"
    ]
  },
  "trustedWorkspaces": ["/path/to/your/project"]
}
```

_Rules are matched as command prefixes: `"command(jq)"` also allows `jq .name package.json`, and `"command(rg)"` also allows `rg TODO src/`._

> [!IMPORTANT]
> **Write `command(jq)`, not `command(jq *)`.** A trailing ` *` does not work. Verified on 2026-10-20 with headless `agy -p` on WSL (one run per case, `agy` asked to run each command verbatim):
>
> | `permissions.allow` | Command | Result |
> | --- | --- | --- |
> | `command(ls *)` | `ls -la`, `ls` | denied |
> | `command(ls)` | `ls -la` | allowed (prefix match) |
> | `command(ls)` | `ls && echo ...`, `ls; echo ...`, `ls \| wc -l`, `ls $(echo ...)` | denied |
> | `command(ls)` | `echo ...` (control) | denied |
>
> So a prefix rule does not let extra chained, piped or substituted commands ride along. Not tested: chains where **every** segment is allowlisted (the [official page](https://antigravity.google/docs/permissions?tab=cli) says `git status && git log` runs when `command(git)` is allowed), and deny-rule matching. The deny rules in this repo use the same documented prefix form (`command(rm -rf)`, `command(sudo)`, ...) for that reason. Keep the allowlist narrow and do not allow interpreters or network tools (`bash`, `python`, `node`, `curl`, `wget`, `ssh`).
>
> If you ran an older version of the setup script, entries ending in ` *` (such as `command(ls *)`) are harmless no-ops; you can delete them. To re-check this behavior after an `agy` update, back up your `settings.json`, set `allow` to just `["command(ls)"]`, and run `agy -p "Run exactly this shell command, unmodified, and show its raw output: ls && echo CHAIN_OK" --output-format json`: the run should be denied and `CHAIN_OK` should not appear.

---

## FAQ & Design Philosophy

### Q1: I already have project-specific instructions in my `CLAUDE.md`. Will the setup script overwrite them?

**No.** The script uses a non-destructive append approach. If `CLAUDE.md` already exists, it simply appends the Antigravity delegation rules to the bottom of the file, leaving your existing instructions intact. The rules live in a block wrapped in `<!-- agy-bridge:start v4 -->` / `<!-- agy-bridge:end -->` markers, so re-running the script replaces only that block and never duplicates it or touches anything else.

### Q2: How does Claude Code choose which `agy` model to use without wasting quota or breaking when models update?

Our `CLAUDE.md` rules implement **Dynamic Model Tiering**:

- **Tier 1 (Routine tasks):** Claude omits the `--model` flag, automatically using your lightweight default configured in `settings.json`.
- **Tier 2 & 3 (Moderate to Complex logic):** Claude runs `agy models` once per session to discover currently available model IDs, then dynamically selects a mid-tier or flagship model (`--model <MODEL_ID>`). No hardcoded model IDs will break when Google updates its catalog.

### Q3: What happens if Antigravity's quota runs out? Will Claude Code silently drain its own quota to finish the batch job?

**No.** `CLAUDE.md` includes a strict **Quota Fallback Guardrail**. When Claude detects a "Quota Exceeded", "429 Too Many Requests", or soft-denied command error in `agy`'s output, it runs `agy -p "/usage"` (instant, zero tokens) to read the quota groups. Each group lists which models share its limits and has a 5-hour and a weekly bucket, so Claude knows exactly which limit was hit and when it resets. Groups are read from `agy`, never hardcoded, so it keeps working when Google changes them. If the failed run changed no files, Claude retries once with a same-tier model from a group that still has quota. If every group is exhausted, it is strictly forbidden from taking over the batch task automatically: it halts, reports each group's limit and reset time, and asks for your explicit decision.

### Q4: I'm getting a macOS "Data Access Blocked" popup or a Windows `\ufeff` BOM error. What do I do?

See our comprehensive troubleshooting guide: **[docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md)**.

### Q5: I ran an older version of the setup script. How do I get the updated rules?

Rules added by versions **before `v1.1.0`** have no markers, so the script leaves that section untouched and prints a warning (those old rules include, for example, "git status must be clean, commit if necessary", which blocks read-only tasks). Migrate once:

1. In your `CLAUDE.md`, delete the whole `## Delegating Tasks to Antigravity (agy)` section (it was appended at the end; keep anything you wrote yourself).
2. Re-run `setup.sh` / `setup.ps1` from the project root. It appends the new marked block and merges `settings.json` without duplicating entries.

After that, re-running the script upgrades the marked block in place automatically. Re-running does **not** remove allowlist entries added by older versions (such as `pytest *` and `make *`). Remove them by hand from `~/.gemini/antigravity-cli/settings.json` if you do not want them.

---

## Optional: Hard-Enforce the Rules with a PreToolUse Hook

`CLAUDE.md` rules are advice; Claude can still forget them. [`extras/claude-hook/agy_guard.py`](./extras/claude-hook/agy_guard.py) is an optional Claude Code hook that blocks a headless `agy -p` call (exit code 2) when `--output-format json` is missing, when neither `run_in_background` nor a Bash `timeout` >= 600000 is set, when a foreground call lacks `--print-timeout`, or when another headless `agy` run from the same project directory is still alive (runs in other projects are ignored when their directory can be read; otherwise it conservatively blocks). Add it to `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "python3 /path/to/extras/claude-hook/agy_guard.py" }] }
    ]
  }
}
```

Unexpected input always passes through, so a bug in the hook cannot lock you out of Bash. Test it offline with `bash scripts/test-agy-guard.sh`.

## Quota & Security Checklist

- **Quota consumption:** Antigravity quota is based on actual agent work/tokens (refreshes every 5 hours with a weekly cap). Each headless call loads ~6k–10k context tokens; batch related edits into a single task or reuse `--conversation <id>`.
- **Model pools:** Gemini models and Claude/GPT models draw from separate quota pools. Use Gemini Flash for routine tasks.
- **Family sharing:** Antigravity quota in a Google One family group is shared across all members.
- **Untrusted output:** The rules tell Claude to treat `agy` output (and anything `agy` read from the repo) as data, never as instructions, because files in a repository can contain planted text. Still review diffs before accepting changes.
- **Safety:** Prefer a Git repo (the rules use `git status` / `git diff` when available, and fall back to a backup or file-list check when not), never use `--dangerously-skip-permissions` outside ephemeral sandboxes, and always review the changes after delegation.
