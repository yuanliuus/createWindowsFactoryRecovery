#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultPath = Join-Path $root 'winre-menu-test-scheduled.txt'
$workingRoot = Join-Path $env:ProgramData 'FactoryRecoveryBuild'
$checkpoint = Join-Path $workingRoot `
    ('WinREMenuTest-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -ItemType Directory -Path $checkpoint -Force | Out-Null
$bcdBackup = Join-Path $checkpoint 'BCD'
& bcdedit.exe /export $bcdBackup | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "BCD export failed with exit code $LASTEXITCODE."
}

$winreInfo = (& reagentc.exe /info 2>&1) -join "`r`n"
if ($LASTEXITCODE -ne 0 -or
    $winreInfo -notmatch '(?im)Windows RE status:\s*Enabled') {
    throw 'Windows RE is not enabled.'
}

& reagentc.exe /boottore | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "REAgentC /boottore failed with exit code $LASTEXITCODE."
}

@"
WINRE MENU TEST SCHEDULED
Time: $([DateTime]::Now.ToString('o'))
BCD checkpoint: $bcdBackup

In Windows Recovery Environment:
1. Select Troubleshoot.
2. Select the Factory Recovery tile.
3. Enter one of the listed image indexes.
4. At Type RESTORE, press Enter without typing anything.
5. The computer will reboot directly to normal Windows.
"@ | Set-Content -LiteralPath $resultPath -Encoding UTF8

& shutdown.exe /r /t 20 /d p:4:1 /c 'One-time WinRE Factory Recovery menu validation'
if ($LASTEXITCODE -ne 0) {
    & bcdedit.exe /deletevalue '{bootmgr}' bootsequence | Out-Null
    throw 'Reboot scheduling failed; the one-time boot sequence was removed.'
}
