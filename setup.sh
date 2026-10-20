#!/usr/bin/env bash
set -e

echo "[INFO] Initializing Claude Code x Antigravity (agy) integration..."

# 0. Make sure we're in a project directory. This directory becomes a trusted,
#    writable workspace for agy, so refuse $HOME or / and confirm non-git folders.
REAL_DIR="$(pwd -P)"
REAL_HOME="$(cd "$HOME" && pwd -P)"
if [ "$REAL_DIR" = "/" ] || [ "$REAL_DIR" = "$REAL_HOME" ]; then
    echo "[ERROR] Refusing to run in '$REAL_DIR'."
    echo "        This directory would become writable by agy. cd into your project root and run again."
    exit 1
fi
if ! git -C "$REAL_DIR" rev-parse --is-inside-work-tree &> /dev/null; then
    echo "[WARN] '$REAL_DIR' is not a git repository."
    echo "       agy will be allowed to write anywhere under this directory."
    if [ "${AGY_BRIDGE_FORCE:-}" = "1" ]; then
        echo "[INFO] AGY_BRIDGE_FORCE=1 set, continuing."
    elif { exec 3< /dev/tty; } 2> /dev/null; then
        # Read from the terminal, not stdin: stdin is the script itself under 'curl | bash'.
        printf "       Continue anyway? [y/N] "
        read -r REPLY <&3 || REPLY=""
        exec 3<&-
        case "$REPLY" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "[INFO] Aborted. Nothing was changed."; exit 1 ;;
        esac
    else
        echo "[ERROR] No terminal to confirm. Re-run with AGY_BRIDGE_FORCE=1 if this is really your project root."
        exit 1
    fi
fi

# 1. Check and install agy
if ! command -v agy &> /dev/null; then
    echo "[INFO] 'agy' not found. Running official installer..."
    curl -fsSL https://antigravity.google/cli/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "[OK] 'agy' is already installed."
fi

# 2. Safely merge ~/.gemini/antigravity-cli/settings.json
SETTINGS_DIR="$HOME/.gemini/antigravity-cli"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
CURRENT_DIR="$(pwd)"

mkdir -p "$SETTINGS_DIR"
echo "[INFO] Updating permissions and trusted workspaces in $SETTINGS_FILE..."

python3 - "$SETTINGS_FILE" "$CURRENT_DIR" << 'EOF'
import json, os, shutil, sys, time

file_path = sys.argv[1]
workspace = sys.argv[2]

def abort(reason):
    # Never overwrite a settings file we couldn't understand: keep a backup and stop.
    backup = f"{file_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(file_path, backup)
    print(f"[ERROR] {reason}")
    print(f"        Your settings were NOT modified. A backup was saved to {backup}")
    print("        Fix the file (e.g. remove trailing commas or comments) and run this script again.")
    sys.exit(1)

data = {}
if os.path.exists(file_path):
    try:
        # Use utf-8-sig to gracefully strip any accidental BOM
        with open(file_path, 'r', encoding='utf-8-sig') as f:
            content = f.read().strip()
        if content:
            data = json.loads(content)
    except Exception as e:
        abort(f"Could not parse existing settings.json: {e}")

if not isinstance(data, dict):
    abort("settings.json must contain a JSON object at the top level.")

perms = data.setdefault("permissions", {})
if not isinstance(perms, dict):
    abort('"permissions" in settings.json must be an object.')
allow = perms.setdefault("allow", [])
deny = perms.setdefault("deny", [])
trusted = data.setdefault("trustedWorkspaces", [])
for key, value in (("permissions.allow", allow), ("permissions.deny", deny), ("trustedWorkspaces", trusted)):
    if not isinstance(value, list):
        abort(f'"{key}" in settings.json must be an array.')

# Read-only commands only. Anything that executes project code (pytest, make, ...)
# or reads file contents (cat, rg, ...) is opt-in; see README "How to Add CLI Skills".
# File writes are allowed only inside this project directory (trustedWorkspaces alone
# does not grant write_file in headless mode; "write_file(*)" would allow any path).
default_allow = [
    f"write_file({workspace.rstrip('/')}/)",
    "command(ls)",
    "command(ls *)",
    "command(git status)",
    "command(git diff)",
    "command(git log)"
]
default_deny = [
    "command(rm -rf *)",
    "command(sudo *)",
    "command(git push --force*)",
    "write_file(.git/)",
    "read_file(.env)"
]

for item in default_allow:
    if item not in allow:
        allow.append(item)

for item in default_deny:
    if item not in deny:
        deny.append(item)

if workspace not in trusted:
    trusted.append(workspace)

with open(file_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[OK] settings.json updated successfully.")
EOF

# 3. Create or append CLAUDE.md (Non-destructive append)
CLAUDE_MD="$CURRENT_DIR/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && grep -q "Antigravity (agy)" "$CLAUDE_MD"; then
    echo "[OK] CLAUDE.md already contains Antigravity rules. Skipping."
else
    echo "[INFO] Appending dynamic delegation rules to $CLAUDE_MD..."
    cat << 'EOF' >> "$CLAUDE_MD"

## Delegating Tasks to Antigravity (agy)

Suitable for delegation: batch multi-file edits, writing unit tests, repo-wide searches, code reviews.
Not suitable: architectural decisions, complex debugging, small single-file edits.

### 1. Dynamic Model Selection (Workload-Based Tiering)
Never hardcode deprecated model IDs. Select the model dynamically based on task complexity:

- **Tier 1 - Routine & Bulk Tasks (Default / Quota-Saving)**:
  - Scope: formatting, regex replacements, boilerplate unit tests, file summaries, comments.
  - Action: **Omit the `--model` flag**. Run `agy -p "..." --output-format json` directly so `agy` uses the user's default lightweight model configured in `settings.json`.
- **Tier 2 - Moderate Multi-File Logic**:
  - Scope: feature implementation across 2-3 files, integration tests, static code review.
  - Action: Run `agy models` once to inspect available models, pick a mid-tier model (e.g., IDs containing `flash-high` or `medium`), and pass `--model <MODEL_ID>`.
- **Tier 3 - Complex Reasoning & Algorithms (High Quota Cost)**:
  - Scope: complex algorithm design, concurrency/race-condition debugging, cross-module refactoring.
  - Action: Run `agy models` to inspect available models, pick a flagship high-reasoning model (e.g., IDs matching `argon-high`, `opus-.*-high`, or `sonnet-.*-high`), and pass `--model <MODEL_ID>`.
  - Note: Cache the output of `agy models` in your context for the rest of the session; do not run it repeatedly.

### 2. Execution & Safety Rules
1. Before calling `agy`, pick the check by task type. Git is optional; never assume the project uses it.
   - **Read-only task** (listing, searching, summarizing): never block on repo state. Forbid writes in the prompt, and afterwards confirm nothing changed (`git status` if the project uses git, otherwise compare the file list).
   - **Task may write files, project uses git:** verify `git status` is clean. If it is not, ask the user; never commit or stash on their behalf.
   - **Task may write files, no git:** tell the user once that changes cannot be diffed, and get their confirmation (or a backup) before calling `agy`.
2. For long or complex instructions, write the spec to `TASK.md` first, then run:
   `agy -p "Execute the instructions in TASK.md" --output-format json [--model <MODEL_ID>]`
3. **Error & Quota Fallback (CRITICAL):**
   - Only adopt `response` when JSON `status` is `SUCCESS` **and** `response` is non-empty. An empty `response`, a non-empty `denied_actions`, or a `no output produced — a tool required the "command" permission` message in `stderr` means the task was soft-denied: treat it as a failure, do not adopt it, and tell the user which command needs to be added to `permissions.allow`.
   - If `stderr` indicates a "Quota Exceeded", "429 Too Many Requests", or soft-denied command error:
     **DO NOT** automatically fallback to executing the large batch task yourself. You MUST stop immediately, report the exact error to the user, and ask for their explicit decision on how to proceed (e.g., wait for quota refresh, or proceed using Claude's own quota).
4. To continue an existing session, pass `--conversation <conversation_id>`.
5. After completion, review the changes (`git diff` if the project uses git, otherwise compare against the backup or file list) and execute tests.
6. Never ask `agy` to read or write `.env`, private keys, or `.git/`.
EOF
    echo "[OK] CLAUDE.md updated with dynamic model tiering rules."
fi

echo "------------------------------------------------------------------------"
echo "[DONE] Setup complete."
echo "[NEXT] If you haven't logged in yet, run 'agy' once to authenticate,"
echo "       then type '/exit' to return to your shell."