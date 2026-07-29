#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $root 'boot-timeout-result.txt'
$checkpoint = Join-Path $env:ProgramData `
    ('FactoryRecoveryBuild\Timeout-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $checkpoint -Force | Out-Null
$bcdBackup = Join-Path $checkpoint 'BCD'

& bcdedit.exe /export $bcdBackup | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'BCD checkpoint export failed.' }
& bcdedit.exe /timeout 3 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not set Boot Manager timeout.' }

$bootManager = (& bcdedit.exe /enum '{bootmgr}' /v 2>&1) -join "`r`n"
if ($LASTEXITCODE -ne 0 -or
    $bootManager -notmatch '(?im)^\s*timeout\s+3\s*$') {
    & bcdedit.exe /import $bcdBackup | Out-Null
    throw 'Timeout verification failed; BCD checkpoint was restored.'
}

@"
BOOT MANAGER TIMEOUT UPDATED
Timeout: 3 seconds
BCD checkpoint: $bcdBackup
"@ | Set-Content -LiteralPath $resultPath -Encoding UTF8
