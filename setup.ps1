$ErrorActionPreference = "Stop"
Write-Host "[INFO] Initializing Claude Code x Antigravity (agy) integration (Windows)..."

# 0. Make sure we're in a project directory. This directory becomes a trusted,
#    writable workspace for agy, so refuse $HOME or a drive root and confirm non-git folders.
#    Use 'throw' rather than 'exit': under 'irm | iex', exit would close the user's window.
$CheckDir = (Get-Location).ProviderPath.TrimEnd('\')
$HomeDir = ([System.IO.Path]::GetFullPath($HOME)).TrimEnd('\')
$RootDir = ([System.IO.Path]::GetPathRoot($CheckDir)).TrimEnd('\')
if (($CheckDir -ieq $HomeDir) -or ($CheckDir -ieq $RootDir)) {
    throw "[ERROR] Refusing to run in '$CheckDir'. This directory would become writable by agy. cd into your project root and run again."
}
$IsGitRepo = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    & git -C $CheckDir rev-parse --is-inside-work-tree 2>$null | Out-Null
    $IsGitRepo = ($LASTEXITCODE -eq 0)
} else {
    $IsGitRepo = Test-Path (Join-Path $CheckDir ".git")
}
if (-not $IsGitRepo) {
    Write-Host "[WARN] '$CheckDir' is not a git repository."
    Write-Host "       agy will be allowed to write anywhere under this directory."
    if ($env:AGY_BRIDGE_FORCE -eq "1") {
        Write-Host "[INFO] AGY_BRIDGE_FORCE=1 set, continuing."
    } elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $Reply = Read-Host "       Continue anyway? [y/N]"
        if ($Reply -notmatch '^(y|yes)$') {
            throw "[INFO] Aborted. Nothing was changed."
        }
    } else {
        throw "[ERROR] No terminal to confirm. Set `$env:AGY_BRIDGE_FORCE='1' if this is really your project root."
    }
}

# 1. Check and install agy
if (-not (Get-Command agy -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] 'agy' not found. Running official installer..."
    irm https://antigravity.google/cli/install.ps1 | iex
    
    # Reload PATH in current session so user doesn't have to restart immediately
    $AgyBin = Join-Path $env:LOCALAPPDATA "agy\bin"
    if ((Test-Path $AgyBin) -and ($env:Path -notlike "*$AgyBin*")) {
        $env:Path = "$AgyBin;$env:Path"
        Write-Host "[INFO] Added $AgyBin to current session PATH."
    }
} else {
    Write-Host "[OK] 'agy' is already installed."
}

# 2. Safely merge $HOME\.gemini\antigravity-cli\settings.json (PS 5.1 & PS 7+ compatible)
$SettingsDir = Join-Path $HOME ".gemini\antigravity-cli"
$SettingsFile = Join-Path $SettingsDir "settings.json"
$CurrentDir = (Get-Location).Path

if (-not (Test-Path $SettingsDir)) {
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null
}

$Data = New-Object PSObject
if (Test-Path $SettingsFile) {
    try {
        $RawJson = [System.IO.File]::ReadAllText($SettingsFile, [System.Text.Encoding]::UTF8)
        # Strip BOM if present from previous manual edits
        $RawJson = $RawJson.TrimStart([char]0xFEFF)
        if ($RawJson.Trim()) {
            $Data = $RawJson | ConvertFrom-Json
        }
    } catch {
        # Never overwrite a settings file we couldn't understand: keep a backup and stop.
        $Backup = "$SettingsFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $SettingsFile -Destination $Backup
        throw "[ERROR] Could not parse existing settings.json ($($_.Exception.Message)). Your settings were NOT modified; backup saved to $Backup. Fix the file (e.g. remove trailing commas or comments) and run this script again."
    }
    # Note: '-is [PSCustomObject]' matches almost anything in PowerShell, so reject non-objects explicitly.
    if (($Data -is [array]) -or ($Data -is [string]) -or ($Data -is [ValueType])) {
        throw "[ERROR] settings.json must contain a JSON object at the top level. Your settings were NOT modified."
    }
}

if (-not ($Data.PSObject.Properties.Name -contains "permissions")) {
    $Data | Add-Member -MemberType NoteProperty -Name "permissions" -Value (New-Object PSObject)
}
if (-not ($Data.permissions.PSObject.Properties.Name -contains "allow")) {
    $Data.permissions | Add-Member -MemberType NoteProperty -Name "allow" -Value @()
}
if (-not ($Data.permissions.PSObject.Properties.Name -contains "deny")) {
    $Data.permissions | Add-Member -MemberType NoteProperty -Name "deny" -Value @()
}
if (-not ($Data.PSObject.Properties.Name -contains "trustedWorkspaces")) {
    $Data | Add-Member -MemberType NoteProperty -Name "trustedWorkspaces" -Value @()
}

$AllowList = [System.Collections.ArrayList]@($Data.permissions.allow)
$DenyList = [System.Collections.ArrayList]@($Data.permissions.deny)
$TrustedList = [System.Collections.ArrayList]@($Data.trustedWorkspaces)

# Read-only commands only. Anything that executes project code (pytest, npm, ...)
# or reads file contents (cat, rg, ...) is opt-in; see README "How to Add CLI Skills".
# File writes are allowed only inside this project directory (trustedWorkspaces alone
# does not grant write_file in headless mode; "write_file(*)" would allow any path).
$DefaultAllow = @(
    "write_file($($CurrentDir.TrimEnd('\'))\)",
    "command(ls)",
    "command(ls *)",
    "command(dir)",
    "command(dir *)",
    "command(Get-ChildItem)",
    "command(Get-ChildItem *)",
    "command(git status)",
    "command(git diff)",
    "command(git log)"
)
$DefaultDeny = @(
    "command(regex:(rm -rf|Remove-Item|rmdir /s /q|del /f /s /q).*)",
    "command(sudo *)",
    "command(git push --force*)",
    "write_file(.git/)",
    "read_file(.env)"
)

foreach ($item in $DefaultAllow) {
    if (-not $AllowList.Contains($item)) { [void]$AllowList.Add($item) }
}
foreach ($item in $DefaultDeny) {
    if (-not $DenyList.Contains($item)) { [void]$DenyList.Add($item) }
}
if (-not $TrustedList.Contains($CurrentDir)) {
    [void]$TrustedList.Add($CurrentDir)
}

$Data.permissions.allow = @($AllowList)
$Data.permissions.deny = @($DenyList)
$Data.trustedWorkspaces = @($TrustedList)

$JsonOut = $Data | ConvertTo-Json -Depth 10
# CRITICAL: Write as UTF-8 WITHOUT BOM (\ufeff) to prevent agy settings malformed error
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($SettingsFile, $JsonOut, $Utf8NoBom)
Write-Host "[OK] settings.json updated successfully (UTF-8 no BOM)."

# 3. Create or append CLAUDE.md (Non-destructive append)
$ClaudeMd = Join-Path $CurrentDir "CLAUDE.md"
$RuleContent = @"

## Delegating Tasks to Antigravity (agy)

Suitable for delegation: batch multi-file edits, writing unit tests, repo-wide searches, code reviews.
Not suitable: architectural decisions, complex debugging, small single-file edits.

### 1. Dynamic Model Selection (Workload-Based Tiering)
Never hardcode deprecated model IDs. Select the model dynamically based on task complexity:

- **Tier 1 - Routine & Bulk Tasks (Default / Quota-Saving)**:
  - Scope: formatting, regex replacements, boilerplate unit tests, file summaries, comments.
  - Action: **Omit the ``--model`` flag**. Run ``agy -p "..." --output-format json`` directly so ``agy`` uses the user's default lightweight model configured in ``settings.json``.
- **Tier 2 - Moderate Multi-File Logic**:
  - Scope: feature implementation across 2-3 files, integration tests, static code review.
  - Action: Run ``agy models`` once to inspect available models, pick a mid-tier model (e.g., IDs containing ``flash-high`` or ``medium``), and pass ``--model <MODEL_ID>``.
- **Tier 3 - Complex Reasoning & Algorithms (High Quota Cost)**:
  - Scope: complex algorithm design, concurrency/race-condition debugging, cross-module refactoring.
  - Action: Run ``agy models`` to inspect available models, pick a flagship high-reasoning model (e.g., IDs matching ``argon-high``, ``opus-.*-high``, or ``sonnet-.*-high``), and pass ``--model <MODEL_ID>``.
  - Note: Cache the output of ``agy models`` in your context for the rest of the session; do not run it repeatedly.

### 2. Execution & Safety Rules
1. Before calling ``agy``, pick the check by task type. Git is optional; never assume the project uses it.
   - **Read-only task** (listing, searching, summarizing): never block on repo state. Forbid writes in the prompt, and afterwards confirm nothing changed (``git status`` if the project uses git, otherwise compare the file list).
   - **Task may write files, project uses git:** verify ``git status`` is clean. If it is not, ask the user; never commit or stash on their behalf.
   - **Task may write files, no git:** tell the user once that changes cannot be diffed, and get their confirmation (or a backup) before calling ``agy``.
2. For long or complex instructions, write the spec to ``TASK.md`` first, then run:
   ``agy -p "Execute the instructions in TASK.md" --output-format json [--model <MODEL_ID>]``
3. **Error & Quota Fallback (CRITICAL):**
   - Only adopt ``response`` when JSON ``status`` is ``SUCCESS`` **and** ``response`` is non-empty. An empty ``response``, a non-empty ``denied_actions``, or a ``no output produced — a tool required the "command" permission`` message in ``stderr`` means the task was soft-denied: treat it as a failure, do not adopt it, and tell the user which command needs to be added to ``permissions.allow``.
   - If ``stderr`` indicates a "Quota Exceeded", "429 Too Many Requests", or soft-denied command error:
     **DO NOT** automatically fallback to executing the large batch task yourself. You MUST stop immediately, report the exact error to the user, and ask for their explicit decision on how to proceed (e.g., wait for quota refresh, or proceed using Claude's own quota).
4. To continue an existing session, pass ``--conversation <conversation_id>``.
5. After completion, review the changes (``git diff`` if the project uses git, otherwise compare against the backup or file list) and execute tests.
6. Never ask ``agy`` to read or write ``.env``, private keys, or ``.git/``.
"@

if ((Test-Path $ClaudeMd) -and ([System.IO.File]::ReadAllText($ClaudeMd) -match [regex]::Escape("Antigravity (agy)"))) {
    Write-Host "[OK] CLAUDE.md already contains Antigravity rules. Skipping."
} else {
    [System.IO.File]::AppendAllText($ClaudeMd, $RuleContent, $Utf8NoBom)
    Write-Host "[OK] CLAUDE.md updated with dynamic model tiering rules."
}

Write-Host "------------------------------------------------------------------------"
Write-Host "[DONE] Setup complete. Run 'agy' once to authenticate if you haven't already, then type '/exit'."