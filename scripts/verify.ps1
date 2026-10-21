# Checks that setup.ps1 worked for the project in the current directory (Windows).
# Run it from your project root, after setup.ps1:
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
# It never calls a model, so it costs no quota. The exit code is the number of FAIL lines.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = "Continue"
$ExpectedRules = "v5"
$ProjectDir = (Get-Location).ProviderPath.TrimEnd('\')
$Settings = Join-Path $HOME ".gemini\antigravity-cli\settings.json"
$TargetArg = if ($args.Count -gt 0 -and $args[0]) { [string]$args[0] } elseif ($env:AGY_BRIDGE_TARGETS) { $env:AGY_BRIDGE_TARGETS } else { "all" }
if ($TargetArg -match '^(--claude|--claude-only|claude|CLAUDE\.md)$') {
    $TargetDocs = @("CLAUDE.md")
} elseif ($TargetArg -match '^(--agents|--agents-only|--codex|agents|codex|AGENTS\.md)$') {
    $TargetDocs = @("AGENTS.md")
} else {
    $TargetDocs = @("CLAUDE.md", "AGENTS.md")
}
$script:Fail = 0

function Pass($Msg) { "PASS  $Msg" }
function Warn($Msg) { "WARN  $Msg" }
function Bad($Msg) { "FAIL  $Msg"; $script:Fail++ }
function Check($Ok, $Msg) { if ($Ok) { Pass $Msg } else { Bad $Msg } }

"Verifying agy-bridge in $ProjectDir"

# 1. agy is installed and answers (the /usage query runs no model)
$Agy = Get-Command agy -ErrorAction SilentlyContinue
if ($Agy) {
    Pass "agy found: $($Agy.Source)"
    $Usage = $null
    try {
        $Raw = (& agy -p "/usage" --output-format json --print-timeout 30s 2>$null | Out-String)
        $Usage = $Raw | ConvertFrom-Json
    } catch { }
    if ($Usage -and $Usage.command -and $Usage.command.data.groups) {
        foreach ($G in $Usage.command.data.groups) {
            $Parts = @($G.buckets | ForEach-Object { "{0} {1}%" -f $_.window, [math]::Round($_.remaining_fraction * 100) })
            "INFO  quota group $($G.name): $($Parts -join ', ')"
        }
    } else {
        Warn "agy /usage gave no usable output (not logged in yet? run 'agy' once to sign in)"
    }
} else {
    Bad "agy is not on PATH (open a new PowerShell window)"
}

# 2. settings.json
$Data = $null
if (-not (Test-Path -LiteralPath $Settings)) {
    Bad "settings.json not found at $Settings (run setup.ps1)"
} else {
    $Bytes = [System.IO.File]::ReadAllBytes($Settings)
    $HasBom = ($Bytes.Length -ge 3) -and ($Bytes[0] -eq 0xEF) -and ($Bytes[1] -eq 0xBB) -and ($Bytes[2] -eq 0xBF)
    Check (-not $HasBom) "settings.json has no UTF-8 BOM"
    try {
        $Text = [System.Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
        $Data = $Text | ConvertFrom-Json
    } catch {
        Bad "settings.json is not valid JSON: $($_.Exception.Message)"
    }
}
if ($Data) {
    $Perms = $Data.PSObject.Properties["permissions"]
    $PermsOk = $Perms -and $Perms.Value -and -not ($Perms.Value -is [array]) -and -not ($Perms.Value -is [string])
    if (-not $PermsOk) {
        Bad '"permissions" is missing or not an object'
    } else {
        $Allow = $Perms.Value.allow
        $Deny = $Perms.Value.deny
        $Trusted = $Data.trustedWorkspaces
        Check ($Allow -is [array]) "permissions.allow is an array"
        Check ($Deny -is [array]) "permissions.deny is an array"
        Check ($Trusted -is [array]) "trustedWorkspaces is an array"
        $Rule = "write_file($ProjectDir\)"
        Check (@($Allow) -contains $Rule) "write rule for this project: $Rule"
        Check (@($Trusted) -contains $ProjectDir) "project is a trusted workspace"
        foreach ($R in "write_file(.git/)", "read_file(.env)") {
            Check (@($Deny) -contains $R) "deny rule present: $R"
        }
    }
}

# 3. CLAUDE.md / AGENTS.md
foreach ($DocName in $TargetDocs) {
    $MdPath = Join-Path $ProjectDir $DocName
    if (-not (Test-Path -LiteralPath $MdPath)) {
        Bad "$DocName not found in the project root (run setup.ps1 here)"
    } else {
        $MdBytes = [System.IO.File]::ReadAllBytes($MdPath)
        $MdHasBom = ($MdBytes.Length -ge 3) -and ($MdBytes[0] -eq 0xEF) -and ($MdBytes[1] -eq 0xBB) -and ($MdBytes[2] -eq 0xBF)
        Check (-not $MdHasBom) "$DocName has no UTF-8 BOM"
        $Md = [System.IO.File]::ReadAllText($MdPath)
        $Starts = [regex]::Matches($Md, '(?m)^<!-- agy-bridge:start (v\d+) -->\r?$')
        $Ends = [regex]::Matches($Md, '(?m)^<!-- agy-bridge:end -->\r?$')
        if (($Starts.Count -ne 1) -or ($Ends.Count -ne 1)) {
            Bad "$DocName must contain exactly one agy-bridge block (found $($Starts.Count) start, $($Ends.Count) end)"
        } else {
            $Version = $Starts[0].Groups[1].Value
            Check ($Version -eq $ExpectedRules) "$DocName rules version is $Version (expected $ExpectedRules)"
            $Block = $Md.Substring($Starts[0].Index)
            Check (-not $Block.Contains('``')) "$DocName rules block has no doubled backticks"
            Check ($Block.Contains('`agy -p "/usage"')) "$DocName rules block mentions the /usage quota check"
        }
    }
}

""
"$script:Fail failure(s)."
# Only exit when run as a file, so pasting this into a console cannot close the window.
if ($MyInvocation.MyCommand.Path) { exit $script:Fail }
