# Integration test for setup.ps1 (Windows). Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File .\scripts\test-setup-ps1.ps1
# It never calls exit, so it cannot close your PowerShell window.
# It backs up your real agy settings.json first and always restores it at the end.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = "Continue"
$Setup = Join-Path (Split-Path -Parent $PSScriptRoot) "setup.ps1"
$Dir = Join-Path $HOME ".gemini\antigravity-cli"
$File = Join-Path $Dir "settings.json"
$Keep = Join-Path $env:TEMP "settings.json.user-backup"
$Proj = Join-Path $env:TEMP "agy-test-proj"
$ClaudeMd = Join-Path $Proj "CLAUDE.md"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Fail = 0

function Check($Name, $Ok) {
    if ($Ok) { "PASS  $Name" } else { "FAIL  $Name"; $script:Fail++ }
}

function Run-Setup {
    Push-Location $Proj
    $Out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Setup 2>&1 | Out-String)
    $Code = $LASTEXITCODE
    Pop-Location
    return [pscustomobject]@{ Out = $Out; Code = $Code }
}

function Reset-Baks {
    Get-ChildItem $Dir -Filter "settings.json.bak-*" -ErrorAction SilentlyContinue | Remove-Item -Force
}

function Read-Settings {
    return (Get-Content $File -Raw | ConvertFrom-Json)
}

$HadReal = Test-Path $File
if ($HadReal) { Copy-Item $File $Keep -Force }
New-Item -ItemType Directory -Force $Dir, $Proj | Out-Null
$env:AGY_BRIDGE_FORCE = "1"

try {
    # 1. Fresh install
    Remove-Item $File -Force -ErrorAction SilentlyContinue
    Reset-Baks
    Remove-Item $ClaudeMd -Force -ErrorAction SilentlyContinue
    $r = Run-Setup
    Check "fresh: exit 0 and [DONE]" (($r.Code -eq 0) -and ($r.Out -match "\[DONE\]"))
    $j = Read-Settings
    Check "fresh: allow is an array" ($j.permissions.allow -is [array])
    Check "fresh: write_file rule present" (@($j.permissions.allow | Where-Object { $_ -like "write_file(*" }).Count -ge 1)
    Check "fresh: no BOM" ([IO.File]::ReadAllBytes($File)[0] -ne 0xEF)
    Check "fresh: no leftover .tmp" (-not (Test-Path "$File.tmp"))
    Check "fresh: CLAUDE.md created" (Test-Path $ClaudeMd)

    # 1b. The v4 rules block survived PowerShell here-string escaping
    $md = Get-Content $ClaudeMd -Raw
    Check "rules: marker is v4" ($md -match "agy-bridge:start v4")
    $UsageCmd = '`agy -p "/usage" --output-format json --print-timeout 60s`'
    Check "rules: /usage command intact" ($md.Contains($UsageCmd))
    Check "rules: no doubled backticks" (-not $md.Contains('``'))
    Check "rules: section 1b present" ($md -match "Quota-Aware Model Choice")
    Check "rules: quota keywords present" (($md -match "quota reached") -and ($md -match "remaining_fraction"))

    # 2. Re-run adds no duplicates
    $n1 = @((Read-Settings).permissions.allow).Count
    $r = Run-Setup
    $n2 = @((Read-Settings).permissions.allow).Count
    Check "rerun: allow count unchanged ($n1 -> $n2)" ($n1 -eq $n2)
    $md = Get-Content $ClaudeMd -Raw
    $Blocks = [regex]::Matches($md, "agy-bridge:start").Count
    Check "rerun: exactly one agy-bridge block" ($Blocks -eq 1)

    # 2b. An old v3 block is upgraded in place, user text around it is kept
    $Old = "# Mine`nkeep-top`n`n<!-- agy-bridge:start v3 -->`nold rules`n<!-- agy-bridge:end -->`n`nkeep-bottom"
    [IO.File]::WriteAllText($ClaudeMd, $Old, $Utf8)
    $r = Run-Setup
    $md = Get-Content $ClaudeMd -Raw
    Check "upgrade: v3 replaced by v4" (($md -match "start v4") -and ($md -notmatch "old rules"))
    Check "upgrade: user text kept" (($md -match "keep-top") -and ($md -match "keep-bottom"))

    # 3. Malformed settings: abort, make a .bak, leave the file untouched
    $Bad = [ordered]@{
        "permissions null"         = '{"permissions": null}'
        "allow is string"          = '{"permissions": {"allow": "command(ls)"}}'
        "trustedWorkspaces string" = '{"trustedWorkspaces": "x"}'
        "permissions is array"     = '{"permissions": []}'
        "invalid JSON"             = '{"permissions": '
    }
    foreach ($Key in $Bad.Keys) {
        Reset-Baks
        [IO.File]::WriteAllText($File, $Bad[$Key], $Utf8)
        $r = Run-Setup
        $Same = ([IO.File]::ReadAllText($File) -eq $Bad[$Key])
        $Bak = @(Get-ChildItem $Dir -Filter "settings.json.bak-*").Count -ge 1
        $Aborted = ($r.Code -ne 0) -and ($r.Out -match "NOT modified")
        Check "bad [$Key]: aborts, .bak made, file untouched" ($Aborted -and $Same -and $Bak)
    }

    # 4. Valid edge cases must pass
    $Valid = @('{"permissions": {"allow": []}}', '{"permissions": {"allow": null}}', '{}')
    foreach ($Json in $Valid) {
        [IO.File]::WriteAllText($File, $Json, $Utf8)
        $r = Run-Setup
        $j = Read-Settings
        Check "valid [$Json]: passes, allow is array" (($r.Code -eq 0) -and ($j.permissions.allow -is [array]))
    }

    # 5. A single-element array is not flattened (Windows PowerShell 5.1)
    [IO.File]::WriteAllText($File, '{"trustedWorkspaces": ["C:\\only"]}', $Utf8)
    $r = Run-Setup
    Check "single-element trustedWorkspaces stays an array" ((Get-Content $File -Raw) -match '"trustedWorkspaces":\s*\[')
}
finally {
    if ($HadReal) { Copy-Item $Keep $File -Force } else { Remove-Item $File -Force -ErrorAction SilentlyContinue }
    Reset-Baks
    Remove-Item $Proj -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:AGY_BRIDGE_FORCE -ErrorAction SilentlyContinue
    ""
    "$script:Fail failure(s). Your real settings.json was restored."
}
