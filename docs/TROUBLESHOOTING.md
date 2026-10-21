English | [繁體中文](./TROUBLESHOOTING.zh-TW.md)

# Platform Notes & Troubleshooting Guide (macOS / Windows / WSL)

## Windows Native (PowerShell) Issues

### 1. `settings file is malformed: invalid character '\ufeff' looking for beginning of value`

- **Cause:** Windows PowerShell 5.1 writes files with a UTF-8 Byte Order Mark (BOM, `\ufeff`) by default when using `Set-Content -Encoding UTF8` or certain editors. The `agy` JSON parser rejects files containing a BOM.
- **Fix:** Our updated `setup.ps1` automatically strips BOMs and writes pure UTF-8 using `.NET` `[System.Text.UTF8Encoding]::new($false)`. If you edited `settings.json` manually and triggered this error, choose **Exit and fix manually**, then run this in PowerShell to strip the BOM:
  ```powershell
  $Path = "$HOME\.gemini\antigravity-cli\settings.json"
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (Get-Content $Path -Raw), $Utf8NoBom)
  ```

### 2. `PSSecurityException: ... cannot be loaded because running scripts is disabled on this system`

- **Cause:** Windows default Execution Policy blocks local `.ps1` scripts.
- **Fix:**
  - **Option A (Remote):** Run the remote one-liner (`irm ... | iex`), which executes in memory and bypasses file execution policies.
  - **Option B (Single-run bypass):** Run `powershell -ExecutionPolicy Bypass -File .\setup.ps1`.
  - **Option C (Permanent for current user):** Run `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` and press `Y`.

### 3. `Warning: ...\AppData\Local\agy\bin is not present in your active Environment PATH`

- **Cause:** The installer updates your Windows User PATH registry, but currently open terminal windows do not automatically reload environment variables from the registry.
- **Fix:** Completely close your PowerShell window and open a new one before running `agy`. In the VS Code integrated terminal, quit and reopen VS Code itself; a new terminal tab inherits the old PATH. As a one-off workaround in the current window: `$env:Path = "$env:LOCALAPPDATA\agy\bin;$env:Path"`.

### 4. Installer Prints `ERROR: logging before google.Init: I1020 ... installer.go`

- **Cause:** Google's Go-based installer writes internal info logs (`I1020...`) to `stderr` before initializing its logging module.
- **Fix:** Ignore these lines. As long as the final output says `Antigravity CLI installed/placed successfully`, the binary is healthy.

---

## macOS Common Issues

### 1. "Data Access Blocked: Terminal tried to access data from other apps"

- **Cause:** When `agy` triggers browser authentication or accesses repositories inside `Documents`, macOS TCC privacy protection blocks the access.
- **Fix:** Click **Manage** on the notification (or go to **System Settings > Privacy & Security > Files and Folders > Terminal**), enable the toggles for **Google Chrome** and **Documents**, and restart your terminal.

### 2. Stuck on the Terms of Service Screen

- On first launch, `> [x] Yes, I agree...` is already selected. Press **`Enter`** to continue. If the bottom prompt is not visible, make your terminal window taller.

---

## WSL & Cross-Platform Common Issues

### 1. Pasting `agy -p` Causes the Agent to Run `agy --help` and Explain the Command

- **Symptom:** Instead of getting a raw JSON response, you see `Thought for ...s`, `Ran (agy --help)`, and a conversational explanation stating you are in the interactive TUI.
- **Cause:** You pasted the headless CLI command inside `agy`'s interactive chat prompt (`>`) instead of your system shell.
- **Fix:** Type `/exit` (or press `Ctrl+D` twice) to return to your bash/zsh/PowerShell prompt (`$`, `%`, or `PS >`), then run `agy -p "..." --output-format json`.

### 2. Do I Need Separate Setups for Windows and WSL?

**Yes.** WSL is a separate Linux VM with its own binaries, `$HOME` directory, and cached OAuth credentials.

| Item             | Windows Native (PowerShell)                   | WSL (Linux)                               |
| ---------------- | --------------------------------------------- | ----------------------------------------- |
| **Setup Script** | `setup.ps1`                                   | `setup.sh`                                |
| **Binary Path**  | `%LOCALAPPDATA%\agy\bin\agy.exe`              | `~/.local/bin/agy`                        |
| **Config Path**  | `$HOME\.gemini\antigravity-cli\settings.json` | `~/.gemini/antigravity-cli/settings.json` |

> [!IMPORTANT]
> Never call Windows `agy.exe` from inside WSL (or vice versa). Cross-environment calls cause path translation mismatches (`/mnt/c` vs `C:\`), slow I/O, and Git CRLF/LF conflicts. Run both Claude Code and `agy` in the same environment where your code resides.

---

## Setup Script Messages

### 1. `[ERROR] Refusing to run in '...'`

The current directory becomes a trusted, writable workspace for `agy`, so the scripts refuse to run in your home directory or a drive/filesystem root. `cd` into your project root and run again.

### 2. `'...' is not a git repository` / `No terminal to confirm`

Without git you cannot diff what `agy` changed, so the scripts ask before continuing. When the script is piped (`curl | bash`) the prompt is read from the terminal; if there is no terminal at all (CI, some IDE consoles), set `AGY_BRIDGE_FORCE=1` (`$env:AGY_BRIDGE_FORCE='1'` in PowerShell) after confirming this really is your project root.

### 3. `Could not parse existing settings.json` / `settings.json.bak-<timestamp>`

The script never overwrites a `settings.json` it cannot parse (for example one with a trailing comma or comments). It saves a copy as `settings.json.bak-<timestamp>` next to it, leaves the original untouched and stops. Fix the JSON and run again; delete the `.bak` files when you no longer need them.

### 4. `CLAUDE.md has an older, unmarked Antigravity section`

Rules written by versions before `v1.1.0` have no markers, so the script will not guess where they end. Delete the `## Delegating Tasks to Antigravity (agy)` section once and re-run; later upgrades are automatic.

## General FAQ (Permissions, Skills, Quota & Models)

| Symptom / Question                                                                                                     | Cause & Resolution                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **JSON `status` is `SUCCESS` but `response` is an empty string** | A tool call (often `ls`) was soft-denied. Look for `denied_actions: RunCommand` in the JSON and `no output produced — a tool required the "command" permission` in `stderr`. Safely add the command with `bash scripts/allow.sh "<command>"` (or `.\scripts\allow.ps1 "<command>"` on Windows), and make sure the project directory is listed in `trustedWorkspaces`. Do not treat the empty result as a success. |
| **`stderr` says a tool required the `write_file` permission, and no files were created** | File writes are not covered by `trustedWorkspaces` alone. Re-run `setup.sh` / `setup.ps1` in the project root, or add `write_file(/absolute/path/to/project/)` to `permissions.allow`. Avoid `write_file(*)`: it also allows writes outside the project. |
| **Task succeeded (exit 0) in headless mode, but test/build commands or CLI skills (`jq`, `rg`, `cargo`) were skipped** | Headless mode cannot show interactive `Ask` prompts, so unlisted shell commands are soft-denied. Claude Code cannot approve permission prompts inside `agy`. Run `bash scripts/allow.sh "<command>"` (macOS / Linux / WSL) or `.\scripts\allow.ps1 "<command>"` (Windows) to safely add it (handles BOM, validates syntax, dedupes); or manually add the command prefix (e.g., `"command(jq)"`, `"command(rg)"`, `"command(cargo test)"` (no trailing `*`; rules are prefix matches)) to `permissions.allow` in `settings.json` (JSON does not allow `//` comments). |
| **Where should I install MCP servers vs CLI skills?**                                                                  | Install **MCP servers** (GitHub, Jira, DBs) on **Claude Code** so the manager gathers context and writes `TASK.md`. Install **CLI tools** (`rg`, `jq`, test runners) on your OS and add them to `agy`'s `permissions.allow` list so the worker can execute them.                                                   |
| **Will `setup.sh` / `setup.ps1` overwrite my existing `CLAUDE.md`?**                                                   | **No.** Both scripts check if `Antigravity` rules already exist and use non-destructive append (`>>` / `AppendAllText`), preserving all your existing instructions.                                                                                                                                                |
| **What happens if `agy` quota runs out during a delegated task?**                                                      | Per the **Error & Quota Fallback** rules in `CLAUDE.md`, Claude Code will **not** silently take over large batch tasks and burn your Claude quota. It reads `agy -p "/usage"` to see which quota group is exhausted (5-hour or weekly) and when it resets, retries once with a same-tier model from a group that still has quota, and only if every group is exhausted does it halt, report each group's limit and reset time, and ask for your decision.                                                                 |
| **Claude Code quota exhausted**                                                                                        | Launch `agy` directly in interactive mode. Type `/model` to switch to a flagship model (e.g., `gemini-4-argon-high`, `claude-sonnet-5-5-high`, or `claude-opus-5-5-high`) and continue coding using your Google AI Pro quota.                                                                                                               |
| `authentication required`                                                                                              | Not logged in or token expired. Run `agy` interactively once to log in, then `/exit`.                                                                                                                                                                                                                              |
| **Invalid model error**                                                                                                | Headless mode fails immediately if a model ID is deprecated or mistyped. Run `agy models` and use the exact ID from the first column. Our dynamic tiering rules in `CLAUDE.md` / `AGENTS.md` instruct the agent to omit `--model` for routine tasks and query `agy models` dynamically for complex tasks.                           |
| **Codex CLI fails with network / permission error when calling `agy`**                                                 | Codex CLI runs shell commands in an offline `workspace-write` sandbox by default, blocking `agy` from connecting to Google and writing to `~/.gemini/antigravity-cli`. Approve Codex's escalated permission prompt (`sandbox_permissions: "require_escalated"`), or run Codex with network/home access enabled. |
