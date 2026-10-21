# Safely lets agy run more shell commands in headless mode (agy -p), by adding
# "command(...)" rules to permissions.allow in $HOME\.gemini\antigravity-cli\settings.json.
#
#   .\scripts\allow.ps1 "npm test" pytest     add rules (one per argument)
#   .\scripts\allow.ps1 --list                 show the current allow / deny rules
#   .\scripts\allow.ps1 --remove pytest        remove rules
#   .\scripts\allow.ps1 --yes rg               skip the confirmation some commands need
#
# If local scripts are blocked:
#   powershell -ExecutionPolicy Bypass -File .\scripts\allow.ps1 "npm test"
# Without a checkout of this repo:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.4.0/scripts/allow.ps1))) "npm test"
#
# Rules are prefix matches: "npm test" also allows "npm test -- --watch". The settings file is
# global, so a rule applies to every project. Never touches anything but permissions.allow.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = "Stop"

# Returns the exit code (0 = everything requested is allowed / removed / listed).
function Invoke-Allow([object[]]$ArgList) {
# AGY_BRIDGE_SETTINGS points at another settings file (used by the tests).
$SettingsFile = if ($env:AGY_BRIDGE_SETTINGS) { $env:AGY_BRIDGE_SETTINGS } else { Join-Path $HOME ".gemini\antigravity-cli\settings.json" }

# First word of the rule (lowercase, without a directory or .exe/.cmd/.bat/.ps1).
# Always refused: they delete, escalate, download, re-run arbitrary commands, or call agy itself.
$Blocked = @(
    "agy", "rm", "rmdir", "del", "erase", "rd", "ri", "remove-item", "sudo", "su", "doas", "runas",
    "dd", "mkfs", "format", "shutdown", "reboot", "chmod", "chown", "icacls", "takeown",
    "curl", "wget", "scp", "ssh", "nc", "invoke-webrequest", "iwr", "invoke-restmethod", "irm",
    "invoke-expression", "iex", "start-process", "eval", "exec", "xargs", "env", "nohup", "nice",
    "timeout", "watch", "time", "command", "builtin", "set-executionpolicy", "reg", "setx"
)
# Refused when allowed on their own (they would run any code or any subcommand);
# a longer prefix such as "python -m pytest" or "docker compose ps" is fine.
$BareBlocked = @(
    "bash", "sh", "zsh", "fish", "dash", "ksh", "pwsh", "powershell", "cmd", "wsl",
    "python", "python3", "py", "node", "deno", "bun", "ruby", "perl", "php", "lua", "java",
    "npx", "pnpx", "bunx", "uvx", "osascript",
    "docker", "kubectl", "helm", "terraform", "gh", "aws", "gcloud", "az"
)
# Need a confirmation: they print file contents, so they can show .env and other secrets
# ("read_file(.env)" in deny only covers agy's read_file tool, not shell commands).
$ContentReaders = @(
    "cat", "tac", "type", "get-content", "gc", "head", "tail", "less", "more", "bat", "nl",
    "rg", "grep", "egrep", "fgrep", "ag", "ack", "select-string", "sls", "findstr",
    "jq", "yq", "sed", "awk", "find", "fd", "strings", "od", "xxd", "hexdump", "base64",
    "cut", "sort", "uniq"
)
# Need a confirmation when allowed on their own: they also install packages and run any script.
$BroadRunners = @(
    "npm", "pnpm", "yarn", "pip", "pip3", "uv", "poetry", "cargo", "go", "make", "gradle",
    "gradlew", "mvn", "dotnet", "composer", "bundle", "rake", "cmake", "ninja"
)

function Show-Usage {
    Write-Host "Usage: allow.ps1 [--yes] <command>...   add rules, e.g. allow.ps1 `"npm test`" pytest"
    Write-Host "       allow.ps1 --list                  show the current allow / deny rules"
    Write-Host "       allow.ps1 --remove <command>...   remove rules"
    Write-Host "       allow.ps1 --autonomous            activate Autonomous Mode (command(*))"
    Write-Host "       allow.ps1 --strict                restore Strict Safe Mode (remove command(*))"
}

function ConvertTo-CommandText([string]$Text) {
    $s = $Text.Trim()
    if ($s -match '^command\((.*)\)$') { $s = $Matches[1].Trim() }
    # A trailing " *" does not work in agy: rules are already prefix matches.
    $s = ($s -replace '\s*\*$', '').Trim()
    return ($s -replace '[ \t]+', ' ')
}

function Get-FirstWord([string]$Cmd) {
    $Word = (($Cmd.Split(' ')[0]) -split '[\\/]')[-1].ToLower()
    return ($Word -replace '\.(exe|cmd|bat|ps1)$', '')
}

# Returns @(verdict, reason): verdict is ok, confirm or block.
function Get-Verdict([string]$Cmd, $Deny) {
    if ((-not $Cmd) -or $Cmd.Contains('*')) {
        return @("block", "wildcards are not supported (rules are prefix matches) and '*' would allow everything")
    }
    if ($Cmd -match '[|;&<>`\r\n]|\$\(') {
        return @("block", "contains shell operators (| ; & < > `` `$( ); agy blocks compound commands anyway")
    }
    foreach ($Rule in @($Deny)) {
        if ([string]$Rule -match '^command\((.*)\)$') {
            $Prefix = $Matches[1]
            if (($Cmd -eq $Prefix) -or $Cmd.StartsWith("$Prefix ")) {
                return @("block", "it matches your deny rule $Rule")
            }
        }
    }
    $Word = Get-FirstWord $Cmd
    $Single = -not $Cmd.Contains(' ')
    if ($Word -eq "agy") {
        return @("block", "agy must never call itself (runaway self-recursion and quota use)")
    }
    if ($Blocked -contains $Word) {
        return @("block", "'$Word' can delete files, escalate privileges, download, or run other commands")
    }
    if (($BareBlocked -contains $Word) -and $Single) {
        return @("block", "'$Cmd' on its own would let agy run any code; allow a narrower prefix such as 'python -m pytest'")
    }
    if ($ContentReaders -contains $Word) {
        return @("confirm", "it prints file contents, so agy could show .env or other secrets (deny read_file(.env) does not stop it)")
    }
    if (($BroadRunners -contains $Word) -and $Single) {
        return @("confirm", "'$Cmd' on its own also installs packages and runs any script; '$Cmd test' is safer")
    }
    return @("ok", "")
}

# Parse arguments.
$Mode = "add"; $Yes = $false; $Cmds = New-Object System.Collections.ArrayList
foreach ($A in $ArgList) {
    switch -Regex ([string]$A) {
        '^(-h|--help|-\?)$' { $Mode = "help" }
        '^(-l|--list)$' { $Mode = "list" }
        '^(-r|--remove)$' { $Mode = "remove" }
        '^(-y|--yes)$' { $Yes = $true }
        '^(--autonomous|--auto|-a)$' { $Mode = "autonomous" }
        '^(--strict|--restore-strict)$' { $Mode = "strict" }
        default { [void]$Cmds.Add([string]$A) }
    }
}
if ($Mode -eq "help") { Show-Usage; return 0 }

# Load settings.json. Never write a file we could not understand.
$Data = New-Object PSObject
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $Raw = [System.IO.File]::ReadAllText($SettingsFile, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        if ($Raw.Trim()) { $Data = $Raw | ConvertFrom-Json }
    } catch {
        throw "[ERROR] Could not parse $SettingsFile ($($_.Exception.Message)). Nothing was changed. Fix the file and run again."
    }
    if (($Data -is [array]) -or ($Data -is [string]) -or ($Data -is [ValueType])) {
        throw "[ERROR] settings.json must contain a JSON object. Nothing was changed."
    }
}
$PermProp = $Data.PSObject.Properties["permissions"]
if ($PermProp) {
    if (($null -eq $PermProp.Value) -or ($PermProp.Value -is [array]) -or ($PermProp.Value -is [string]) -or ($PermProp.Value -is [ValueType])) {
        throw '[ERROR] "permissions" in settings.json must be an object. Nothing was changed.'
    }
} else {
    $Data | Add-Member -MemberType NoteProperty -Name "permissions" -Value (New-Object PSObject)
}
foreach ($Key in "allow", "deny") {
    $Field = $Data.permissions.PSObject.Properties[$Key]
    if (-not $Field) {
        $Data.permissions | Add-Member -MemberType NoteProperty -Name $Key -Value @()
    } elseif (($null -ne $Field.Value) -and -not ($Field.Value -is [array])) {
        throw "[ERROR] `"permissions.$Key`" in settings.json must be an array. Nothing was changed."
    }
}
$AllowList = [System.Collections.ArrayList]@(@($Data.permissions.allow) | Where-Object { $null -ne $_ })
$DenyList = @(@($Data.permissions.deny) | Where-Object { $null -ne $_ })

function Save-Settings-File {
    $Data.permissions.allow = [string[]]$AllowList
    $Data.permissions.deny = [string[]]$DenyList
    $Dir = Split-Path $SettingsFile
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $Tmp = "$SettingsFile.tmp"
    [System.IO.File]::WriteAllText($Tmp, ($Data | ConvertTo-Json -Depth 10), $Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $SettingsFile -Force
    Write-Host "Saved $SettingsFile. Rules apply to every project; undo with --remove or --strict."
}

if ($Mode -eq "autonomous") {
    $Changed = $false
    if (-not $AllowList.Contains("command(*)")) {
        [void]$AllowList.Add("command(*)")
        $Changed = $true
    }
    $EssentialDeny = @("command(rm -rf)", "command(Remove-Item)", "command(rmdir)", "command(del)", "command(sudo)", "command(git push --force)", "command(git push -f)", "command(agy)", "write_file(.git/)", "read_file(.env)")
    $DenyArr = [System.Collections.ArrayList]@($DenyList)
    foreach ($d in $EssentialDeny) {
        if (-not $DenyArr.Contains($d)) { [void]$DenyArr.Add($d); $Changed = $true }
    }
    $DenyList = [string[]]$DenyArr
    if ($Changed) { Save-Settings-File }
    Write-Host "[OK] Autonomous Mode activated: 'command(*)' added to permissions.allow."
    Write-Host "     agy can run general commands freely without soft-denials."
    Write-Host "     High-risk operations (rm, sudo, git push -f, .env, agy) remain strictly blocked by deny rules."
    return 0
}

if ($Mode -eq "strict") {
    if ($AllowList.Contains("command(*)")) {
        $AllowList.Remove("command(*)")
        Save-Settings-File
        Write-Host "[OK] Strict Safe Mode restored: 'command(*)' removed from permissions.allow."
    } else {
        Write-Host "[INFO] 'command(*)' was not present. Already in Strict Safe Mode."
    }
    return 0
}

if ($Mode -eq "list") {
    Write-Host "Settings: $SettingsFile"
    Write-Host "allow:"
    foreach ($R in $AllowList) { Write-Host "  $R" }
    Write-Host "deny:"
    foreach ($R in $DenyList) { Write-Host "  $R" }
    return 0
}
if ($Cmds.Count -eq 0) { Show-Usage; return 1 }

$Failed = 0; $Changed = $false
foreach ($A in $Cmds) {
    $Cmd = ConvertTo-CommandText $A
    $Rule = "command($Cmd)"
    if ($Mode -eq "remove") {
        if ($AllowList.Contains($Rule)) {
            $AllowList.Remove($Rule); $Changed = $true
            Write-Host "[OK] Removed $Rule"
        } else {
            Write-Host "[INFO] $Rule was not in permissions.allow"
        }
        continue
    }
    if ($AllowList.Contains($Rule)) { Write-Host "[OK] $Rule is already allowed"; continue }
    $Verdict = Get-Verdict $Cmd $DenyList
    if ($Verdict[0] -eq "block") {
        Write-Host "[REFUSED] ${Rule}: $($Verdict[1])" -ForegroundColor Red
        $Failed++
        continue
    }
    if (($Verdict[0] -eq "confirm") -and -not $Yes) {
        Write-Host "[CAUTION] ${Rule}: $($Verdict[1])" -ForegroundColor Yellow
        $Ok = $false
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $Reply = Read-Host "          Allow it anyway? [y/N]"
            $Ok = ($Reply -match '^(y|yes)$')
        } else {
            Write-Host "          No terminal to confirm. Re-run with --yes if you are sure."
        }
        if (-not $Ok) { Write-Host "[SKIPPED] $Rule"; $Failed++; continue }
    }
    [void]$AllowList.Add($Rule); $Changed = $true
    Write-Host "[OK] Allowed $Rule"
}

if ($Changed) {
    Save-Settings-File
}
if ($Failed -gt 0) { return 1 }
return 0
}

$ExitCode = 0
try {
    # Last item only, in case anything above ever writes to the pipeline.
    $ExitCode = @(Invoke-Allow $args)[-1]
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $ExitCode = 1
}
# Only exit when run as a file, so running it from a scriptblock cannot close the window.
if ($MyInvocation.MyCommand.Path) { exit $ExitCode }
