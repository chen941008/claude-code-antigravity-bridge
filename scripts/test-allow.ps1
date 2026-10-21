# Offline unit test for scripts/allow.ps1 (no agy, no network, no quota).
$ErrorActionPreference = "Stop"
$Repo = Split-Path $PSScriptRoot -Parent
$Allow = Join-Path $Repo "scripts\allow.ps1"
$Tmp = Join-Path $env:TEMP "agy-allow-test-$PID"
New-Item -ItemType Directory -Force $Tmp | Out-Null
$S = Join-Path $Tmp "settings.json"
$env:AGY_BRIDGE_SETTINGS = $S
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($S, '{"model":"keep-me","permissions":{"allow":["command(ls)"],"deny":["command(rm -rf)","command(git push -f)"]},"trustedWorkspaces":["C:\\x"]}', $utf8)

$fails = 0
function Run([string[]]$A) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Allow @A 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect($Name, $Cond) {
    if ($Cond) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:fails++
    }
}
function Allowed { @((Get-Content $S -Raw | ConvertFrom-Json).permissions.allow) }

try {
    $r = Run @("npm test", "pytest");            Expect "add two rules" ($r.Code -eq 0 -and ((Allowed) -contains "command(npm test)") -and ((Allowed) -contains "command(pytest)"))
    $r = Run @("npm test *");                    Expect "trailing * normalized to existing rule" ($r.Code -eq 0 -and ($r.Out -match "already allowed"))
    $r = Run @("command(go test)");              Expect "command(...) form normalized" ((Allowed) -contains "command(go test)")
    $r = Run @("rm -rf build");                  Expect "rm refused" ($r.Code -eq 1 -and ($r.Out -match "REFUSED"))
    $r = Run @("git push -f origin");            Expect "deny conflict refused" ($r.Code -eq 1 -and ($r.Out -match "deny rule"))
    $r = Run @("python");                        Expect "bare python refused" ($r.Code -eq 1 -and -not ((Allowed) -contains "command(python)"))
    $r = Run @("python -m pytest");              Expect "python -m pytest allowed" ((Allowed) -contains "command(python -m pytest)")
    $r = Run @("ls | cat");                      Expect "pipe refused" ($r.Code -eq 1 -and ($r.Out -match "shell operators"))
    $r = Run @("C:\tools\agy.exe -p x");         Expect "agy path refused" ($r.Code -eq 1 -and ($r.Out -match "agy must never call itself"))
    $r = Run @("rg");                            Expect "rg needs confirmation (skipped without tty)" ($r.Code -eq 1 -and -not ((Allowed) -contains "command(rg)"))
    $r = Run @("--yes", "rg");                   Expect "rg allowed with --yes" ((Allowed) -contains "command(rg)")
    $r = Run @("--remove", "pytest");            Expect "remove rule" ($r.Code -eq 0 -and -not ((Allowed) -contains "command(pytest)"))
    $r = Run @("--autonomous");                  Expect "autonomous mode activated" ($r.Code -eq 0 -and ((Allowed) -contains "command(*)"))
    $curDeny = @((Get-Content $S -Raw | ConvertFrom-Json).permissions.deny)
    Expect "autonomous ensures command(agy) in deny" ($curDeny -contains "command(agy)")
    Expect "autonomous ensures rm in deny" ($curDeny -contains "command(rm -rf)")
    $r = Run @("--strict");                      Expect "strict mode restored" ($r.Code -eq 0 -and -not ((Allowed) -contains "command(*)"))
    $r = Run @("--list");                        Expect "list contains deny and allow rules" ($r.Code -eq 0 -and ($r.Out -match "command\(rm -rf\)") -and ($r.Out -match "command\(npm test\)"))
    $r = Run @();                                Expect "no args exits with usage" ($r.Code -eq 1 -and ($r.Out -match "Usage:"))
    $j = Get-Content $S -Raw | ConvertFrom-Json
    Expect "other keys preserved" ($j.model -eq "keep-me" -and (@($j.trustedWorkspaces)[0] -eq "C:\x"))
    $b = [IO.File]::ReadAllBytes($S); Expect "no UTF-8 BOM" (-not ($b[0] -eq 0xEF))
    [IO.File]::WriteAllText($S, '{"permissions": ', $utf8)
    $r = Run @("pytest");                        Expect "malformed settings.json untouched on error" ($r.Code -eq 1 -and ([IO.File]::ReadAllText($S) -eq '{"permissions": '))
    [IO.File]::WriteAllText($S, '{"permissions": {"allow": "x"}}', $utf8)
    $r = Run @("pytest");                        Expect "allow not array refused" ($r.Code -eq 1)
    Remove-Item $S -Force -ErrorAction SilentlyContinue
    $r = Run @("pytest");                        Expect "missing settings.json auto-created" ($r.Code -eq 0 -and ((Allowed) -contains "command(pytest)"))
    $j = Get-Content $S -Raw
    Expect "single rule still a JSON array" ($j -match '"allow":\s*\[')
} finally {
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails -gt 0) { exit 1 }
exit 0
